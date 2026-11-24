Set-StrictMode -Version Latest

function New-LabVirtualSwitch {
  <#
  .SYNOPSIS
    Creates a Hyper-V virtual switch if it does not already exist (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet('External', 'Internal', 'Private')]
    [string]$Type,

    [string]$NetAdapterName
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  if (Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue) {
    Write-Verbose "Virtual switch '$Name' already exists; skipping creation."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Name, "Create $Type virtual switch")) {
    return $false
  }

  switch ($Type) {
    'External' {
      if ([string]::IsNullOrWhiteSpace($NetAdapterName)) {
        throw "External switch '$Name' requires -NetAdapterName."
      }
      $conflict = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Where-Object {
        $_.NetAdapterInterfaceDescription -and
        (Get-NetAdapter -InterfaceDescription $_.NetAdapterInterfaceDescription -ErrorAction SilentlyContinue).Name -eq $NetAdapterName
      }
      if ($conflict) {
        throw ("Network adapter '{0}' is already bound to external switch '{1}'. " -f $NetAdapterName, $conflict.Name) +
        ("Reuse it by setting the external network 'name' to '{0}' in lab-config.yaml (or rename that switch to '{1}'), " -f $conflict.Name, $Name) +
        'choose a different adapter, or remove the existing switch.'
      }
      New-VMSwitch -Name $Name -NetAdapterName $NetAdapterName -AllowManagementOS $true -ErrorAction Stop | Out-Null
    }
    'Internal' { New-VMSwitch -Name $Name -SwitchType Internal -ErrorAction Stop | Out-Null }
    'Private' { New-VMSwitch -Name $Name -SwitchType Private -ErrorAction Stop | Out-Null }
  }

  return $true
}

