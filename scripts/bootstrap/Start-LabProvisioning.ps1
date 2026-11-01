<#
.SYNOPSIS
  One-touch entry point that provisions the whole Hyper-V observability lab end to end.

.DESCRIPTION
  Chains every provisioning stage into a single command so the lab can be brought up
  hands-off from a Windows Hyper-V host:

    1. Host readiness precheck (elevation, Hyper-V, RAM/disk, tooling, ISO).
    2. Hyper-V provisioning: virtual switches + VMs + cloud-init/autoinstall seeds,
       then power the VMs on (Invoke-LabProvisioning -StartVms).
    3. Bridge: clear stale SSH host keys and block until every node answers on TCP 22.
    4. Regenerate the Ansible inventory from the same lab config (single source of truth).
    5. Linux/Kubernetes bootstrap: node baseline + kubeadm cluster + platform add-ons +
       declarative manifests + tenant Terraform (scripts/deployment/bootstrap-cluster.sh).

  Stages 1-4 run natively on the Windows host. Stage 5 runs the repository's bash
  bootstrap script through WSL (default) or a bash already on PATH, or is skipped with
  -SkipClusterBootstrap so you can run it later from the admin node.

  The script is idempotent: re-running converges the lab (existing switches/VMs are kept,
  kubeadm/Helm/Terraform steps are guarded). Use -Rebuild to recreate the VMs cleanly.

.EXAMPLE
  # Fully unattended: remaster the installer ISO, autoinstall Ubuntu, then bootstrap K8s.
  ./scripts/bootstrap/Start-LabProvisioning.ps1 `
    -VhdRootPath 'C:\HyperV\VHDs' `
    -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
    -Autoinstall -BuildAutoinstallIso

.EXAMPLE
  # Provision + start + wait only; run the cluster bootstrap yourself later.
  ./scripts/bootstrap/Start-LabProvisioning.ps1 -VhdRootPath 'C:\HyperV\VHDs' -SkipClusterBootstrap

.NOTES
  Run from an ELEVATED PowerShell session on the Hyper-V host. Requires the powershell-yaml
  module (ConvertFrom-Yaml). Autoinstall needs a gitignored .env (see hyperv/README.md) and
  oscdimg.exe (Windows ADK). The cluster bootstrap needs WSL (or bash) with ansible-playbook,
  kubectl, and terraform available, plus a kubeconfig reachable from the controller.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string]$VhdRootPath,

  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\hyperv\config\lab-config.yaml'),

  [string]$CloudInitSourcePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\hyperv\cloud-init'),

  [string]$ExternalNetAdapterName,

  [string]$InstallIsoPath,

  [switch]$Autoinstall,

  [switch]$BuildAutoinstallIso,

  [ValidateSet('wsl', 'docker', 'oscdimg')]
  [string]$IsoEngine = 'wsl',

  [string]$EnvFile,

  [switch]$DynamicMemory,

  [switch]$Rebuild,

  [int]$SshWaitTimeoutMinutes = 60,

  [switch]$SkipReadinessCheck,

  [switch]$SkipClusterBootstrap,

  # How to run the bash cluster bootstrap from Windows.
  [ValidateSet('wsl', 'bash')]
  [string]$ClusterBootstrapEngine = 'wsl',

  # kubeconfig path as seen by the cluster-bootstrap engine (Linux/WSL path).
  [string]$KubeconfigPath = '$HOME/.kube/config'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'hyperv\powershell\HyperVLab.psm1'
Import-Module -Name $modulePath -Force

# Local status helper (the module's Write-LabStatus is internal / not exported).
function Write-Status {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Message,
    [ValidateSet('Info', 'Step', 'Success', 'Warning')][string]$Level = 'Info'
  )
  $prefix = switch ($Level) { 'Step' { '==>' } 'Success' { '[ OK ]' } 'Warning' { '[WARN]' } default { '  -' } }
  $color = switch ($Level) { 'Step' { 'Cyan' } 'Success' { 'Green' } 'Warning' { 'Yellow' } default { 'Gray' } }
  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

# --- Preconditions ---------------------------------------------------------
if (-not (Test-IsAdministrator)) {
  throw 'Provisioning the Hyper-V lab requires an ELEVATED PowerShell session.'
}
if (-not (Test-HyperVAvailable)) {
  throw 'Hyper-V cmdlets are not available. Enable the Hyper-V role before provisioning.'
}

Write-Status 'Loading lab configuration...' -Level Step
$configuration = Import-LabConfiguration -Path $ConfigPath

# Resolve the installer ISO from config if not passed explicitly.
if ([string]::IsNullOrWhiteSpace($InstallIsoPath) -and $configuration['installIso']) {
  $InstallIsoPath = [string]$configuration['installIso']
}

# --- Stage 1: host readiness precheck --------------------------------------
if (-not $SkipReadinessCheck) {
  Write-Status 'Stage 1/5: host readiness precheck...' -Level Step
  $readinessParameters = @{ VhdRootPath = $VhdRootPath; RequireYaml = $true }
  if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath)) {
    $readinessParameters['InstallIsoPath'] = $InstallIsoPath
  }
  $readiness = Test-LabHostReadiness @readinessParameters
  if (-not $readiness.Passed) {
    $readiness.Failures | ForEach-Object { Write-Status $_ -Level Warning }
    throw 'Host readiness precheck failed. Resolve the issues above or re-run with -SkipReadinessCheck.'
  }
  Write-Status 'Host readiness precheck passed.' -Level Success
}

