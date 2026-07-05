<#
.SYNOPSIS
  Provisions the Hyper-V observability lab from a declarative configuration file.

.DESCRIPTION
  Loads the lab configuration, validates it, and idempotently creates the virtual
  switches and virtual machines it declares. Requires an elevated PowerShell session
  on a Hyper-V enabled host. Supports -WhatIf and -Verbose through the module.

.EXAMPLE
  ./provision-lab.ps1 -VhdRootPath 'D:\HyperV\VHDs' -ExternalNetAdapterName 'Ethernet'

.NOTES
  For a dry run, import HyperVLab.psm1 and call Invoke-LabProvisioning with -WhatIf.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/lab-config.yaml'),

  [Parameter(Mandatory)]
  [string]$VhdRootPath,

  [string]$ExternalNetAdapterName
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

Invoke-LabProvisioning `
  -Configuration $configuration `
  -VhdRootPath $VhdRootPath `
  -ExternalNetAdapterName $ExternalNetAdapterName