function New-LabVirtualMachine {
  <#
  .SYNOPSIS
    Creates a Generation 2 lab virtual machine if it does not already exist (idempotent).
  .DESCRIPTION
    By default the VM is only created when it does not already exist. A leftover virtual disk
    at the target path (for example from a VM removed without its disk) stops creation with a
    clear error. Use -Force to delete such a leftover disk and recreate the VM cleanly.
    Secure Boot is configured for Linux guests (Microsoft UEFI CA template) so Ubuntu boots
    on Generation 2; pass -SecureBootTemplate 'Off' to disable Secure Boot entirely.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [long]$MemoryStartupBytes,

    [Parameter(Mandatory)]
    [int]$CpuCount,

    [Parameter(Mandatory)]
    [long]$DiskSizeBytes,

    [Parameter(Mandatory)]
    [string[]]$SwitchNames,

    [Parameter(Mandatory)]
    [string]$VhdPath,

    [int]$Generation = 2,

    [string]$SecureBootTemplate = 'MicrosoftUEFICertificateAuthority',

    [ValidateSet('Nothing', 'StartIfRunning', 'Start')]
    [string]$AutomaticStartAction = 'Nothing',

    [ValidateSet('TurnOff', 'Save', 'ShutDown')]
    [string]$AutomaticStopAction = 'ShutDown',

    [ValidateSet('Standard', 'Production', 'ProductionOnly', 'Disabled')]
    [string]$CheckpointType = 'Production',

    [switch]$DynamicMemory,

    [switch]$Force
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Verbose "VM '$Name' already exists; skipping creation."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Name, 'Create lab virtual machine')) {
    return $false
  }

  if (Test-Path -LiteralPath $VhdPath) {
    if ($Force) {
      Write-Verbose "Removing leftover virtual disk '$VhdPath' before recreating VM '$Name'."
      Remove-Item -LiteralPath $VhdPath -Force
    }
    else {
      throw "A virtual disk already exists at '$VhdPath'. Remove it, or re-run with -Force (Invoke-LabProvisioning -Rebuild), before creating VM '$Name'."
    }
  }

  $vhdDirectory = Split-Path -Path $VhdPath -Parent
  if ($vhdDirectory -and -not (Test-Path -LiteralPath $vhdDirectory)) {
    New-Item -ItemType Directory -Path $vhdDirectory -Force | Out-Null
  }

  $primarySwitch = $SwitchNames | Select-Object -First 1
  New-VM -Name $Name `
    -MemoryStartupBytes $MemoryStartupBytes `
    -Generation $Generation `
    -NewVHDPath $VhdPath `
    -NewVHDSizeBytes $DiskSizeBytes `
    -SwitchName $primarySwitch | Out-Null

  Set-VMProcessor -VMName $Name -Count $CpuCount

  Set-VM -Name $Name -AutomaticStartAction $AutomaticStartAction -AutomaticStopAction $AutomaticStopAction -CheckpointType $CheckpointType
  Set-VMMemory -VMName $Name -DynamicMemoryEnabled ([bool]$DynamicMemory)

  if ($Generation -eq 2) {
    if ($SecureBootTemplate -eq 'Off') {
      Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    }
    else {
      Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate $SecureBootTemplate
    }
  }

  foreach ($additionalSwitch in ($SwitchNames | Select-Object -Skip 1)) {
    Add-VMNetworkAdapter -VMName $Name -SwitchName $additionalSwitch
  }

  return $true
}

function Start-LabVirtualMachine {
  <#
  .SYNOPSIS
    Starts a lab virtual machine unless it is already running (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
  if (-not $vm) {
    throw "VM '$Name' was not found."
  }
  if ($vm.State -eq 'Running') {
    Write-Verbose "VM '$Name' is already running."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Name, 'Start virtual machine')) {
    return $false
  }

  Start-VM -Name $Name -ErrorAction Stop | Out-Null
  return $true
}

function Stop-LabVirtualMachine {
  <#
  .SYNOPSIS
    Stops a lab virtual machine unless it is already stopped (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$Force
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
  if (-not $vm) {
    throw "VM '$Name' was not found."
  }
  if ($vm.State -eq 'Off') {
    Write-Verbose "VM '$Name' is already stopped."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Name, 'Stop virtual machine')) {
    return $false
  }

  if ($Force) {
    Stop-VM -Name $Name -Force | Out-Null
  }
  else {
    Stop-VM -Name $Name | Out-Null
  }

  return $true
}

function Remove-LabVirtualMachine {
  <#
  .SYNOPSIS
    Removes a lab virtual machine and, optionally, its attached virtual disks (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$RemoveDisks
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
  if (-not $vm) {
    Write-Verbose "VM '$Name' does not exist; nothing to remove."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Name, 'Remove lab virtual machine')) {
    return $false
  }

  if ($vm.State -ne 'Off') {
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
  }

  $diskPaths = @()
  if ($RemoveDisks) {
    $diskPaths = @(Get-VMHardDiskDrive -VMName $Name | Select-Object -ExpandProperty Path)
  }

  Remove-VM -Name $Name -Force | Out-Null

  foreach ($diskPath in $diskPaths) {
    if ($diskPath -and (Test-Path -LiteralPath $diskPath)) {
      Remove-Item -LiteralPath $diskPath -Force
    }
  }

  return $true
}

function Add-LabCloudInitDisk {
  <#
  .SYNOPSIS
    Attaches a cloud-init NoCloud seed ISO to a virtual machine as a DVD drive (idempotent).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$IsoPath
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }
  if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "cloud-init seed image not found: $IsoPath"
  }

  $existing = Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $IsoPath }
  if ($existing) {
    Write-Verbose "cloud-init seed '$IsoPath' is already attached to '$VmName'."
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($VmName, "Attach cloud-init seed $IsoPath")) {
    return $false
  }

  Add-VMDvdDrive -VMName $VmName -Path $IsoPath
  return $true
}

function Add-LabInstallMedia {
  <#
  .SYNOPSIS
    Attaches an OS installer ISO to a virtual machine and optionally makes it the first boot device.
  .DESCRIPTION
    Idempotently attaches the installer ISO (for example the Ubuntu Server live-server image) as a
    DVD drive. -SetFirstBootDevice makes the installer the first boot device (manual installs).
    -BootAfterDisk sets the boot order to the hard disk first and the installer DVD second, so a
    blank disk falls through to the installer but a finished (autoinstall) install boots the disk
    instead of re-running the installer. Returns $true when a change was made.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$IsoPath,

    [switch]$SetFirstBootDevice,

    [switch]$BootAfterDisk
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }
  if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "installer ISO not found: $IsoPath"
  }

  $changed = $false
  $drive = Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $IsoPath } |
    Select-Object -First 1

  if (-not $drive) {
    if ($PSCmdlet.ShouldProcess($VmName, "Attach installer media $IsoPath")) {
      $drive = Add-VMDvdDrive -VMName $VmName -Path $IsoPath -Passthru
      $changed = $true
    }
  }
  else {
    Write-Verbose "Installer media '$IsoPath' is already attached to '$VmName'."
  }

  if ($drive -and $BootAfterDisk) {
    if ($PSCmdlet.ShouldProcess($VmName, 'Set boot order to disk then installer DVD')) {
      $bootOrder = @()
      $bootOrder += @(Get-VMHardDiskDrive -VMName $VmName)
      $bootOrder += $drive
      Set-VMFirmware -VMName $VmName -BootOrder $bootOrder
      $changed = $true
    }
  }
  elseif ($drive -and $SetFirstBootDevice) {
    if ($PSCmdlet.ShouldProcess($VmName, 'Set installer DVD as first boot device')) {
      Set-VMFirmware -VMName $VmName -FirstBootDevice $drive
      $changed = $true
    }
  }

  return $changed
}
