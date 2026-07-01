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
  param([Parameter(Mandatory)][string]$Scope)

  return "Cleanup is destructive for $Scope. Re-run with -Confirm to continue."
}

Export-ModuleMember -Function Test-IsAdministrator,Import-LabConfiguration,Test-LabVmDefinition,Get-DestructiveCleanupMessage
