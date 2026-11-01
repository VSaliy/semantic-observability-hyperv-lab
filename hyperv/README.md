# Hyper-V lab automation (Milestone 2)

VM lifecycle and cloud-init automation for the Linux guests that host the
Kubernetes platform in later milestones. The logic lives in
`powershell/HyperVLab.psm1` and is driven by the declarative
`config/lab-config.yaml`.

## Module layout

`HyperVLab.psm1` is a thin loader: it sets `$script:LabModuleRoot`, dot-sources
every `powershell/lib/*.ps1` file into the module scope, and exports the public
functions. Functions are grouped by concern so each file stays small:

| File | Contents |
| --- | --- |
| `lib/Common.ps1` | Status output, admin/Hyper-V checks, byte parsing |
| `lib/Configuration.ps1` | Config load, validation, VM plan, Ansible inventory |
| `lib/HostReadiness.ps1` | `Test-LabHostReadiness` precheck |
| `lib/CloudInit.ps1` | NoCloud meta-data/network-config/seed, `.env`, autoinstall user-data |
| `lib/AutoinstallIso.ps1` | oscdimg/xorriso discovery, GRUB edit, ISO build (`New-AutoinstallIso`) |
| `lib/VirtualMachine.ps1` | Switch/VM create/start/stop/remove, media attach |
| `lib/Network.ps1` | `New-LabNatNetwork` (internal switch + WinNAT) |
| `lib/NodeReadiness.ps1` | TCP probe, SSH wait, known-hosts cleanup |
| `lib/Environment.ps1` | `Invoke-LabProvisioning`, lab start/stop/status/remove |

Consumers still just `Import-Module ./hyperv/powershell/HyperVLab.psm1` — the
split is internal. Functions use `$script:LabModuleRoot` (not `$PSScriptRoot`,
which inside `lib/` would point at the wrong folder) for repo-relative paths.

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
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' -WhatIf

# Provision VMs and attach cloud-init seeds (requires oscdimg.exe from the Windows ADK).
Invoke-LabProvisioning `
  -Configuration $config `
  -VhdRootPath 'C:\HyperV\VHDs' `
  -CloudInitSourcePath ./hyperv/cloud-init
```

`provision-lab.ps1` wraps the same flow with prerequisite checks. Requires
`ConvertFrom-Yaml` (the `powershell-yaml` module) to load YAML configuration.

## Starting the VMs

Provisioning creates the VMs **powered off** and does not start them (with
`-Autoinstall` a start triggers a destructive unattended install, so it's a
deliberate step). Power them on with:

```powershell
# Opt in during provisioning:
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' -Autoinstall -BuildAutoinstallIso -StartVms

# Or afterwards (idempotent, skips VMs already running):
$plan = Get-LabVmPlan -Configuration $config
$plan.Vms | ForEach-Object { Start-LabVirtualMachine -Name $_.Name }
```

> **Host RAM:** VMs use **fixed** startup memory by default, so all of it is
> reserved when the VM starts. If the sum exceeds free host RAM, later VMs fail
> to start (`Insufficient system resources`, `0x800705AA`). Provisioning warns
> up front and reports each start result. To fit more nodes on a small host,
> recreate them with Dynamic Memory: `Invoke-LabProvisioning … -DynamicMemory -Rebuild`
> (or reduce `memoryStartupBytes` in `lab-config.yaml`).

## Re-running, clean rebuild, and teardown

Provisioning is **idempotent**: existing switches and VMs are detected by name
and skipped, so a plain re-run only fills in what is missing. You do not need to
remove anything between normal runs, and virtual switches (and any NAT) are never
deleted by the tooling.

For a **clean rebuild** of the VMs (for example after changing CPU, memory, or
disk sizes), use `-Rebuild`. It removes each lab VM and its disk, then recreates
it. Switches and NAT are left in place:

