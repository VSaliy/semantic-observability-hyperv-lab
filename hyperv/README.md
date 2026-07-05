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

## Installing the guest OS

New VMs are created with **blank** VHDX disks, so they need an OS. Generation 2
VMs are created with the **Microsoft UEFI CA** Secure Boot template so Ubuntu
boots (the default Windows template would block it). There are two paths:

### Path A - Ubuntu cloud image (smoothest, zero-touch)

The cloud-init files in `cloud-init/` are **runtime** cloud-config, which is what
Ubuntu **cloud images** consume on first boot. Download
`ubuntu-24.04-server-cloudimg-amd64.img`, convert it to a VHDX, place it at
`<VhdRootPath>\<vm>.vhdx`, and provision **without** `-Rebuild` (so the prepared
disk is kept). The attached NoCloud seed then configures the running guest.

### Path B - Ubuntu Server installer ISO (what you have at `E:\ISO`)

Attach the installer and boot it. Provisioning sets the ISO as the first boot
device automatically:

```powershell
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'D:\HyperV\VHDs' `
  -CloudInitSourcePath ./hyperv/cloud-init `
  -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso'
# or set installIso in lab-config.yaml, or use provision-lab.ps1 -InstallIsoPath
```

Then install the OS one of two ways:

- **Manual:** open each VM's console and click through the Ubuntu Server
  installer. The runtime cloud-config in `cloud-init/` does **not** drive the
  installer, so configure the user and SSH key during setup.
- **Unattended (autoinstall):** run provisioning with `-Autoinstall`. Secrets are
  read from a gitignored `.env` and rendered into a per-VM autoinstall seed:

  ```powershell
  Copy-Item .env.example .env   # then edit .env with real values (never commit it)
  Invoke-LabProvisioning -Configuration $config -VhdRootPath 'D:\HyperV\VHDs' `
    -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' -Autoinstall
  # or: ./hyperv/powershell/provision-lab.ps1 -VhdRootPath 'D:\HyperV\VHDs' `
  #        -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' -Autoinstall
  ```

  The autoinstall template lives at `cloud-init/autoinstall/user-data.template`
  and contains **placeholders only**. `Import-DotEnv` loads the secrets and
  `Get-AutoinstallUserData` renders them into `user-data`, which is written to the
  seed staging area **outside the repository** (default
  `<VhdRootPath>\cloud-init-seeds`, gitignored). Secrets are never written into
  the repo or logged. Required `.env` keys:

  | Key | Purpose |
  | --- | --- |
  | `LAB_AUTOINSTALL_USERNAME` | Login account created on each guest |
  | `LAB_AUTOINSTALL_FULL_NAME` | Account display name |
  | `LAB_AUTOINSTALL_PASSWORD_HASH` | SHA-512 crypt hash (`openssl passwd -6`) |
  | `LAB_AUTOINSTALL_SSH_AUTHORIZED_KEYS` | One or more public keys (newline/`;` separated) |

  > A stock live-server ISO still asks to confirm autoinstall unless the
  > `autoinstall` kernel argument is added at the GRUB prompt (or the ISO is
  > repacked). Add it once per VM on first boot to run fully hands-off.

  **Fully automatic (recommended): remaster the ISO with `-BuildAutoinstallIso`.**
  This injects the `autoinstall` kernel argument into the installer ISO's GRUB
  config and repacks a UEFI-bootable `…-autoinstall.iso`, so no GRUB keypress is
  needed. It uses the **host WSL** installation and `xorriso` by default; pass
  `-IsoEngine docker` to build in a container instead.

  ```powershell
  # One-time in your WSL Ubuntu distro:
  Invoke-LabProvisioning -Configuration $config -VhdRootPath 'D:\HyperV\VHDs' `
    -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
    -Autoinstall -BuildAutoinstallIso            # add -IsoEngine docker to use Docker
  ```

  The remastered ISO is **secret-free** (it only carries the kernel flag); the
  credentials stay on the per-VM cidata seed. The build is idempotent — the
  `…-autoinstall.iso` is reused unless `-Rebuild` is set. You can also call the
  builder directly:

  ```powershell
  New-AutoinstallIso -SourceIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
    -OutputIsoPath 'E:\ISO\ubuntu-24.04.3-autoinstall.iso'   # -Engine docker optional
  ```

  > `xorriso`'s `-boot_image any replay` preserves the original UEFI boot
  > structure. `-Engine docker` installs `xorriso` in the container on each run
  > (slower); WSL is the faster default.

After the install finishes, detach the installer so the VM boots from disk:

```powershell
Get-VMDvdDrive -VMName k8s-cp1 | Where-Object { $_.Path -like '*live-server*' } | Set-VMDvdDrive -Path $null
Set-VMFirmware -VMName k8s-cp1 -FirstBootDevice (Get-VMHardDiskDrive -VMName k8s-cp1)
```

## Prerequisites

- Windows 11 Pro with the Hyper-V role enabled.
- A guest OS source: an Ubuntu 24.04 **cloud image** VHDX (Path A) or the
  **installer ISO** at, e.g., `E:\ISO\ubuntu-24.04.3-live-server-amd64.iso` (Path B).
- `powershell-yaml` module for YAML parsing.
- Windows ADK "Deployment Tools" (`oscdimg.exe`) for cloud-init seed images
  (optional — seeding is skipped with a warning if it is missing).
- For automatic autoinstall ISO remastering (`-BuildAutoinstallIso`): WSL with an
  Ubuntu distribution and `xorriso` installed (`sudo apt-get install -y xorriso`),
  or Docker (`-IsoEngine docker`).
- Add your SSH public key to the cloud-init files before provisioning
  (see `cloud-init/README.md`).

## Tests

Pure functions (config parsing, byte math, cloud-init generation, inventory
rendering, lifecycle guards) are covered by Pester:

```powershell
Invoke-Pester -Path ./hyperv/tests
```

The suite mocks Hyper-V so it runs on any host without the Hyper-V role.
