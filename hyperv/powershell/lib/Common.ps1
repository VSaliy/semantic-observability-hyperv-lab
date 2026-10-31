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
