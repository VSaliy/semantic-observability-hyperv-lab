Set-StrictMode -Version Latest

function Invoke-LabProvisioning {
  <#
  .SYNOPSIS
    Provisions the full lab: virtual switches followed by virtual machines.
  .DESCRIPTION
    Validates and normalizes the configuration, then creates each virtual switch and
    virtual machine idempotently. When -CloudInitSourcePath is supplied, a cloud-init NoCloud
    seed image is built and attached to every VM that declares a cloudInit user-data file.
    Use -Rebuild for a clean rebuild: existing lab VMs and their disks are removed and
    recreated. Virtual switches (and any NAT) are always left in place.
    When -InstallIsoPath (or an installIso key in configuration) is supplied, that ISO is
    attached to every VM and set as the first boot device so the guests boot the installer.
    With -Autoinstall, an unattended Ubuntu autoinstall NoCloud seed is rendered per VM from
    the template and secrets in the .env file (-EnvFile); the rendered credentials are written
    only to the staging area (outside the repository) and are never logged.
    With -BuildAutoinstallIso, the installer ISO is first remastered (via WSL, or -IsoEngine
    docker) to inject the 'autoinstall' kernel argument so the install runs fully hands-off.
    -StartVms powers on each VM at the end (off by default, since with -Autoinstall this starts
    a destructive unattended install); starting is best-effort and reports per-VM failures
    (for example insufficient host RAM) without falsely reporting success. -DynamicMemory
    creates VMs with Hyper-V Dynamic Memory so they start with less RAM (applies to VMs created
    this run; use -Rebuild to reconfigure existing VMs).
    Supports -WhatIf and -Verbose.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  param(
    [Parameter(Mandatory)]
    $Configuration,

    [Parameter(Mandatory)]
    [string]$VhdRootPath,

    [string]$ExternalNetAdapterName,

    [string]$CloudInitSourcePath,

    [string]$CloudInitStagingPath,

    [string[]]$DnsServers = @('1.1.1.1', '9.9.9.9'),

    [string]$InstallIsoPath,

    [switch]$Autoinstall,

    [string]$EnvFile = (Join-Path -Path $script:LabModuleRoot -ChildPath '..\..\.env'),

    [string]$AutoinstallTemplatePath = (Join-Path -Path $script:LabModuleRoot -ChildPath '..\cloud-init\autoinstall\user-data.template'),

    [switch]$BuildAutoinstallIso,

    [ValidateSet('wsl', 'docker', 'oscdimg')]
    [string]$IsoEngine = 'wsl',

    [switch]$StartVms,

    [switch]$DynamicMemory,

    [switch]$Rebuild
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  if ([string]::IsNullOrWhiteSpace($InstallIsoPath) -and $Configuration['installIso']) {
    $InstallIsoPath = [string]$Configuration['installIso']
  }
  if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath) -and -not (Test-Path -LiteralPath $InstallIsoPath)) {
    throw "installer ISO not found: $InstallIsoPath"
  }

  if ($BuildAutoinstallIso) {
    if ([string]::IsNullOrWhiteSpace($InstallIsoPath)) {
      throw '-BuildAutoinstallIso requires -InstallIsoPath (or an installIso key in configuration) as the source ISO.'
    }
    $sourceDir = Split-Path -Path $InstallIsoPath -Parent
    $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($InstallIsoPath)
    $autoinstallIsoPath = Join-Path -Path $sourceDir -ChildPath ('{0}-autoinstall.iso' -f $sourceBase)
    try {
      $InstallIsoPath = New-AutoinstallIso -SourceIsoPath $InstallIsoPath -OutputIsoPath $autoinstallIsoPath `
        -Engine $IsoEngine -Force:$Rebuild -Confirm:$false
    }
    catch {
      throw "Failed to build the autoinstall ISO (engine '$IsoEngine'): $($_.Exception.Message)"
    }
  }

  $autoinstallValues = $null
  if ($Autoinstall) {
    if ([string]::IsNullOrWhiteSpace($InstallIsoPath)) {
      throw '-Autoinstall requires -InstallIsoPath (or an installIso key in configuration).'
    }
    if (-not (Test-OscdimgAvailable)) {
      throw '-Autoinstall requires oscdimg.exe (Windows ADK Deployment Tools) to build the NoCloud seed.'
    }
    if (-not (Test-Path -LiteralPath $AutoinstallTemplatePath)) {
      throw "autoinstall template not found: $AutoinstallTemplatePath"
    }
    Write-LabStatus ("Loading autoinstall secrets from '{0}'..." -f $EnvFile)
    try {
      # Loaded once; treated as sensitive and never written back to the repository or logs.
      $autoinstallValues = Import-DotEnv -Path $EnvFile
    }
    catch {
      throw "Failed to load autoinstall secrets from '$EnvFile': $($_.Exception.Message)"
    }
  }

  $null = Test-LabVmDefinition -Configuration $Configuration
  $plan = Get-LabVmPlan -Configuration $Configuration

  if (-not $PSCmdlet.ShouldProcess('Hyper-V lab environment', 'Provision virtual switches and machines')) {
    return
  }

  $switchCount = @($plan.Switches).Count
  $vmCount = @($plan.Vms).Count
  Write-LabStatus ("Provisioning lab: {0} virtual switch(es), {1} virtual machine(s)." -f $switchCount, $vmCount) -Level Step

  foreach ($switch in $plan.Switches) {
    try {
      if ($switch.Type -eq 'External') {
        $adapter = $ExternalNetAdapterName
        if ([string]::IsNullOrWhiteSpace($adapter)) {
          $adapter = $switch.AdapterName
        }
        if ([string]::IsNullOrWhiteSpace($adapter)) {
          throw "External switch '$($switch.Name)' requires -ExternalNetAdapterName or an adapterName in configuration."
        }
        $switchCreated = New-LabVirtualSwitch -Name $switch.Name -Type $switch.Type -NetAdapterName $adapter -Confirm:$false
      }
      else {
        $switchCreated = New-LabVirtualSwitch -Name $switch.Name -Type $switch.Type -Confirm:$false
      }
      if ($switchCreated) {
        Write-LabStatus ("Created {0} switch '{1}'." -f $switch.Type, $switch.Name) -Level Success
      }
      else {
        Write-LabStatus ("Switch '{0}' already present; leaving it in place." -f $switch.Name)
      }

      # An Internal switch exposes a host vNIC; give it the declared gateway IP so the host
      # can reach the guests on the lab subnet (required for the SSH wait and Ansible). This
      # is idempotent and runs on every provisioning pass, not only when the switch is created.
      if ($switch.Type -eq 'Internal' -and -not [string]::IsNullOrWhiteSpace($switch.Gateway)) {
        $prefixLength = 24
        if (-not [string]::IsNullOrWhiteSpace($switch.Subnet) -and $switch.Subnet -match '/(\d{1,2})$') {
          $prefixLength = [int]$Matches[1]
        }
        $hostAlias = 'vEthernet ({0})' -f $switch.Name
        $hostVnic = $null
        for ($attempt = 0; $attempt -lt 10 -and -not $hostVnic; $attempt++) {
          $hostVnic = Get-NetAdapter -Name $hostAlias -ErrorAction SilentlyContinue
          if (-not $hostVnic) { Start-Sleep -Milliseconds 500 }
        }
        if ($hostVnic) {
          $hasGatewayIp = Get-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $switch.Gateway -ErrorAction SilentlyContinue
          if (-not $hasGatewayIp) {
            New-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $switch.Gateway -PrefixLength $prefixLength -ErrorAction Stop | Out-Null
            Write-LabStatus ("Assigned host IP {0}/{1} to '{2}'." -f $switch.Gateway, $prefixLength, $hostAlias) -Level Success
          }
          else {
            Write-LabStatus ("Host IP {0} already present on '{1}'." -f $switch.Gateway, $hostAlias)
          }
        }
        else {
          Write-LabStatus ("Host vNIC '{0}' did not appear; skipping host IP assignment (assign {1}/{2} manually if the SSH wait stalls)." -f $hostAlias, $switch.Gateway, $prefixLength) -Level Warning
        }
      }
    }
    catch {
      throw "Failed to ensure virtual switch '$($switch.Name)' ($($switch.Type)): $($_.Exception.Message)"
    }
  }

  if ((-not [string]::IsNullOrWhiteSpace($CloudInitSourcePath)) -or $Autoinstall) {
    if ([string]::IsNullOrWhiteSpace($CloudInitStagingPath)) {
      $CloudInitStagingPath = Join-Path -Path $VhdRootPath -ChildPath 'cloud-init-seeds'
    }
    $oscdimgAvailable = Test-OscdimgAvailable
    if (-not $oscdimgAvailable -and -not $Autoinstall) {
      Write-LabStatus 'oscdimg.exe is not available; skipping cloud-init seed generation (install the Windows ADK to enable it).' -Level Warning
    }
  }

  if (-not (Test-Path -LiteralPath $VhdRootPath)) {
    New-Item -ItemType Directory -Path $VhdRootPath -Force | Out-Null
  }

  # Preflight: a full VHD drive causes dynamic disks to fail mid-install with
  # 'critical IO errors' (PausedCritical). Warn before creating anything.
  $vhdQualifier = Split-Path -Path $VhdRootPath -Qualifier -ErrorAction SilentlyContinue
  if ($vhdQualifier) {
    $vhdDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$vhdQualifier'" -ErrorAction SilentlyContinue
    if ($vhdDisk -and $vhdDisk.FreeSpace -lt 40GB) {
      Write-LabStatus ("Only {0:N1} GB free on {1} for VHDs; dynamic disks may fill it and pause the VMs with 'critical IO errors'. Point -VhdRootPath at a drive with more free space." -f ($vhdDisk.FreeSpace / 1GB), $vhdQualifier) -Level Warning
    }
  }

  $index = 0
  foreach ($vm in $plan.Vms) {
    $index++
    $label = '[{0}/{1}] {2}' -f $index, $vmCount, $vm.Name
    try {
      $vhdPath = Join-Path -Path $VhdRootPath -ChildPath ('{0}.vhdx' -f $vm.Name)

      if ($Rebuild) {
        Write-LabStatus ("{0}: removing existing VM and disk (rebuild)..." -f $label)
        Remove-LabVirtualMachine -Name $vm.Name -RemoveDisks -Confirm:$false | Out-Null
      }

      Write-LabStatus ("{0}: creating VM ({1} vCPU, {2:N0} MB RAM, {3:N0} GB disk)..." -f $label, $vm.CpuCount, ($vm.MemoryStartupBytes / 1MB), ($vm.DiskSizeBytes / 1GB)) -Level Step
      $vmCreated = New-LabVirtualMachine -Name $vm.Name `
        -MemoryStartupBytes $vm.MemoryStartupBytes `
        -CpuCount $vm.CpuCount `
        -DiskSizeBytes $vm.DiskSizeBytes `
        -SwitchNames $vm.Networks `
        -VhdPath $vhdPath `
        -Generation $vm.Generation `
        -DynamicMemory:$DynamicMemory `
        -Force:$Rebuild `
        -Confirm:$false
      if (-not $vmCreated) {
        Write-LabStatus ("{0}: VM already exists; leaving it in place." -f $label)
      }

      $networkConfig = $null
      if ($vm.IpAddress) {
        $networkConfig = Get-CloudInitNetworkConfig -StaticIpCidr $vm.IpAddress -DnsServers $DnsServers
      }

      $seedDirectory = $null
      if ($Autoinstall) {
        Write-LabStatus ("{0}: rendering autoinstall seed..." -f $label)
        $userData = Get-AutoinstallUserData -TemplatePath $AutoinstallTemplatePath -Values $autoinstallValues -Hostname $vm.Hostname -StaticIpCidr $vm.IpAddress -DnsServers $DnsServers
        $seedDirectory = New-CloudInitSeedStaging -VmName $vm.Name -UserDataContent $userData -OutputRootPath $CloudInitStagingPath -Hostname $vm.Hostname -NetworkConfig $networkConfig -Confirm:$false
      }
      elseif (-not [string]::IsNullOrWhiteSpace($CloudInitSourcePath) -and $vm.CloudInit -and $oscdimgAvailable) {
        Write-LabStatus ("{0}: staging cloud-init seed from '{1}'..." -f $label, $vm.CloudInit)
        $userDataPath = Join-Path -Path $CloudInitSourcePath -ChildPath $vm.CloudInit
        $seedDirectory = New-CloudInitSeedStaging -VmName $vm.Name -UserDataPath $userDataPath -OutputRootPath $CloudInitStagingPath -Hostname $vm.Hostname -NetworkConfig $networkConfig -Confirm:$false
      }

      if ($seedDirectory) {
        $isoPath = Join-Path -Path $CloudInitStagingPath -ChildPath ('{0}-cidata.iso' -f $vm.Name)
        New-CloudInitSeedImage -SeedDirectory $seedDirectory -OutputIsoPath $isoPath -Confirm:$false | Out-Null
        Add-LabCloudInitDisk -VmName $vm.Name -IsoPath $isoPath -Confirm:$false | Out-Null
        Write-LabStatus ("{0}: attached cloud-init seed." -f $label)
      }

      if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath)) {
        $bootMode = if ($Autoinstall) { 'disk-first (auto-installs then boots disk)' } else { 'DVD-first' }
        Add-LabInstallMedia -VmName $vm.Name -IsoPath $InstallIsoPath -SetFirstBootDevice:(-not $Autoinstall) -BootAfterDisk:$Autoinstall -Confirm:$false | Out-Null
        Write-LabStatus ("{0}: attached installer media (boot order: {1})." -f $label, $bootMode)
      }

      Write-LabStatus ("{0}: ready." -f $label) -Level Success
    }
    catch {
      throw "Failed provisioning VM '$($vm.Name)' ($label): $($_.Exception.Message)"
    }
  }

  Write-LabStatus ("Provisioning complete: {0} of {1} VM(s) created/updated." -f $vmCount, $vmCount) -Level Success

  if ($StartVms) {
    # Capacity heads-up: fixed-memory VMs reserve all RAM at startup.
    try {
      $freeBytes = [int64](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1KB
      $totalStartupBytes = 0L
      foreach ($planVm in $plan.Vms) {
        $totalStartupBytes += [long]$planVm['MemoryStartupBytes']
      }
      if ($totalStartupBytes -gt $freeBytes) {
        Write-LabStatus ("Total VM startup memory ({0:N1} GB) exceeds free host RAM ({1:N1} GB); some VMs may fail to start. Consider -DynamicMemory (with -Rebuild), smaller sizes, or closing memory-heavy apps." -f ($totalStartupBytes / 1GB), ($freeBytes / 1GB)) -Level Warning
      }
    }
    catch {
      Write-Verbose "Could not evaluate host memory capacity: $($_.Exception.Message)"
    }

    $startFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $plan.Vms) {
      try {
        Write-LabStatus ("Starting '{0}'..." -f $vm.Name)
        Start-LabVirtualMachine -Name $vm.Name -Confirm:$false | Out-Null
        Write-LabStatus ("Started '{0}'." -f $vm.Name) -Level Success
      }
      catch {
        $startFailures.Add(('{0}: {1}' -f $vm.Name, $_.Exception.Message))
        Write-LabStatus ("Failed to start '{0}': {1}" -f $vm.Name, $_.Exception.Message) -Level Warning
      }
    }

    $startedCount = $vmCount - $startFailures.Count
    if ($startFailures.Count -gt 0) {
      Write-LabStatus ("{0} of {1} VM(s) started; {2} failed to start (see warnings above)." -f $startedCount, $vmCount, $startFailures.Count) -Level Warning
      Write-LabStatus 'Free host RAM (stop other VMs), or recreate with -DynamicMemory -Rebuild, then re-run to start the remaining VMs.'
    }
    elseif ($Autoinstall) {
      Write-LabStatus ("All {0} VM(s) started: the unattended install is running now; each reboots into the installed OS automatically (disk-first boot order)." -f $vmCount) -Level Success
    }
    else {
      Write-LabStatus ("All {0} VM(s) started: open the console (VMConnect / Hyper-V Manager) to complete the installer." -f $vmCount) -Level Success
    }
  }
  elseif ($Autoinstall) {
    Write-LabStatus 'Next: start the VMs (Start-LabEnvironment, or re-run with -StartVms) to run the unattended install; each reboots into the installed OS automatically.'
  }
  elseif (-not [string]::IsNullOrWhiteSpace($InstallIsoPath)) {
    Write-LabStatus 'Next: start the VMs, complete the installer, then detach the ISO (see hyperv/README.md).'
  }
}

