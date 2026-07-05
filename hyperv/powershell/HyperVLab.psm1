Set-StrictMode -Version Latest

function Write-LabStatus {
  <#
  .SYNOPSIS
    Writes a colored, prefixed provisioning status line to the host console.
  #>
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Provisioning progress is intended for the interactive console.')]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Message,

    [ValidateSet('Info', 'Step', 'Success', 'Warning')]
    [string]$Level = 'Info'
  )

  $prefix = switch ($Level) {
    'Step' { '==>' }
    'Success' { '[ OK ]' }
    'Warning' { '[WARN]' }
    default { '  -' }
  }
  $color = switch ($Level) {
    'Step' { 'Cyan' }
    'Success' { 'Green' }
    'Warning' { 'Yellow' }
    default { 'Gray' }
  }

  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

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
    if ([int]$vm['cpu'] -lt 1) {
      throw "VM $vmName must request at least one vCPU."
    }
    if (-not $vm['networks'] -or $vm['networks'].Count -lt 1) {
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
      $switchName = [string]$network['name']
      $switchType = [string]$network['type']

      if ([string]::IsNullOrWhiteSpace($switchName)) {
        throw "Network '$networkKey' must define a name."
      }
      if ($switchType -notin @('External', 'Internal', 'Private')) {
        throw "Network '$networkKey' has unsupported type '$switchType'."
      }

      $subnet = $null
      if ($network['subnet']) {
        $subnet = [string]$network['subnet']
      }

      $adapterName = $null
      if ($network['adapterName']) {
        $adapterName = [string]$network['adapterName']
      }

      $gateway = $null
      if ($network['gateway']) {
        $gateway = [string]$network['gateway']
      }

      $switches.Add(@{
          Key         = [string]$networkKey
          Name        = $switchName
          Type        = $switchType
          Subnet      = $subnet
          AdapterName = $adapterName
          Gateway     = $gateway
        })
    }
  }

  $vms = [System.Collections.Generic.List[hashtable]]::new()
  if ($Configuration.vms) {
    foreach ($vmName in $Configuration.vms.Keys) {
      $vm = $Configuration.vms[$vmName]

      if ([int]$vm['cpu'] -lt 1) {
        throw "VM $vmName must request at least one vCPU."
      }
      if (-not $vm['networks'] -or $vm['networks'].Count -lt 1) {
        throw "VM $vmName must define at least one network."
      }
      if (-not $vm['memoryStartupBytes']) {
        throw "VM $vmName must define memoryStartupBytes."
      }
      if (-not $vm['diskSizeBytes']) {
        throw "VM $vmName must define diskSizeBytes."
      }

      $generation = 2
      if ($vm['generation']) {
        $generation = [int]$vm['generation']
      }

      $hostname = [string]$vmName
      if ($vm['hostname']) {
        $hostname = [string]$vm['hostname']
      }

      $ipAddress = $null
      if ($vm['ipAddress']) {
        $ipAddress = [string]$vm['ipAddress']
      }

      $cloudInit = $null
      if ($vm['cloudInit']) {
        $cloudInit = [string]$vm['cloudInit']
      }

      $role = $null
      if ($vm['role']) {
        $role = [string]$vm['role']
      }

      $vms.Add(@{
          Name               = [string]$vmName
          Hostname           = $hostname
          Role               = $role
          CpuCount           = [int]$vm['cpu']
          MemoryStartupBytes = ConvertTo-ByteCount -Size ([string]$vm['memoryStartupBytes'])
          DiskSizeBytes      = ConvertTo-ByteCount -Size ([string]$vm['diskSizeBytes'])
          Networks           = @($vm['networks'] | ForEach-Object { [string]$_ })
          Generation         = $generation
          IpAddress          = $ipAddress
          CloudInit          = $cloudInit
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

function Get-CloudInitNetworkConfig {
  <#
  .SYNOPSIS
    Builds cloud-init NoCloud network-config (netplan v2) for a lab virtual machine.
  .DESCRIPTION
    Produces a deterministic netplan version 2 document. The primary interface uses DHCP
    (typically the external switch that provides internet access) and the secondary
    interface receives the static lab address on the internal observability network.
    No default route is placed on the static interface unless -DefaultRouteOnStatic is set,
    which avoids conflicting default routes on multi-homed guests.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$StaticIpCidr,

    [string[]]$DnsServers = @('1.1.1.1', '9.9.9.9'),

    [string]$PrimaryInterface = 'eth0',

    [string]$StaticInterface = 'eth1',

    [string]$Gateway,

    [switch]$DefaultRouteOnStatic
  )

  if ($StaticIpCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "StaticIpCidr must be in CIDR notation (for example '10.50.0.11/24'): $StaticIpCidr"
  }

  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine('version: 2')
  [void]$builder.AppendLine('ethernets:')
  [void]$builder.AppendLine(('  {0}:' -f $PrimaryInterface))
  [void]$builder.AppendLine('    dhcp4: true')
  [void]$builder.AppendLine('    optional: true')
  [void]$builder.AppendLine(('  {0}:' -f $StaticInterface))
  [void]$builder.AppendLine('    dhcp4: false')
  [void]$builder.AppendLine('    addresses:')
  [void]$builder.AppendLine(('      - {0}' -f $StaticIpCidr))

  if ($DefaultRouteOnStatic) {
    if ([string]::IsNullOrWhiteSpace($Gateway)) {
      throw '-DefaultRouteOnStatic requires -Gateway.'
    }
    [void]$builder.AppendLine('    routes:')
    [void]$builder.AppendLine('      - to: default')
    [void]$builder.AppendLine(('        via: {0}' -f $Gateway))
  }

  if ($DnsServers -and $DnsServers.Count -gt 0) {
    [void]$builder.AppendLine('    nameservers:')
    [void]$builder.AppendLine('      addresses:')
    foreach ($dns in $DnsServers) {
      [void]$builder.AppendLine(('        - {0}' -f $dns))
    }
  }

  return $builder.ToString().TrimEnd() + "`n"
}

function New-CloudInitSeedStaging {
  <#
  .SYNOPSIS
    Writes cloud-init NoCloud seed files (meta-data, user-data, network-config) to a staging folder.
  .DESCRIPTION
    Creates a per-VM staging directory populated with the three NoCloud files. The user-data is
    taken from an existing #cloud-config document (-UserDataPath) or from an in-memory string
    (-UserDataContent, used for rendered autoinstall so secrets never touch the repository). The
    staging folder can later be turned into a NoCloud seed image with New-CloudInitSeedImage.
  .OUTPUTS
    The absolute path to the staging directory that was created.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low', DefaultParameterSetName = 'FromFile')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory, ParameterSetName = 'FromFile')]
    [string]$UserDataPath,

    [Parameter(Mandatory, ParameterSetName = 'FromContent')]
    [string]$UserDataContent,

    [Parameter(Mandatory)]
    [string]$OutputRootPath,

    [string]$Hostname,

    [string]$NetworkConfig
  )

  if ($PSCmdlet.ParameterSetName -eq 'FromContent') {
    $userData = $UserDataContent
  }
  else {
    if (-not (Test-Path -LiteralPath $UserDataPath)) {
      throw "cloud-init user-data not found: $UserDataPath"
    }
    $userData = Get-Content -LiteralPath $UserDataPath -Raw
  }

  if ($userData -notmatch '^\s*#cloud-config') {
    throw "cloud-init user-data must begin with '#cloud-config'."
  }

  $seedDirectory = Join-Path -Path $OutputRootPath -ChildPath $VmName
  if (-not $PSCmdlet.ShouldProcess($seedDirectory, 'Write cloud-init NoCloud seed files')) {
    return $seedDirectory
  }

  if (-not (Test-Path -LiteralPath $seedDirectory)) {
    New-Item -ItemType Directory -Path $seedDirectory -Force | Out-Null
  }

  $metadata = Get-CloudInitMetadata -VmName $VmName -Hostname $Hostname
  Set-Content -LiteralPath (Join-Path -Path $seedDirectory -ChildPath 'meta-data') -Value $metadata -NoNewline:$false
  Set-Content -LiteralPath (Join-Path -Path $seedDirectory -ChildPath 'user-data') -Value $userData -NoNewline:$false

  if (-not [string]::IsNullOrWhiteSpace($NetworkConfig)) {
    Set-Content -LiteralPath (Join-Path -Path $seedDirectory -ChildPath 'network-config') -Value $NetworkConfig -NoNewline:$false
  }

  return $seedDirectory
}

function Import-DotEnv {
  <#
  .SYNOPSIS
    Loads KEY=VALUE pairs from a .env file into a hashtable.
  .DESCRIPTION
    Parses a dotenv file, ignoring blank lines and '#' comments, splitting on the first '='
    and stripping matching surrounding quotes. This function never writes the values to output
    or logs; treat the returned hashtable as sensitive and keep it out of the repository.
  .OUTPUTS
    A hashtable of key/value pairs.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw ".env file not found: $Path"
  }

  $values = @{}
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
      continue
    }
    $separatorIndex = $line.IndexOf('=')
    if ($separatorIndex -lt 1) {
      continue
    }
    $key = $line.Substring(0, $separatorIndex).Trim()
    $value = $line.Substring($separatorIndex + 1).Trim()
    if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'")))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $values[$key] = $value
  }

  return $values
}