# --- Stage 2: Hyper-V provisioning + start ---------------------------------
Write-Status 'Stage 2/5: provisioning Hyper-V switches and VMs...' -Level Step
$provisioningParameters = @{
  Configuration       = $configuration
  VhdRootPath         = $VhdRootPath
  CloudInitSourcePath = $CloudInitSourcePath
  StartVms            = $true
  Rebuild             = $Rebuild
  DynamicMemory       = $DynamicMemory
}
if (-not [string]::IsNullOrWhiteSpace($ExternalNetAdapterName)) {
  $provisioningParameters['ExternalNetAdapterName'] = $ExternalNetAdapterName
}
if (-not [string]::IsNullOrWhiteSpace($InstallIsoPath)) {
  $provisioningParameters['InstallIsoPath'] = $InstallIsoPath
}
if ($Autoinstall) { $provisioningParameters['Autoinstall'] = $true }
if ($BuildAutoinstallIso) {
  $provisioningParameters['BuildAutoinstallIso'] = $true
  $provisioningParameters['IsoEngine'] = $IsoEngine
}
if (-not [string]::IsNullOrWhiteSpace($EnvFile)) { $provisioningParameters['EnvFile'] = $EnvFile }

if (-not $PSCmdlet.ShouldProcess('Hyper-V lab', 'Provision and start virtual machines')) {
  return
}
Invoke-LabProvisioning @provisioningParameters

# Derive the node addresses (CIDR suffix stripped) from the same plan.
$plan = Get-LabVmPlan -Configuration $configuration
$nodeAddresses = @(
  $plan.Vms |
    Where-Object { $_.IpAddress } |
    ForEach-Object { ($_.IpAddress -split '/')[0] }
)
if ($nodeAddresses.Count -eq 0) {
  throw 'No node IP addresses found in the configuration; cannot wait for SSH.'
}

# --- Stage 3: bridge to configuration (wait for SSH) -----------------------
Write-Status 'Stage 3/5: waiting for nodes to become reachable over SSH...' -Level Step
Clear-LabSshKnownHost -HostName $nodeAddresses -Confirm:$false
[void](Wait-LabNodeSsh -Address $nodeAddresses -TimeoutMinutes $SshWaitTimeoutMinutes)
Write-Status 'All nodes are reachable over SSH.' -Level Success

# --- Stage 4: regenerate the Ansible inventory -----------------------------
Write-Status 'Stage 4/5: regenerating the Ansible inventory from lab config...' -Level Step
$inventoryPath = Join-Path -Path $repoRoot -ChildPath 'ansible\inventories\lab\hosts.yml'
$inventory = Get-LabAnsibleInventory -Configuration $configuration
Set-Content -LiteralPath $inventoryPath -Value $inventory -Encoding utf8
Write-Status ("Inventory written to {0}." -f $inventoryPath) -Level Success

# --- Stage 5: Linux + Kubernetes bootstrap ---------------------------------
if ($SkipClusterBootstrap) {
  Write-Status 'Stage 5/5: skipped (-SkipClusterBootstrap).' -Level Step
  Write-Status 'Nodes are provisioned and reachable. Run the cluster bootstrap from a controller with ansible-playbook/kubectl/terraform:'
  Write-Status '  ./scripts/deployment/bootstrap-cluster.sh'
  return
}

Write-Status 'Stage 5/5: bootstrapping node baseline, Kubernetes cluster, and tenants...' -Level Step
$bootstrapScriptRel = 'scripts/deployment/bootstrap-cluster.sh'

if ($ClusterBootstrapEngine -eq 'wsl') {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL was not found. Install WSL (with ansible-playbook, kubectl, terraform) or use -ClusterBootstrapEngine bash, or -SkipClusterBootstrap and run the bootstrap from the admin node.'
  }
  $wslRepoRoot = ConvertTo-WslPath -Path $repoRoot
  $remoteCommand = "cd '$wslRepoRoot' && KUBECONFIG='$KubeconfigPath' bash '$bootstrapScriptRel'"
  Write-Status ("Running cluster bootstrap via WSL: {0}" -f $remoteCommand)
  & wsl.exe -e bash -lc $remoteCommand
  if ($LASTEXITCODE -ne 0) { throw "Cluster bootstrap failed (WSL exit code $LASTEXITCODE)." }
}
else {
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if (-not $bash) {
    throw 'bash was not found on PATH. Use -ClusterBootstrapEngine wsl, or -SkipClusterBootstrap and run the bootstrap from the admin node.'
  }
  $bootstrapScript = Join-Path -Path $repoRoot -ChildPath 'scripts\deployment\bootstrap-cluster.sh'
  Write-Status ("Running cluster bootstrap via bash: {0}" -f $bootstrapScript)
  $env:KUBECONFIG = $KubeconfigPath
  & $bash.Source $bootstrapScript
  if ($LASTEXITCODE -ne 0) { throw "Cluster bootstrap failed (bash exit code $LASTEXITCODE)." }
}

Write-Status 'Lab provisioning complete: Hyper-V VMs, Kubernetes cluster, platform add-ons, and tenants are up.' -Level Success

