# Hyper-V lab automation (Milestone 2)

VM lifecycle and cloud-init automation for the Linux guests that host the
Kubernetes platform in later milestones. The logic lives in
`powershell/HyperVLab.psm1` and is driven by the declarative
`config/lab-config.yaml`.

## Lab topology

`config/lab-config.yaml` and `../ansible/inventories/lab/hosts.yml` describe the
same four guests on the `Observability-Internal` switch (10.50.0.0/24):

| VM | Role | vCPU | Memory | Disk | IP |
| --- | --- | --- | --- | --- | --- |
| `obs-admin` | admin | 2 | 4 GB | 60 GB | 10.50.0.10 |
| `k8s-cp1` | kubernetes | 4 | 6 GB | 80 GB | 10.50.0.11 |
| `k8s-worker1` | kubernetes | 4 | 6 GB | 80 GB | 10.50.0.12 |
| `k8s-worker2` | kubernetes | 4 | 6 GB | 80 GB | 10.50.0.13 |

Each guest also gets a DHCP NIC on the `External-Lab` switch for internet access.

## What the module does

- `Import-LabConfiguration` / `Get-LabVmPlan` — parse and normalize the config
  into a provider-agnostic plan (byte counts, switch types, per-VM addressing).
- `New-LabVirtualSwitch` / `New-LabVirtualMachine` — idempotently create
  Generation 2 switches and VMs (skip if they already exist).
- `Start-/Stop-/Remove-LabVirtualMachine`, `Remove-LabEnvironment` — lifecycle
  operations with `ShouldProcess` (`-WhatIf` / `-Confirm`) safety.
- Cloud-init (NoCloud) seeding:
  - `Get-CloudInitMetadata` / `Get-CloudInitNetworkConfig` — deterministic
    `meta-data` and netplan v2 `network-config`.
  - `New-CloudInitSeedStaging` — assemble `meta-data`, `user-data`,
    `network-config` per VM.
  - `New-CloudInitSeedImage` — build a `cidata`-labelled ISO with `oscdimg.exe`.
  - `Add-LabCloudInitDisk` — attach the seed ISO as a DVD drive.
- `Get-LabAnsibleInventory` — render the Ansible inventory from the same config
  so host addressing has a single source of truth.
- `Invoke-LabProvisioning` — orchestrates switches, VMs, and (optionally)
  cloud-init seeds end to end.

## Provision the lab

Run from an **elevated** PowerShell session on a Hyper-V host:

```powershell
Import-Module ./hyperv/powershell/HyperVLab.psm1
$config = Import-LabConfiguration -Path ./hyperv/config/lab-config.yaml

# Dry run first.
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'D:\HyperV\VHDs' -WhatIf

# Provision VMs and attach cloud-init seeds (requires oscdimg.exe from the Windows ADK).
Invoke-LabProvisioning `
  -Configuration $config `
  -VhdRootPath 'D:\HyperV\VHDs' `
  -CloudInitSourcePath ./hyperv/cloud-init
```

`provision-lab.ps1` wraps the same flow with prerequisite checks. Requires
`ConvertFrom-Yaml` (the `powershell-yaml` module) to load YAML configuration.

## Re-running, clean rebuild, and teardown

Provisioning is **idempotent**: existing switches and VMs are detected by name
and skipped, so a plain re-run only fills in what is missing. You do not need to
remove anything between normal runs, and virtual switches (and any NAT) are never
deleted by the tooling.

For a **clean rebuild** of the VMs (for example after changing CPU, memory, or
disk sizes), use `-Rebuild`. It removes each lab VM and its disk, then recreates
it. Switches and NAT are left in place:

```powershell
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'D:\HyperV\VHDs' -CloudInitSourcePath ./hyperv/cloud-init -Rebuild
# or via the wrapper:
./hyperv/powershell/provision-lab.ps1 -VhdRootPath 'D:\HyperV\VHDs' -CloudInitSourcePath ../cloud-init -Rebuild
```

To tear the lab down without recreating it:

```powershell
Remove-LabEnvironment -Configuration $config              # remove VMs, keep VHDX disks
Remove-LabEnvironment -Configuration $config -RemoveDisks  # remove VMs and delete VHDX disks
Remove-LabVirtualMachine -Name k8s-cp1 -RemoveDisks        # single VM + its disk
```

> A leftover `*.vhdx` (from a VM removed without `-RemoveDisks`) blocks
> recreation. `New-LabVirtualMachine` reports this clearly; `-Rebuild` / `-Force`
> deletes the stale disk automatically.

## Prerequisites

- Windows 11 Pro with the Hyper-V role enabled.
- An Ubuntu Server 24.04 Generation 2 base VHDX (or use the cloud image).
- `powershell-yaml` module for YAML parsing.
- Windows ADK "Deployment Tools" (`oscdimg.exe`) for cloud-init seed images
  (optional — seeding is skipped with a warning if it is missing).
- Add your SSH public key to the cloud-init files before provisioning
  (see `cloud-init/README.md`).

## Tests

Pure functions (config parsing, byte math, cloud-init generation, inventory
rendering, lifecycle guards) are covered by Pester:

```powershell
Invoke-Pester -Path ./hyperv/tests
```

The suite mocks Hyper-V so it runs on any host without the Hyper-V role.