function Get-AutoinstallUserData {
  <#
  .SYNOPSIS
    Renders an Ubuntu autoinstall user-data document from a template and secret values.
  .DESCRIPTION
    Substitutes the template placeholders and expands the SSH authorized-keys list from the
    supplied values (typically loaded with Import-DotEnv). The returned string contains
    credentials and is intended to be written only to the seed staging area outside the
    repository; it must never be committed or logged.
  .OUTPUTS
    The rendered autoinstall user-data as a string.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$TemplatePath,

    [Parameter(Mandatory)]
    [hashtable]$Values,

    [Parameter(Mandatory)]
    [string]$Hostname
  )

  if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "autoinstall template not found: $TemplatePath"
  }

  $required = @(
    'LAB_AUTOINSTALL_USERNAME',
    'LAB_AUTOINSTALL_FULL_NAME',
    'LAB_AUTOINSTALL_PASSWORD_HASH',
    'LAB_AUTOINSTALL_SSH_AUTHORIZED_KEYS'
  )
  $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([string]$Values[$_]) })
  if ($missing.Count -gt 0) {
    throw ('Missing required autoinstall values: {0}' -f ($missing -join ', '))
  }

  $content = Get-Content -LiteralPath $TemplatePath -Raw
  $content = $content.Replace('${LAB_VM_HOSTNAME}', $Hostname)
  $content = $content.Replace('${LAB_AUTOINSTALL_FULL_NAME}', [string]$Values['LAB_AUTOINSTALL_FULL_NAME'])
  $content = $content.Replace('${LAB_AUTOINSTALL_USERNAME}', [string]$Values['LAB_AUTOINSTALL_USERNAME'])
  $content = $content.Replace('${LAB_AUTOINSTALL_PASSWORD_HASH}', [string]$Values['LAB_AUTOINSTALL_PASSWORD_HASH'])

  $keys = [string]$Values['LAB_AUTOINSTALL_SSH_AUTHORIZED_KEYS'] -split '[\r\n;]+' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
  $keyLines = ($keys | ForEach-Object { '      - {0}' -f $_ }) -join "`n"
  $content = $content.Replace('__SSH_AUTHORIZED_KEYS__', $keyLines)

  if ($content -match '\$\{[A-Z_]+\}' -or $content.Contains('__SSH_AUTHORIZED_KEYS__')) {
    throw 'autoinstall template still contains unresolved placeholders.'
  }

  return $content
}

