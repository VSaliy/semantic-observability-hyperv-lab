Set-StrictMode -Version Latest

function Test-LabHostReadiness {
  <#
  .SYNOPSIS
    Validates Hyper-V host prerequisites, collecting all failures into one result.
  .DESCRIPTION
    Checks elevation, Windows edition, Hyper-V availability and service, RAM, free disk on the
    VHD drive, required cmdlets (optionally the NAT stack), YAML support, and the installer ISO.
    Every check runs so the caller sees all problems at once.
  .OUTPUTS
    A PSCustomObject with Passed (bool), Failures (string[]) and Warnings (string[]).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [long]$MinimumMemoryBytes = 16GB,

    [long]$MinimumFreeDiskBytes = 100GB,

    [string]$VhdRootPath,

    [string]$InstallIsoPath,

    [switch]$RequireNat,

    [switch]$RequireYaml
  )

  $failures = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()

  if (-not (Test-IsAdministrator)) {
    $failures.Add('Administrator privileges are required (run in an elevated session).')
  }

  try {
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
    if ($edition -notin @('Professional', 'Enterprise', 'Education', 'ServerStandard', 'ServerDatacenter')) {
      $warnings.Add("Windows edition '$edition' may not support Hyper-V.")
    }
  }
  catch {
    $warnings.Add('Could not determine the Windows edition.')
  }

  if (-not (Test-HyperVAvailable)) {
    $failures.Add('Hyper-V cmdlets are not available; enable the Hyper-V feature.')
  }
  $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
  if (-not $vmms) {
    $failures.Add('Hyper-V Virtual Machine Management service (vmms) is missing.')
  }
  elseif ($vmms.Status -ne 'Running') {
    $failures.Add("Hyper-V Virtual Machine Management service is '$($vmms.Status)'; start it or reboot.")
  }

  try {
    $memory = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    if ($memory -lt $MinimumMemoryBytes) {
      $failures.Add(('Insufficient RAM: {0:N0} GB (minimum {1:N0} GB).' -f ($memory / 1GB), ($MinimumMemoryBytes / 1GB)))
    }
  }
  catch {
    $warnings.Add('Could not determine physical memory.')
  }

  if (-not [string]::IsNullOrWhiteSpace($VhdRootPath)) {
    $qualifier = Split-Path -Path $VhdRootPath -Qualifier -ErrorAction SilentlyContinue
    if ($qualifier) {
      $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'" -ErrorAction SilentlyContinue
      if ($disk -and $disk.FreeSpace -lt $MinimumFreeDiskBytes) {
        $failures.Add(('Insufficient free space on {0}: {1:N0} GB (minimum {2:N0} GB).' -f $qualifier, ($disk.FreeSpace / 1GB), ($MinimumFreeDiskBytes / 1GB)))
      }
    }
  }

  $required = @('Get-VM', 'Get-VMSwitch')
  if ($RequireNat) {
    $required += @('New-NetNat', 'Get-NetRoute', 'New-NetIPAddress')
  }
  foreach ($command in $required) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
      $failures.Add("Required command missing: $command")
    }
  }

  if ($RequireYaml -and -not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    $failures.Add('PowerShell YAML support (ConvertFrom-Yaml) is missing. Install with: Install-Module powershell-yaml -Scope CurrentUser')
  }

  if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath) -and -not (Test-Path -LiteralPath $InstallIsoPath)) {
    $failures.Add("Installer ISO not found: $InstallIsoPath")
  }

  return [pscustomobject]@{
    Passed   = ($failures.Count -eq 0)
    Failures = $failures.ToArray()
    Warnings = $warnings.ToArray()
  }
}
