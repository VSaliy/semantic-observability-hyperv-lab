Set-StrictMode -Version Latest

# Root module loader. Function definitions live in the lib subfolder and are
# dot-sourced below so they are defined in the module scope. Functions use
# $script:LabModuleRoot (not $PSScriptRoot, which inside a lib file resolves to
# the lib folder) for repository-relative default paths.
$script:LabModuleRoot = $PSScriptRoot

foreach ($labFunctionFile in (Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'lib') -Filter '*.ps1' -File | Sort-Object -Property Name)) {
    . $labFunctionFile.FullName
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
  Get-LabAnsibleInventory, `
  Test-HyperVAvailable, `
  New-LabVirtualSwitch, `
  New-LabVirtualMachine, `
  Start-LabVirtualMachine, `
  Stop-LabVirtualMachine, `
  Remove-LabVirtualMachine, `
  Get-OscdimgPath, `
  Test-OscdimgAvailable, `
  New-CloudInitSeedImage, `
  Add-LabCloudInitDisk, `
  Add-LabInstallMedia, `
  New-AutoinstallIso, `
  Invoke-LabProvisioning, `
  Remove-LabEnvironment, `
  New-LabNatNetwork, `
  Test-LabHostReadiness, `
  Test-LabTcpPort, `
  Clear-LabSshKnownHost, `
  Wait-LabNodeSsh, `
  Start-LabEnvironment, `
  Stop-LabEnvironment, `
  Get-LabStatus