function ConvertTo-WslPath {
  <#
  .SYNOPSIS
    Converts a Windows drive path to its WSL /mnt equivalent.
  .EXAMPLE
    ConvertTo-WslPath -Path 'E:\ISO\ubuntu.iso'  # -> /mnt/e/ISO/ubuntu.iso
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if ($Path -notmatch '^[A-Za-z]:[\\/]') {
    throw "Path must be a rooted Windows drive path (for example 'E:\ISO\file.iso'): $Path"
  }

  $drive = $Path.Substring(0, 1).ToLowerInvariant()
  $rest = $Path.Substring(2) -replace '\\', '/'
  $rest = $rest.TrimStart('/')
  return "/mnt/$drive/$rest"
}

function Add-AutoinstallKernelArgument {
  <#
  .SYNOPSIS
    Injects one or more kernel arguments (default 'autoinstall') into the GRUB kernel lines.
  .DESCRIPTION
    Adds the requested arguments immediately after the Ubuntu casper kernel image on every
    'linux /casper/vmlinuz ...' line, skipping arguments that are already present. Idempotent.
  .OUTPUTS
    The modified GRUB configuration text.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$GrubConfiguration,

    [string[]]$KernelArguments = @('autoinstall')
  )

  $lines = $GrubConfiguration -split "`r?`n"
  $found = $false

  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch 'vmlinuz') {
      continue
    }
    $found = $true
    $indent = [regex]::Match($lines[$i], '^\s*').Value
    $tokens = @($lines[$i] -split '\s+' | Where-Object { $_ -ne '' })

    $vmIndex = -1
    for ($j = 0; $j -lt $tokens.Count; $j++) {
      if ($tokens[$j] -like '*vmlinuz*') { $vmIndex = $j; break }
    }
    if ($vmIndex -lt 0) { continue }

    $missing = @($KernelArguments | Where-Object { $tokens -notcontains $_ })
    if ($missing.Count -eq 0) { continue }

    $newTokens = @($tokens[0..$vmIndex]) + $missing
    if ($vmIndex -lt ($tokens.Count - 1)) {
      $newTokens += $tokens[($vmIndex + 1)..($tokens.Count - 1)]
    }
    $lines[$i] = $indent + ($newTokens -join ' ')
  }

  if (-not $found) {
    throw 'No /casper/vmlinuz kernel line found in the GRUB configuration.'
  }

  return ($lines -join "`n")
}