```powershell
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' -CloudInitSourcePath ./hyperv/cloud-init -Rebuild
# or via the wrapper:
./hyperv/powershell/provision-lab.ps1 -VhdRootPath 'C:\HyperV\VHDs' -CloudInitSourcePath ../cloud-init -Rebuild
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
Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' `
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
  Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' `
    -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' -Autoinstall
  # or: ./hyperv/powershell/provision-lab.ps1 -VhdRootPath 'C:\HyperV\VHDs' `
  #        -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' -Autoinstall
  ```

  The autoinstall template lives at `cloud-init/autoinstall/user-data.template`
  and contains **placeholders only**. `Import-DotEnv` loads the secrets and
  `Get-AutoinstallUserData` renders them into `user-data`, which is written to the
  seed staging area **outside the repository** (default
  `<VhdRootPath>\cloud-init-seeds`, gitignored). Secrets are never written into
  the repo or logged. The template also sets `refresh-installer: {update: false}`
  (skips the slow subiquity self-update), `updates: security`, `shutdown: reboot`,
  and `late-commands` that enable SSH and passwordless sudo for the automation
  user so Ansible can connect immediately. Required `.env` keys:

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
  needed. Choose the engine with `-IsoEngine`:

  | Engine | Tooling | Notes |
  | --- | --- | --- |
  | `wsl` (default) | Host WSL + `xorriso` | Most faithful (`-boot_image any replay` preserves boot + Rock Ridge/Joliet). |
  | `docker` | Docker + `xorriso` | Same pipeline in a container; installs xorriso per run (slower). |
  | `oscdimg` | 7-Zip + ADK `oscdimg` | **Native Windows, no WSL/Docker.** Boots/installs fine; no Rock Ridge (on-ISO symlinks not preserved). |

  ```powershell
  # wsl engine one-time:  wsl sudo apt-get update; wsl sudo apt-get install -y xorriso
  Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\HyperV\VHDs' `
    -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
    -Autoinstall -BuildAutoinstallIso -IsoEngine wsl   # or: -IsoEngine oscdimg (native) / docker
  ```

  The remastered ISO is **secret-free** (it only carries the kernel flag); the
  credentials stay on the per-VM cidata seed. The build is idempotent — the
  `…-autoinstall.iso` is reused unless `-Rebuild` is set. You can also call the
  builder directly:

  ```powershell
  New-AutoinstallIso -SourceIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
    -OutputIsoPath 'E:\ISO\ubuntu-24.04.3-autoinstall.iso' -Engine oscdimg   # wsl | docker | oscdimg
  ```

  > The `oscdimg` engine (7-Zip extract + `oscdimg -m -o -j2 -bootdata:…`) is the
  > no-WSL path and reuses the same tested GRUB edit. It does not write Rock Ridge, so keep it in
  > mind if you rely on offline apt from the ISO pool; the `wsl`/`docker` xorriso
  > engines preserve the exact boot metadata.

After the install finishes, detach the installer so the VM boots from disk:

```powershell
Get-VMDvdDrive -VMName k8s-cp1 | Where-Object { $_.Path -like '*live-server*' } | Set-VMDvdDrive -Path $null
Set-VMFirmware -VMName k8s-cp1 -FirstBootDevice (Get-VMHardDiskDrive -VMName k8s-cp1)
```

> **Boot order:** for `-Autoinstall`, provisioning sets the boot order **disk
> first, installer second** (`Add-LabInstallMedia -BootAfterDisk`). A blank disk
> falls through to the installer; once the unattended install finishes and
> `shutdown: reboot` runs, the now-bootable disk starts the installed OS — no
> reinstall loop and no manual detach. The manual detach above is only needed for
> the non-autoinstall (DVD-first) flow.

## Operational helpers

These functions (adopted from a proven Hyper-V lab) complement provisioning:

### Host readiness precheck

`Test-LabHostReadiness` collects **all** problems at once (elevation, edition,
Hyper-V + `vmms`, RAM, free disk, required cmdlets, YAML support, ISO presence):

```powershell
$r = Test-LabHostReadiness -VhdRootPath 'C:\HyperV\VHDs' -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' -RequireYaml
if (-not $r.Passed) { $r.Failures | ForEach-Object { Write-Warning $_ } }
```

### NAT networking (no external adapter needed)

`New-LabNatNetwork` creates an **internal** switch + static host vNIC + **WinNAT**,
so guests get a stable subnet and outbound internet **without binding a physical
adapter** — this avoids the "external adapter already bound" conflict and works on
laptops/Wi-Fi. It detects route and NAT-prefix conflicts first.

```powershell
New-LabNatNetwork -SwitchName 'Observability-Internal' -HostIpAddress '10.50.0.1' `
  -PrefixLength 24 -NatName 'ObservabilityNat' -NatPrefix '10.50.0.0/24'
```

### Wait for nodes, then hand off to Ansible

After `-StartVms -Autoinstall`, block until the freshly installed nodes are
reachable (and clear stale SSH host keys from a previous `-Rebuild`):

```powershell
Clear-LabSshKnownHost -HostName 10.50.0.10, 10.50.0.11, 10.50.0.12, 10.50.0.13
Wait-LabNodeSsh -Address 10.50.0.10, 10.50.0.11, 10.50.0.12, 10.50.0.13 -TimeoutMinutes 60
# nodes are now reachable -> run the Ansible playbooks
```

### Lab lifecycle and status

```powershell
Start-LabEnvironment -Configuration $config
Get-LabStatus -Configuration $config | Format-Table -AutoSize
Stop-LabEnvironment -Configuration $config          # -Force to hard stop
```

### VM policies

`New-LabVirtualMachine` (used by provisioning) sets sensible defaults:
`-AutomaticStopAction ShutDown`, `-CheckpointType Production`, and
`-AutomaticStartAction Nothing`; pass `-DynamicMemory` to enable dynamic memory.

## Prerequisites

- Windows 11 Pro with the Hyper-V role enabled.
- A guest OS source: an Ubuntu 24.04 **cloud image** VHDX (Path A) or the
  **installer ISO** at, e.g., `E:\ISO\ubuntu-24.04.3-live-server-amd64.iso` (Path B).
- `powershell-yaml` module for YAML parsing.
- Windows ADK "Deployment Tools" (`oscdimg.exe`) for cloud-init seed images
  (optional — seeding is skipped with a warning if it is missing).
- For automatic autoinstall ISO remastering (`-BuildAutoinstallIso`), one of:
  - WSL with an Ubuntu distribution and `xorriso` (`-IsoEngine wsl`, default), or
  - Docker (`-IsoEngine docker`), or
  - **7-Zip + the Windows ADK `oscdimg`** for a fully native build (`-IsoEngine oscdimg`).
- Add your SSH public key to the cloud-init files before provisioning
  (see `cloud-init/README.md`).

## Tests

Pure functions (config parsing, byte math, cloud-init generation, inventory
rendering, lifecycle guards) are covered by Pester:

```powershell
Invoke-Pester -Path ./hyperv/tests
```

The suite mocks Hyper-V so it runs on any host without the Hyper-V role.
