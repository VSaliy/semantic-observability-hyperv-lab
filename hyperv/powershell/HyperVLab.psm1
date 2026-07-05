Set-StrictMode -Version Latest

function Test-IsAdministrator {
  [CmdletBinding()]
  param()

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-LabConfiguration {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Lab configuration not found: $Path"
  }

  $content = Get-Content -LiteralPath $Path -Raw
  if ($Path.EndsWith('.json')) {
    return $content | ConvertFrom-Json -AsHashtable
  }

  if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    throw 'PowerShell YAML support is required to load YAML configuration.'
  }

  return $content | ConvertFrom-Yaml -Ordered
}

function Test-LabVmDefinition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Configuration
  )

  foreach ($vmName in $Configuration.vms.Keys) {
    $vm = $Configuration.vms[$vmName]
    if ([int]$vm.cpu -lt 1) {
      throw "VM $vmName must request at least one vCPU."
    }
    if (-not $vm.networks -or $vm.networks.Count -lt 1) {
      throw "VM $vmName must define at least one network."
    }
  }

  return $true
}

function Get-DestructiveCleanupMessage {
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Scope)

  return "Cleanup is destructive for $Scope. Re-run with -Confirm to continue."
}

function ConvertTo-ByteCount {
  <#
  .SYNOPSIS
    Converts a human-friendly size string (for example '4GB' or '60 GB') into a byte count.
  #>
  [CmdletBinding()]
  [OutputType([long])]
  param(
    [Parameter(Mandatory)]
    [string]$Size
  )

  $normalized = $Size.Trim().ToUpperInvariant()
  if ($normalized -match '^(?<value>\d+(?:\.\d+)?)\s*(?<unit>KB|MB|GB|TB|B)?$') {
    $value = [double]$Matches['value']
    switch ($Matches['unit']) {
      'KB' { return [long]($value * 1KB) }
      'MB' { return [long]($value * 1MB) }
      'GB' { return [long]($value * 1GB) }
      'TB' { return [long]($value * 1TB) }
      default { return [long]$value }
    }
  }

  throw "Unable to parse byte size: $Size"
}

function Get-LabVmPlan {
  <#
  .SYNOPSIS
    Produces a normalized, provider-agnostic provisioning plan from lab configuration.
  .DESCRIPTION
    The returned plan contains fully resolved virtual switches and virtual machines with
    byte counts already computed. It performs no side effects and is safe to unit test.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  $switches = [System.Collections.Generic.List[hashtable]]::new()
  if ($Configuration.networks) {
    foreach ($networkKey in $Configuration.networks.Keys) {
      $network = $Configuration.networks[$networkKey]
      $switchName = [string]$network.name
      $switchType = [string]$network.type

      if ([string]::IsNullOrWhiteSpace($switchName)) {
        throw "Network '$networkKey' must define a name."
      }
      if ($switchType -notin @('External', 'Internal', 'Private')) {
        throw "Network '$networkKey' has unsupported type '$switchType'."
      }

      $subnet = $null
      if ($network.subnet) {
        $subnet = [string]$network.subnet
      }

      $switches.Add(@{
          Key    = [string]$networkKey
          Name   = $switchName
          Type   = $switchType
          Subnet = $subnet
        })
    }
  }

  $vms = [System.Collections.Generic.List[hashtable]]::new()
  if ($Configuration.vms) {
    foreach ($vmName in $Configuration.vms.Keys) {
      $vm = $Configuration.vms[$vmName]

      if ([int]$vm.cpu -lt 1) {
        throw "VM $vmName must request at least one vCPU."
      }
      if (-not $vm.networks -or $vm.networks.Count -lt 1) {
        throw "VM $vmName must define at least one network."
      }
      if (-not $vm.memoryStartupBytes) {
        throw "VM $vmName must define memoryStartupBytes."
      }
      if (-not $vm.diskSizeBytes) {
        throw "VM $vmName must define diskSizeBytes."
      }

      $generation = 2
      if ($vm.generation) {
        $generation = [int]$vm.generation
      }

      $vms.Add(@{
          Name               = [string]$vmName
          CpuCount           = [int]$vm.cpu
          MemoryStartupBytes = ConvertTo-ByteCount -Size ([string]$vm.memoryStartupBytes)
          DiskSizeBytes      = ConvertTo-ByteCount -Size ([string]$vm.diskSizeBytes)
          Networks           = @($vm.networks | ForEach-Object { [string]$_ })
          Generation         = $generation
        })
    }
  }

  return @{
    Switches = $switches.ToArray()
    Vms      = $vms.ToArray()
  }
}