function Resolve-EltoritoBootImage {
  <#
  .SYNOPSIS
    Locates the BIOS and UEFI El Torito boot images extracted by 7-Zip from an ISO.
  .DESCRIPTION
    7-Zip exposes the boot images under a synthetic '[BOOT]' directory (for example
    '1-Boot-NoEmul.img' for BIOS and '2-Boot-NoEmul.img' for UEFI). This resolves those images
    by their numeric prefix, falling back to enumeration order, so oscdimg can rebuild a hybrid
    bootable ISO.
  .OUTPUTS
    A hashtable with 'Bios' and 'Uefi' full paths (either may be $null).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ExtractDirectory
  )

  $bootDir = Join-Path -Path $ExtractDirectory -ChildPath '[BOOT]'
  if (-not (Test-Path -LiteralPath $bootDir)) {
    throw "El Torito '[BOOT]' directory not found under: $ExtractDirectory"
  }

  $images = @(Get-ChildItem -LiteralPath $bootDir -Filter '*.img' -File | Sort-Object Name)
  if ($images.Count -eq 0) {
    throw "No boot images (*.img) found in: $bootDir"
  }

  $bios = $images | Where-Object { $_.Name -match '^1' } | Select-Object -First 1
  $uefi = $images | Where-Object { $_.Name -match '^2' } | Select-Object -First 1
  if (-not $bios -and $images.Count -ge 1) { $bios = $images[0] }
  if (-not $uefi -and $images.Count -ge 2) { $uefi = $images[1] }

  $biosPath = if ($bios) { $bios.FullName } else { $null }
  $uefiPath = if ($uefi) { $uefi.FullName } else { $null }
  return @{ Bios = $biosPath; Uefi = $uefiPath }
}