function Remove-LabEnvironment {
  <#
  .SYNOPSIS
    Removes every lab virtual machine defined in the configuration (destructive).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  param(
    [Parameter(Mandatory)]
    $Configuration,

    [switch]$RemoveDisks
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $plan = Get-LabVmPlan -Configuration $Configuration
  foreach ($vm in $plan.Vms) {
    if ($PSCmdlet.ShouldProcess($vm.Name, 'Remove lab virtual machine')) {
      Remove-LabVirtualMachine -Name $vm.Name -RemoveDisks:$RemoveDisks -Confirm:$false | Out-Null
    }
  }
}

function Start-LabEnvironment {
  <#
  .SYNOPSIS
    Starts every lab virtual machine defined in the configuration (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $plan = Get-LabVmPlan -Configuration $Configuration
  foreach ($vm in $plan.Vms) {
    if ($PSCmdlet.ShouldProcess($vm.Name, 'Start lab virtual machine')) {
      Start-LabVirtualMachine -Name $vm.Name -Confirm:$false | Out-Null
      Write-LabStatus ("Started '{0}'." -f $vm.Name) -Level Success
    }
  }
}

function Stop-LabEnvironment {
  <#
  .SYNOPSIS
    Stops every lab virtual machine defined in the configuration (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  param(
    [Parameter(Mandatory)]
    $Configuration,

    [switch]$Force
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $plan = Get-LabVmPlan -Configuration $Configuration
  foreach ($vm in $plan.Vms) {
    if ($PSCmdlet.ShouldProcess($vm.Name, 'Stop lab virtual machine')) {
      Stop-LabVirtualMachine -Name $vm.Name -Force:$Force -Confirm:$false | Out-Null
      Write-LabStatus ("Stopped '{0}'." -f $vm.Name)
    }
  }
}

function Get-LabStatus {
  <#
  .SYNOPSIS
    Returns the current state of each lab virtual machine defined in the configuration.
  .OUTPUTS
    One PSCustomObject per VM with Name, State, CpuUsage, MemoryAssignedMB and Uptime.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $plan = Get-LabVmPlan -Configuration $Configuration
  foreach ($vm in $plan.Vms) {
    $hyperVvm = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Name            = $vm.Name
      State           = if ($hyperVvm) { [string]$hyperVvm.State } else { 'NotCreated' }
      CpuUsage        = if ($hyperVvm) { $hyperVvm.CPUUsage } else { $null }
      MemoryAssignedMB = if ($hyperVvm) { [math]::Round($hyperVvm.MemoryAssigned / 1MB) } else { $null }
      Uptime          = if ($hyperVvm) { $hyperVvm.Uptime } else { $null }
    }
  }
}
