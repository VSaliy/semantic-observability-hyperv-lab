Set-StrictMode -Version Latest

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
    [string]$Hostname,

    [string]$StaticIpCidr,

    [string[]]$DnsServers = @('1.1.1.1', '9.9.9.9')
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

  # Render the installed-system netplan (eth0 = external/DHCP, eth1 = internal/static).
  # Applied by subiquity to the target because the NoCloud network-config does not reach
  # the installed OS in the autoinstall flow. Empty when no static IP is supplied.
  $networkBlock = ''
  if (-not [string]::IsNullOrWhiteSpace($StaticIpCidr)) {
    if ($StaticIpCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
      throw "StaticIpCidr must be in CIDR notation (for example '10.50.0.11/24'): $StaticIpCidr"
    }
    $dnsList = ($DnsServers | Where-Object { $_ }) -join ', '
    $networkBlock = @"
  network:
    version: 2
    ethernets:
      eth0:
        dhcp4: true
        optional: true
      eth1:
        dhcp4: false
        addresses:
          - $StaticIpCidr
        nameservers:
          addresses: [$dnsList]
"@.TrimEnd()
  }
  $content = $content.Replace('__NETWORK_CONFIG__', $networkBlock)

  if ($content -match '\$\{[A-Z_]+\}' -or $content.Contains('__SSH_AUTHORIZED_KEYS__') -or $content.Contains('__NETWORK_CONFIG__')) {
    throw 'autoinstall template still contains unresolved placeholders.'
  }

  return $content
}