function Get-LabAnsibleInventory {
  <#
  .SYNOPSIS
    Generates an Ansible YAML inventory from the lab configuration.
  .DESCRIPTION
    Groups virtual machines by their declared role and emits an inventory that matches the
    layout under ansible/inventories/lab. The static lab IP address (with any CIDR suffix
    stripped) is used as ansible_host so the Hyper-V configuration remains the single source
    of truth for host addressing. Output is deterministic (hosts and groups are sorted).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  $plan = Get-LabVmPlan -Configuration $Configuration

  $groups = [System.Collections.Specialized.OrderedDictionary]::new()
  foreach ($vm in ($plan.Vms | Sort-Object -Property Name)) {
    $groupName = if ([string]::IsNullOrWhiteSpace($vm.Role)) { 'ungrouped' } else { $vm.Role }
    if (-not $groups.Contains($groupName)) {
      $groups[$groupName] = [System.Collections.Generic.List[hashtable]]::new()
    }
    $address = $null
    if ($vm.IpAddress) {
      $address = ($vm.IpAddress -split '/')[0]
    }
    $groups[$groupName].Add(@{ Name = $vm.Name; Address = $address })
  }

  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine('all:')
  [void]$builder.AppendLine('  children:')
  foreach ($groupName in ($groups.Keys | Sort-Object)) {
    [void]$builder.AppendLine(('    {0}:' -f $groupName))
    [void]$builder.AppendLine('      hosts:')
    foreach ($entry in $groups[$groupName]) {
      [void]$builder.AppendLine(('        {0}:' -f $entry.Name))
      if ($entry.Address) {
        [void]$builder.AppendLine(('          ansible_host: {0}' -f $entry.Address))
      }
    }
  }

  return $builder.ToString().TrimEnd() + "`n"
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

function Get-OscdimgPath {
  <#
  .SYNOPSIS
    Resolves the full path to oscdimg.exe from PATH or well-known Windows ADK locations.
  .DESCRIPTION
    oscdimg.exe ships with the Windows ADK "Deployment Tools" and is usually not added to
    PATH. This helper checks PATH first, then the standard ADK install directories under
    Program Files, preferring the amd64 build.
  .OUTPUTS
    The full path to oscdimg.exe, or $null when it cannot be found.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $command = Get-Command -Name 'oscdimg.exe' -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $roots = @()
  if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
  if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }

  foreach ($root in $roots) {
    $deploymentTools = Join-Path -Path $root -ChildPath 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    if (-not (Test-Path -LiteralPath $deploymentTools)) {
      continue
    }
    $candidates = Get-ChildItem -Path $deploymentTools -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue
    $preferred = $candidates | Where-Object { $_.FullName -match '\\amd64\\' } | Select-Object -First 1
    if ($preferred) {
      return $preferred.FullName
    }
    if ($candidates) {
      return ($candidates | Select-Object -First 1).FullName
    }
  }

  return $null
}

function Test-OscdimgAvailable {
  <#
  .SYNOPSIS
    Indicates whether oscdimg.exe (Windows ADK) can be located on this host.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  return [bool](Get-OscdimgPath)
}

function New-CloudInitSeedImage {
  <#
  .SYNOPSIS
    Builds a cloud-init NoCloud seed ISO from a staging directory using oscdimg.exe.
  .DESCRIPTION
    The ISO is labelled 'cidata' so cloud-init's NoCloud data source discovers it automatically
    when the disk is attached to the guest. Requires oscdimg.exe from the Windows ADK.
  .OUTPUTS
    The absolute path to the ISO that was created.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$SeedDirectory,

    [Parameter(Mandatory)]
    [string]$OutputIsoPath,

    [string]$OscdimgPath
  )

  if (-not (Test-Path -LiteralPath $SeedDirectory)) {
    throw "cloud-init seed directory not found: $SeedDirectory"
  }

  if ([string]::IsNullOrWhiteSpace($OscdimgPath)) {
    $OscdimgPath = Get-OscdimgPath
  }
  if ([string]::IsNullOrWhiteSpace($OscdimgPath) -or -not (Test-Path -LiteralPath $OscdimgPath)) {
    throw 'oscdimg.exe could not be located. Install the Windows ADK (Deployment Tools) or pass -OscdimgPath.'
  }

  if (-not $PSCmdlet.ShouldProcess($OutputIsoPath, 'Build cloud-init NoCloud seed image')) {
    return $OutputIsoPath
  }

  $isoDirectory = Split-Path -Path $OutputIsoPath -Parent
  if ($isoDirectory -and -not (Test-Path -LiteralPath $isoDirectory)) {
    New-Item -ItemType Directory -Path $isoDirectory -Force | Out-Null
  }

  if (Test-Path -LiteralPath $OutputIsoPath) {
    Remove-Item -LiteralPath $OutputIsoPath -Force
  }

  $oscdimgOutput = & $OscdimgPath '-lcidata' '-j2' '-m' '-o' $SeedDirectory $OutputIsoPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "oscdimg.exe failed with exit code $LASTEXITCODE while building '$OutputIsoPath': $oscdimgOutput"
  }

  return $OutputIsoPath
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

