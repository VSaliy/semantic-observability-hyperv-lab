<#
.SYNOPSIS
  Provisions the Hyper-V observability lab from a declarative configuration file.

.DESCRIPTION
  Loads the lab configuration, validates it, and idempotently creates the virtual
  switches and virtual machines it declares. Requires an elevated PowerShell session
  on a Hyper-V enabled host. Supports -WhatIf and -Verbose through the module.

  Use -Rebuild for a clean rebuild: existing lab VMs and their disks are removed and
  recreated. Virtual switches (and any NAT) are always left in place.

.EXAMPLE
  ./provision-lab.ps1 -VhdRootPath 'D:\HyperV\VHDs' -ExternalNetAdapterName 'Ethernet'

.EXAMPLE
  ./provision-lab.ps1 -VhdRootPath 'D:\HyperV\VHDs' -CloudInitSourcePath ../cloud-init -Rebuild

.NOTES
  For a dry run, import HyperVLab.psm1 and call Invoke-LabProvisioning with -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/lab-config.yaml'),

  [Parameter(Mandatory)]
  [string]$VhdRootPath,

  [string]$ExternalNetAdapterName,

  [string]$CloudInitSourcePath,

  [string]$InstallIsoPath,

  [switch]$Autoinstall,

  [string]$EnvFile,

  [switch]$BuildAutoinstallIso,

  [ValidateSet('wsl', 'docker')]
  [string]$IsoEngine = 'wsl',

  [switch]$Rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'HyperVLab.psm1') -Force

if (-not (Test-IsAdministrator)) {
  throw 'Provisioning the Hyper-V lab requires an elevated PowerShell session.'
}

if (-not (Test-HyperVAvailable)) {
  throw 'Hyper-V cmdlets are not available. Enable the Hyper-V role before provisioning.'
}

Write-Verbose "Loading lab configuration from $ConfigPath"
$configuration = Import-LabConfiguration -Path $ConfigPath

$provisioningParameters = @{
  Configuration          = $configuration
  VhdRootPath            = $VhdRootPath
  ExternalNetAdapterName = $ExternalNetAdapterName
  Rebuild                = $Rebuild
}
if (-not [string]::IsNullOrWhiteSpace($CloudInitSourcePath)) {
  $provisioningParameters['CloudInitSourcePath'] = $CloudInitSourcePath
}
if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath)) {
  $provisioningParameters['InstallIsoPath'] = $InstallIsoPath
}
if ($Autoinstall) {
  $provisioningParameters['Autoinstall'] = $true
}
if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
  $provisioningParameters['EnvFile'] = $EnvFile
}
if ($BuildAutoinstallIso) {
  $provisioningParameters['BuildAutoinstallIso'] = $true
  $provisioningParameters['IsoEngine'] = $IsoEngine
}

Invoke-LabProvisioning @provisioningParameters