function Get-CloudInitInstanceId {
  <#
  .SYNOPSIS
    Returns a deterministic cloud-init NoCloud instance id for a virtual machine.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$VmName
  )

  return ('iid-{0}' -f $VmName.ToLowerInvariant())
}

function Get-CloudInitMetadata {
  <#
  .SYNOPSIS
    Builds cloud-init NoCloud meta-data content for a virtual machine.
  #>
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Metadata is the canonical cloud-init NoCloud term and is treated as singular.')]
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$VmName,

    [string]$Hostname
  )

  if ([string]::IsNullOrWhiteSpace($Hostname)) {
    $Hostname = $VmName
  }

  $instanceId = Get-CloudInitInstanceId -VmName $VmName
  return @"
instance-id: $instanceId
local-hostname: $Hostname
"@
}

function Test-HyperVAvailable {
  <#
  .SYNOPSIS
    Indicates whether the Hyper-V PowerShell cmdlets are available on this host.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  return [bool](Get-Command -Name 'Get-VM' -ErrorAction SilentlyContinue)
}

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
      New-VMSwitch -Name $Name -NetAdapterName $NetAdapterName -AllowManagementOS $true | Out-Null
    }
    'Internal' { New-VMSwitch -Name $Name -SwitchType Internal | Out-Null }
    'Private' { New-VMSwitch -Name $Name -SwitchType Private | Out-Null }
  }

  return $true
}

function New-LabVirtualMachine {
  <#
  .SYNOPSIS
    Creates a Generation 2 lab virtual machine if it does not already exist (idempotent).
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

    [int]$Generation = 2
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

  $primarySwitch = $SwitchNames | Select-Object -First 1
  New-VM -Name $Name `
    -MemoryStartupBytes $MemoryStartupBytes `
    -Generation $Generation `
    -NewVHDPath $VhdPath `
    -NewVHDSizeBytes $DiskSizeBytes `
    -SwitchName $primarySwitch | Out-Null

  Set-VMProcessor -VMName $Name -Count $CpuCount

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

  Start-VM -Name $Name | Out-Null
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

function Invoke-LabProvisioning {
  <#
  .SYNOPSIS
    Provisions the full lab: virtual switches followed by virtual machines.
  .DESCRIPTION
    Validates and normalizes the configuration, then creates each virtual switch and
    virtual machine idempotently. Supports -WhatIf and -Verbose.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  param(
    [Parameter(Mandatory)]
    $Configuration,

    [Parameter(Mandatory)]
    [string]$VhdRootPath,

    [string]$ExternalNetAdapterName
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $null = Test-LabVmDefinition -Configuration $Configuration
  $plan = Get-LabVmPlan -Configuration $Configuration

  if (-not $PSCmdlet.ShouldProcess('Hyper-V lab environment', 'Provision virtual switches and machines')) {
    return
  }

  foreach ($switch in $plan.Switches) {
    if ($switch.Type -eq 'External') {
      if ([string]::IsNullOrWhiteSpace($ExternalNetAdapterName)) {
        throw "External switch '$($switch.Name)' requires -ExternalNetAdapterName."
      }
      New-LabVirtualSwitch -Name $switch.Name -Type $switch.Type -NetAdapterName $ExternalNetAdapterName -Confirm:$false | Out-Null
    }
    else {
      New-LabVirtualSwitch -Name $switch.Name -Type $switch.Type -Confirm:$false | Out-Null
    }
  }

  foreach ($vm in $plan.Vms) {
    $vhdPath = Join-Path -Path $VhdRootPath -ChildPath ('{0}.vhdx' -f $vm.Name)
    New-LabVirtualMachine -Name $vm.Name `
      -MemoryStartupBytes $vm.MemoryStartupBytes `
      -CpuCount $vm.CpuCount `
      -DiskSizeBytes $vm.DiskSizeBytes `
      -SwitchNames $vm.Networks `
      -VhdPath $vhdPath `
      -Generation $vm.Generation `
      -Confirm:$false | Out-Null
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

Export-ModuleMember -Function `
  Test-IsAdministrator, `
  Import-LabConfiguration, `
  Test-LabVmDefinition, `
  Get-DestructiveCleanupMessage, `
  ConvertTo-ByteCount, `
  Get-LabVmPlan, `
  Get-CloudInitInstanceId, `
  Get-CloudInitMetadata, `
  Test-HyperVAvailable, `
  New-LabVirtualSwitch, `
  New-LabVirtualMachine, `
  Start-LabVirtualMachine, `
  Stop-LabVirtualMachine, `
  Remove-LabVirtualMachine, `
  Invoke-LabProvisioning, `
  Remove-LabEnvironment