function New-AutoinstallIso {
  <#
  .SYNOPSIS
    Builds an autoinstall-enabled Ubuntu Server ISO from a source ISO.
  .DESCRIPTION
    Injects the 'autoinstall' kernel argument into the ISO's GRUB configuration and repacks a
    UEFI-bootable ISO. No credentials are placed in the ISO; the per-VM cloud-init cidata seed
    supplies the autoinstall data at install time.

    Engines:
      wsl     - (default) host WSL + xorriso; '-boot_image any replay' preserves the exact boot
                structure and Rock Ridge/Joliet metadata (most faithful). Requires xorriso in WSL.
      docker  - same xorriso pipeline inside a container (installs xorriso per run; slower).
      oscdimg - fully native Windows: 7-Zip extracts the ISO, the GRUB configs are edited, and
                oscdimg.exe (Windows ADK) repacks a hybrid BIOS+UEFI ISO. No WSL/Docker needed.
                Note: oscdimg does not write Rock Ridge extensions, so on-ISO symlinks are not
                preserved (boot/install still work; offline apt from the ISO pool may not).

    Idempotent: an existing output ISO is reused unless -Force is set.
  .OUTPUTS
    The absolute path to the autoinstall ISO.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$SourceIsoPath,

    [Parameter(Mandatory)]
    [string]$OutputIsoPath,

    [string[]]$KernelArguments = @('autoinstall'),

    [ValidateSet('wsl', 'docker', 'oscdimg')]
    [string]$Engine = 'wsl',

    [string]$WslDistribution,

    [string]$DockerImage = 'ubuntu:24.04',

    [string]$VolumeLabel = 'UBUNTU_AUTO',

    [switch]$Force
  )

  if (-not (Test-Path -LiteralPath $SourceIsoPath)) {
    throw "source ISO not found: $SourceIsoPath"
  }
  if ((Test-Path -LiteralPath $OutputIsoPath) -and -not $Force) {
    Write-Verbose "Autoinstall ISO '$OutputIsoPath' already exists; reusing it (use -Force to rebuild)."
    return $OutputIsoPath
  }
  if (-not $PSCmdlet.ShouldProcess($OutputIsoPath, "Build autoinstall ISO from $SourceIsoPath")) {
    return $OutputIsoPath
  }

  $workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('autoinstall-iso-{0}' -f ([guid]::NewGuid()))
  New-Item -ItemType Directory -Path $workDir -Force | Out-Null
  $grubHostPath = Join-Path -Path $workDir -ChildPath 'grub.cfg'

  Write-LabStatus ("Building autoinstall ISO ({0}) from '{1}' - this can take a few minutes..." -f $Engine, (Split-Path -Path $SourceIsoPath -Leaf)) -Level Step

  try {
    switch ($Engine) {
      'wsl' {
        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
          throw 'wsl.exe is not available. Install WSL with an Ubuntu distribution or use -Engine docker/oscdimg.'
        }
        $distroArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($WslDistribution)) { $distroArgs = @('-d', $WslDistribution) }

        $wslIso = ConvertTo-WslPath -Path $SourceIsoPath
        $wslOut = ConvertTo-WslPath -Path $OutputIsoPath
        $wslGrub = ConvertTo-WslPath -Path $grubHostPath

        $extract = "set -e; command -v osirrox >/dev/null 2>&1 || { echo MISSING_XORRISO; exit 3; }; osirrox -indev '$wslIso' -extract /boot/grub/grub.cfg '$wslGrub'"
        Write-LabStatus 'Extracting GRUB config via WSL/xorriso...'
        $extractOut = & wsl @distroArgs -- bash -lc $extract 2>&1
        if ($LASTEXITCODE -eq 3 -or ($extractOut -match 'MISSING_XORRISO')) {
          $install = 'sudo apt-get update && sudo apt-get install -y xorriso'
          if ($distroArgs.Count -gt 0) { $install = "wsl -d $WslDistribution $install" } else { $install = "wsl $install" }
          throw "xorriso is not installed in WSL. Install it with: $install"
        }
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to extract grub.cfg via WSL (exit $LASTEXITCODE): $extractOut"
        }

        $null = Update-GrubConfigFile -Path $grubHostPath -KernelArguments $KernelArguments

        $repack = "set -e; xorriso -indev '$wslIso' -outdev '$wslOut' -boot_image any replay -map '$wslGrub' /boot/grub/grub.cfg -end"
        Write-LabStatus 'Repacking bootable ISO via WSL/xorriso...'
        $repackOut = & wsl @distroArgs -- bash -lc $repack 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to repack ISO via WSL (exit $LASTEXITCODE): $repackOut"
        }
      }

      'docker' {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
          throw 'docker is not available. Install Docker or use -Engine wsl/oscdimg.'
        }
        $isoDir = (Split-Path -Path $SourceIsoPath -Parent) -replace '\\', '/'
        $isoName = Split-Path -Path $SourceIsoPath -Leaf
        $outDir = (Split-Path -Path $OutputIsoPath -Parent) -replace '\\', '/'
        $outName = Split-Path -Path $OutputIsoPath -Leaf
        $workDirFwd = $workDir -replace '\\', '/'
        $aptPrefix = 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq xorriso >/dev/null 2>&1;'

        $extract = "set -e; $aptPrefix osirrox -indev '/iso/$isoName' -extract /boot/grub/grub.cfg /work/grub.cfg"
        Write-LabStatus 'Extracting GRUB config via Docker/xorriso (installing xorriso in container)...'
        $extractOut = & docker run --rm -v "${isoDir}:/iso:ro" -v "${workDirFwd}:/work" $DockerImage bash -lc $extract 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to extract grub.cfg via Docker (exit $LASTEXITCODE): $extractOut"
        }

        $null = Update-GrubConfigFile -Path $grubHostPath -KernelArguments $KernelArguments

        $repack = "set -e; $aptPrefix xorriso -indev '/iso/$isoName' -outdev '/out/$outName' -boot_image any replay -map /work/grub.cfg /boot/grub/grub.cfg -end"
        Write-LabStatus 'Repacking bootable ISO via Docker/xorriso...'
        $repackOut = & docker run --rm -v "${isoDir}:/iso:ro" -v "${workDirFwd}:/work" -v "${outDir}:/out" $DockerImage bash -lc $repack 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to repack ISO via Docker (exit $LASTEXITCODE): $repackOut"
        }
      }

      'oscdimg' {
        $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if (-not $sevenZip) { $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue }
        if (-not $sevenZip) {
          throw '7-Zip (7z) was not found. Install 7-Zip (or add it to PATH), or use -Engine wsl/docker.'
        }
        $oscdimgPath = Get-OscdimgPath
        if ([string]::IsNullOrWhiteSpace($oscdimgPath)) {
          throw 'oscdimg.exe was not found. Install the Windows ADK Deployment Tools, or use -Engine wsl/docker.'
        }

        $extractDir = Join-Path -Path $workDir -ChildPath 'extract'
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        Write-LabStatus 'Extracting installer ISO with 7-Zip...'
        $extractOut = & $sevenZip.Source x $SourceIsoPath "-o$extractDir" -y 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "7-Zip extraction failed (exit $LASTEXITCODE): $extractOut"
        }

        $grubCfg = Join-Path -Path $extractDir -ChildPath 'boot\grub\grub.cfg'
        if (-not (Test-Path -LiteralPath $grubCfg)) {
          throw "grub.cfg not found after extraction: $grubCfg"
        }
        Write-LabStatus 'Injecting autoinstall kernel argument into GRUB...'
        $null = Update-GrubConfigFile -Path $grubCfg -KernelArguments $KernelArguments

        $loopbackCfg = Join-Path -Path $extractDir -ChildPath 'boot\grub\loopback.cfg'
        if (Test-Path -LiteralPath $loopbackCfg) {
          try { $null = Update-GrubConfigFile -Path $loopbackCfg -KernelArguments $KernelArguments }
          catch { Write-Warning "Skipped loopback.cfg (no kernel line?): $($_.Exception.Message)" }
        }

        $boot = Resolve-EltoritoBootImage -ExtractDirectory $extractDir
        if ($boot.Bios -and $boot.Uefi) {
          $bootData = "-bootdata:2#p0,e,b$($boot.Bios)#pEF,e,b$($boot.Uefi)"
        }
        elseif ($boot.Uefi) {
          $bootData = "-bootdata:1#pEF,e,b$($boot.Uefi)"
        }
        elseif ($boot.Bios) {
          $bootData = "-bootdata:1#p0,e,b$($boot.Bios)"
        }
        else {
          throw 'No El Torito boot images were found in the extracted [BOOT] directory.'
        }

        if (Test-Path -LiteralPath $OutputIsoPath) {
          Remove-Item -LiteralPath $OutputIsoPath -Force
        }

        Write-LabStatus 'Repacking bootable ISO with oscdimg...'
        # Flags match the proven istio-practical-lab build (-m -o -j2 -bootdata:...); Joliet is what
        # GRUB/casper read on the Ubuntu ISO, so -j2 is the verified-bootable choice.
        $oscdimgOut = & $oscdimgPath -m -o -j2 $bootData "-l$VolumeLabel" $extractDir $OutputIsoPath 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "oscdimg.exe failed (exit $LASTEXITCODE): $oscdimgOut"
        }
      }
    }
  }
  finally {
    if (Test-Path -LiteralPath $workDir) {
      Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-LabStatus "Autoinstall ISO ready: $OutputIsoPath" -Level Success
  return $OutputIsoPath
}

function Update-GrubConfigFile {
  <#
  .SYNOPSIS
    Applies Add-AutoinstallKernelArgument to a grub.cfg file in place.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string[]]$KernelArguments = @('autoinstall')
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "grub.cfg not found (extraction may have failed): $Path"
  }
  if (-not $PSCmdlet.ShouldProcess($Path, 'Inject autoinstall kernel arguments')) {
    return $Path
  }

  $content = Get-Content -LiteralPath $Path -Raw
  $updated = Add-AutoinstallKernelArgument -GrubConfiguration $content -KernelArguments $KernelArguments
  Set-Content -LiteralPath $Path -Value $updated -NoNewline:$false
  return $Path
}

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

    [string]$EnvFile = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\.env'),

    [string]$AutoinstallTemplatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\cloud-init\autoinstall\user-data.template'),

    [switch]$BuildAutoinstallIso,

    [ValidateSet('wsl', 'docker', 'oscdimg')]
    [string]$IsoEngine = 'wsl',

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
        $userData = Get-AutoinstallUserData -TemplatePath $AutoinstallTemplatePath -Values $autoinstallValues -Hostname $vm.Hostname
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

  Write-LabStatus ("Provisioning complete: {0} of {1} VM(s) processed successfully." -f $vmCount, $vmCount) -Level Success
  if ($Autoinstall) {
    Write-LabStatus 'Next: start the VMs to run the unattended install; they reboot into the installed OS automatically (disk-first boot order).'
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

Export-ModuleMember -Function `
  Test-IsAdministrator, `
  Import-LabConfiguration, `
  Test-LabVmDefinition, `
  Get-DestructiveCleanupMessage, `
  ConvertTo-ByteCount, `
  Get-LabVmPlan, `
  Get-CloudInitInstanceId, `
  Get-CloudInitMetadata, `
  Get-CloudInitNetworkConfig, `
  New-CloudInitSeedStaging, `
  Import-DotEnv, `
  Get-AutoinstallUserData, `
  ConvertTo-WslPath, `
  Add-AutoinstallKernelArgument, `
  Resolve-EltoritoBootImage, `
  New-AutoinstallIso, `
  Get-LabAnsibleInventory, `
  Test-HyperVAvailable, `
  Test-OscdimgAvailable, `
  Get-OscdimgPath, `
  New-CloudInitSeedImage, `
  Add-LabCloudInitDisk, `
  Add-LabInstallMedia, `
  New-LabVirtualSwitch, `
  New-LabVirtualMachine, `
  Start-LabVirtualMachine, `
  Stop-LabVirtualMachine, `
  Remove-LabVirtualMachine, `
  Invoke-LabProvisioning, `
  Remove-LabEnvironment
