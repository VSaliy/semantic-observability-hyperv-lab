# cloud-init (NoCloud)

These `#cloud-config` documents are the **user-data** half of a cloud-init
[NoCloud](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
seed. The other two files (`meta-data` and `network-config`) are generated per
VM by the PowerShell module so that hostnames and static IPs stay consistent
with `hyperv/config/lab-config.yaml`.

## Files

| File | Purpose |
| --- | --- |
| `obs-admin.yaml` | User-data for the admin / jump host. |
| `k8s-node.yaml` | User-data shared by all Kubernetes nodes (hostname comes from meta-data). |

## Before you provision

1. **Add an SSH key.** Each file ships with an empty `ssh_authorized_keys: []`
   and password auth disabled. Replace the empty list with your public key(s),
   otherwise the guest is intentionally unreachable:

   ```yaml
   ssh_authorized_keys:
     - ssh-ed25519 AAAA... you@example
   ```

2. Do **not** commit private keys or passwords (see `CONTRIBUTING.md`).

## How the seed is built

`Invoke-LabProvisioning` wires everything together when
`-CloudInitSourcePath` points at this folder:

```powershell
Import-Module ./hyperv/powershell/HyperVLab.psm1
$config = Import-LabConfiguration -Path ./hyperv/config/lab-config.yaml

Invoke-LabProvisioning `
  -Configuration $config `
  -VhdRootPath 'C:\HyperV\VHDs' `
  -CloudInitSourcePath ./hyperv/cloud-init
```

For each VM that declares a `cloudInit` file, the module:

1. Generates `meta-data` from `Get-CloudInitMetadata` (deterministic instance-id
   and `local-hostname`).
2. Generates `network-config` (netplan v2) from `Get-CloudInitNetworkConfig`:
   DHCP on the external adapter (`eth0`) and the static lab address on the
   internal adapter (`eth1`).
3. Copies the matching user-data file.
4. Builds a `*-cidata.iso` labelled `cidata` with `oscdimg.exe` (Windows ADK).
5. Attaches the ISO as a DVD drive so cloud-init discovers it on first boot.

If `oscdimg.exe` is not installed, seed generation is skipped with a warning and
the VMs are still created; install the Windows ADK "Deployment Tools" to enable
automatic seeding, or build the ISO manually with `genisoimage`/`mkisofs`.

## Autoinstall (unattended installer ISO)

For the Ubuntu Server **installer ISO** path, `autoinstall/user-data.template`
holds a placeholder-only autoinstall document. At provisioning time
(`Invoke-LabProvisioning -Autoinstall`), `Import-DotEnv` reads secrets from a
gitignored `.env` and `Get-AutoinstallUserData` renders them into the NoCloud
`user-data` written to the seed staging area **outside** the repository.

- The template contains **no secrets** and is safe to commit.
- Real credentials live only in `.env` (see the repo-root `.env.example`).
- Rendered seeds and `*-cidata.iso` are gitignored so they are never committed.

## Assumptions

- Ubuntu Server 24.04 cloud image (Generation 2 VM, UEFI).
- Hyper-V synthetic NICs enumerate as `eth0` (external) and `eth1` (internal).
  Adjust `Get-CloudInitNetworkConfig -PrimaryInterface/-StaticInterface` if your
  image uses predictable names such as `ens*`.

