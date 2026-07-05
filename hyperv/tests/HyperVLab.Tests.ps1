BeforeAll {
  Import-Module "$PSScriptRoot/../powershell/HyperVLab.psm1" -Force
}

Describe 'Test-LabVmDefinition' {
  It 'accepts valid VM configuration' {
    $config = @{
      vms = @{
        'obs-admin' = @{ cpu = 2; networks = @('External-Lab') }
      }
    }

    Test-LabVmDefinition -Configuration $config | Should -BeTrue
  }

  It 'rejects a VM without networks' {
    $config = @{
      vms = @{
        'obs-admin' = @{ cpu = 2; networks = @() }
      }
    }

    { Test-LabVmDefinition -Configuration $config } | Should -Throw
  }
}

Describe 'Get-DestructiveCleanupMessage' {
  It 'returns an actionable confirmation message' {
    Get-DestructiveCleanupMessage -Scope 'lab VMs' | Should -Match 'Confirm'
  }
}

Describe 'ConvertTo-ByteCount' {
  It 'parses gigabyte values' {
    ConvertTo-ByteCount -Size '4GB' | Should -Be 4294967296
  }

  It 'parses megabyte values with whitespace' {
    ConvertTo-ByteCount -Size '512 MB' | Should -Be 536870912
  }

  It 'treats plain numbers as bytes' {
    ConvertTo-ByteCount -Size '1048576' | Should -Be 1048576
  }

  It 'throws on unparseable input' {
    { ConvertTo-ByteCount -Size 'not-a-size' } | Should -Throw
  }
}

Describe 'Get-LabVmPlan' {
  BeforeAll {
    $script:config = @{
      networks = @{
        external = @{ name = 'External-Lab'; type = 'External' }
        internal = @{ name = 'Observability-Internal'; type = 'Internal'; subnet = '10.50.0.0/24' }
      }
      vms      = @{
        'obs-admin' = @{
          cpu                = 2
          memoryStartupBytes = '4GB'
          diskSizeBytes      = '60GB'
          networks           = @('External-Lab', 'Observability-Internal')
        }
      }
    }
  }

  It 'normalizes switches from the configuration' {
    $plan = Get-LabVmPlan -Configuration $script:config
    $plan.Switches.Count | Should -Be 2
    ($plan.Switches | Where-Object { $_.Type -eq 'Internal' }).Subnet | Should -Be '10.50.0.0/24'
  }

  It 'resolves VM memory and disk sizes to bytes' {
    $plan = Get-LabVmPlan -Configuration $script:config
    $vm = $plan.Vms | Where-Object { $_.Name -eq 'obs-admin' }
    $vm.MemoryStartupBytes | Should -Be 4294967296
    $vm.DiskSizeBytes | Should -Be 64424509440
    $vm.CpuCount | Should -Be 2
    $vm.Generation | Should -Be 2
    $vm.Networks.Count | Should -Be 2
  }

  It 'rejects unsupported switch types' {
    $bad = @{ networks = @{ bogus = @{ name = 'Nope'; type = 'Bridged' } } }
    { Get-LabVmPlan -Configuration $bad } | Should -Throw
  }

  It 'requires memory and disk for a VM' {
    $bad = @{ vms = @{ 'x' = @{ cpu = 1; networks = @('External-Lab') } } }
    { Get-LabVmPlan -Configuration $bad } | Should -Throw
  }
}

Describe 'Get-CloudInitInstanceId' {
  It 'is deterministic and lowercase' {
    Get-CloudInitInstanceId -VmName 'Obs-Admin' | Should -Be 'iid-obs-admin'
  }
}

Describe 'Get-CloudInitMetadata' {
  It 'includes the instance id and hostname' {
    $metadata = Get-CloudInitMetadata -VmName 'k8s-cp1'
    $metadata | Should -Match 'instance-id: iid-k8s-cp1'
    $metadata | Should -Match 'local-hostname: k8s-cp1'
  }

  It 'allows overriding the hostname' {
    Get-CloudInitMetadata -VmName 'k8s-cp1' -Hostname 'control-plane-1' | Should -Match 'local-hostname: control-plane-1'
  }
}

Describe 'Hyper-V lifecycle guards' {
  It 'throws a clear error when Hyper-V is unavailable' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $false }

      { New-LabVirtualSwitch -Name 'External-Lab' -Type 'External' -NetAdapterName 'Ethernet' } |
        Should -Throw '*Hyper-V cmdlets are not available*'
      { New-LabVirtualMachine -Name 'obs-admin' -MemoryStartupBytes 4294967296 -CpuCount 2 -DiskSizeBytes 64424509440 -SwitchNames @('External-Lab') -VhdPath 'C:\vhd\obs-admin.vhdx' } |
        Should -Throw '*Hyper-V cmdlets are not available*'
      { Start-LabVirtualMachine -Name 'obs-admin' } | Should -Throw '*Hyper-V cmdlets are not available*'
      { Stop-LabVirtualMachine -Name 'obs-admin' } | Should -Throw '*Hyper-V cmdlets are not available*'
      { Remove-LabVirtualMachine -Name 'obs-admin' } | Should -Throw '*Hyper-V cmdlets are not available*'
    }
  }

  It 'validates configuration before provisioning' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $false }

      $config = @{
        vms = @{ 'obs-admin' = @{ cpu = 2; networks = @('External-Lab') } }
      }

      { Invoke-LabProvisioning -Configuration $config -VhdRootPath 'C:\vhd' } |
        Should -Throw '*Hyper-V cmdlets are not available*'
    }
  }

  It 'throws a clear error when attaching a cloud-init disk without Hyper-V' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $false }

      { Add-LabCloudInitDisk -VmName 'obs-admin' -IsoPath 'C:\seed\obs-admin.iso' } |
        Should -Throw '*Hyper-V cmdlets are not available*'
    }
  }

  It 'throws a clear error when attaching installer media without Hyper-V' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $false }

      { Add-LabInstallMedia -VmName 'obs-admin' -IsoPath 'E:\ISO\ubuntu.iso' } |
        Should -Throw '*Hyper-V cmdlets are not available*'
    }
  }
}

Describe 'Get-CloudInitNetworkConfig' {
  It 'produces netplan v2 with DHCP primary and static secondary interfaces' {
    $config = Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24' -DnsServers @('1.1.1.1', '9.9.9.9')
    $config | Should -Match 'version: 2'
    $config | Should -Match 'eth0:\s*\n\s*dhcp4: true'
    $config | Should -Match 'optional: true'
    $config | Should -Match '- 10.50.0.11/24'
    $config | Should -Match '- 1.1.1.1'
  }

  It 'omits a default route on the static interface by default' {
    $config = Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24'
    $config | Should -Not -Match 'to: default'
  }

  It 'adds a default route only when requested' {
    $config = Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24' -Gateway '10.50.0.1' -DefaultRouteOnStatic
    $config | Should -Match 'to: default'
    $config | Should -Match 'via: 10.50.0.1'
  }

  It 'rejects an address that is not in CIDR notation' {
    { Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11' } | Should -Throw
  }

  It 'requires a gateway when a default route is requested' {
    { Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24' -DefaultRouteOnStatic } | Should -Throw '*-Gateway*'
  }
}

Describe 'New-CloudInitSeedStaging' {
  BeforeEach {
    $script:userData = Join-Path -Path $TestDrive -ChildPath 'user-data.yaml'
    Set-Content -LiteralPath $script:userData -Value "#cloud-config`nmanage_etc_hosts: true`n"
  }

  It 'writes meta-data, user-data, and network-config into a per-VM folder' {
    $network = Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24'
    $dir = New-CloudInitSeedStaging -VmName 'k8s-cp1' -UserDataPath $script:userData `
      -OutputRootPath $TestDrive -Hostname 'k8s-cp1' -NetworkConfig $network -Confirm:$false

    Test-Path (Join-Path $dir 'meta-data') | Should -BeTrue
    Test-Path (Join-Path $dir 'user-data') | Should -BeTrue
    Test-Path (Join-Path $dir 'network-config') | Should -BeTrue
    Get-Content (Join-Path $dir 'meta-data') -Raw | Should -Match 'local-hostname: k8s-cp1'
    Get-Content (Join-Path $dir 'user-data') -Raw | Should -Match '#cloud-config'
  }

  It 'skips the network-config file when none is supplied' {
    $dir = New-CloudInitSeedStaging -VmName 'obs-admin' -UserDataPath $script:userData `
      -OutputRootPath $TestDrive -Confirm:$false
    Test-Path (Join-Path $dir 'network-config') | Should -BeFalse
  }

  It 'rejects user-data that is not a #cloud-config document' {
    $bad = Join-Path -Path $TestDrive -ChildPath 'bad.yaml'
    Set-Content -LiteralPath $bad -Value "not-cloud-config: true"
    { New-CloudInitSeedStaging -VmName 'x' -UserDataPath $bad -OutputRootPath $TestDrive -Confirm:$false } |
      Should -Throw '*#cloud-config*'
  }

  It 'throws when the user-data file is missing' {
    { New-CloudInitSeedStaging -VmName 'x' -UserDataPath (Join-Path $TestDrive 'missing.yaml') -OutputRootPath $TestDrive -Confirm:$false } |
      Should -Throw '*not found*'
  }
}

Describe 'Get-LabAnsibleInventory' {
  BeforeAll {
    $script:config = @{
      networks = @{
        internal = @{ name = 'Observability-Internal'; type = 'Internal'; subnet = '10.50.0.0/24' }
      }
      vms      = @{
        'obs-admin'   = @{ role = 'admin'; cpu = 2; memoryStartupBytes = '4GB'; diskSizeBytes = '60GB'; networks = @('Observability-Internal'); ipAddress = '10.50.0.10/24' }
        'k8s-cp1'     = @{ role = 'kubernetes'; cpu = 4; memoryStartupBytes = '6GB'; diskSizeBytes = '80GB'; networks = @('Observability-Internal'); ipAddress = '10.50.0.11/24' }
        'k8s-worker1' = @{ role = 'kubernetes'; cpu = 4; memoryStartupBytes = '6GB'; diskSizeBytes = '80GB'; networks = @('Observability-Internal'); ipAddress = '10.50.0.12/24' }
      }
    }
  }

  It 'groups hosts by role' {
    $inventory = Get-LabAnsibleInventory -Configuration $script:config
    $inventory | Should -Match 'admin:'
    $inventory | Should -Match 'kubernetes:'
  }

  It 'uses the static IP without CIDR suffix as ansible_host' {
    $inventory = Get-LabAnsibleInventory -Configuration $script:config
    $inventory | Should -Match 'ansible_host: 10.50.0.11'
    $inventory | Should -Not -Match 'ansible_host: 10.50.0.11/24'
  }
}

Describe 'Get-LabVmPlan cloud-init fields' {
  BeforeAll {
    $script:config = @{
      networks = @{
        external = @{ name = 'External-Lab'; type = 'External'; adapterName = 'Ethernet' }
        internal = @{ name = 'Observability-Internal'; type = 'Internal'; subnet = '10.50.0.0/24'; gateway = '10.50.0.1' }
      }
      vms      = @{
        'k8s-cp1' = @{
          role               = 'kubernetes'
          cpu                = 4
          memoryStartupBytes = '6GB'
          diskSizeBytes      = '80GB'
          networks           = @('External-Lab', 'Observability-Internal')
          ipAddress          = '10.50.0.11/24'
          cloudInit          = 'k8s-node.yaml'
        }
      }
    }
  }

  It 'resolves per-VM hostname, role, IP, and cloud-init file' {
    $plan = Get-LabVmPlan -Configuration $script:config
    $vm = $plan.Vms | Where-Object { $_.Name -eq 'k8s-cp1' }
    $vm.Hostname | Should -Be 'k8s-cp1'
    $vm.Role | Should -Be 'kubernetes'
    $vm.IpAddress | Should -Be '10.50.0.11/24'
    $vm.CloudInit | Should -Be 'k8s-node.yaml'
  }

  It 'resolves external switch adapter name and internal gateway' {
    $plan = Get-LabVmPlan -Configuration $script:config
    ($plan.Switches | Where-Object { $_.Type -eq 'External' }).AdapterName | Should -Be 'Ethernet'
    ($plan.Switches | Where-Object { $_.Type -eq 'Internal' }).Gateway | Should -Be '10.50.0.1'
  }

  It 'tolerates a configuration that omits optional keys' {
    $minimal = @{
      networks = @{ internal = @{ name = 'Observability-Internal'; type = 'Internal' } }
      vms      = @{ 'x' = @{ cpu = 1; memoryStartupBytes = '2GB'; diskSizeBytes = '20GB'; networks = @('Observability-Internal') } }
    }
    $plan = Get-LabVmPlan -Configuration $minimal
    $vm = $plan.Vms | Where-Object { $_.Name -eq 'x' }
    $vm.Hostname | Should -Be 'x'
    $vm.Role | Should -BeNullOrEmpty
    $vm.CloudInit | Should -BeNullOrEmpty
  }
}

Describe 'Test-OscdimgAvailable' {
  It 'returns a boolean' {
    (Test-OscdimgAvailable) -is [bool] | Should -BeTrue
  }
}

Describe 'Import-DotEnv' {
  It 'parses key/value pairs and ignores comments and blank lines' {
    $envFile = Join-Path -Path $TestDrive -ChildPath 'sample.env'
    $lines = @(
      '# a comment',
      '',
      'LAB_AUTOINSTALL_USERNAME=labadmin',
      'LAB_AUTOINSTALL_FULL_NAME="Lab Administrator"',
      'LAB_AUTOINSTALL_PASSWORD_HASH=$6$abc$def=='
    )
    Set-Content -LiteralPath $envFile -Value ($lines -join "`n")

    $values = Import-DotEnv -Path $envFile
    $values['LAB_AUTOINSTALL_USERNAME'] | Should -Be 'labadmin'
    $values['LAB_AUTOINSTALL_FULL_NAME'] | Should -Be 'Lab Administrator'
    $values['LAB_AUTOINSTALL_PASSWORD_HASH'] | Should -Be '$6$abc$def=='
  }

  It 'throws when the file is missing' {
    { Import-DotEnv -Path (Join-Path -Path $TestDrive -ChildPath 'missing.env') } | Should -Throw '*not found*'
  }
}

Describe 'Get-AutoinstallUserData' {
  BeforeAll {
    $script:template = Join-Path -Path $TestDrive -ChildPath 'user-data.template'
    $templateLines = @(
      '#cloud-config',
      'autoinstall:',
      '  identity:',
      '    realname: "${LAB_AUTOINSTALL_FULL_NAME}"',
      '    hostname: ${LAB_VM_HOSTNAME}',
      '    username: ${LAB_AUTOINSTALL_USERNAME}',
      '    password: "${LAB_AUTOINSTALL_PASSWORD_HASH}"',
      '  ssh:',
      '    authorized-keys:',
      '__SSH_AUTHORIZED_KEYS__'
    )
    Set-Content -LiteralPath $script:template -Value ($templateLines -join "`n")
  }

  It 'renders placeholders and expands the ssh key list' {
    $values = @{
      LAB_AUTOINSTALL_USERNAME            = 'labadmin'
      LAB_AUTOINSTALL_FULL_NAME           = 'Lab Administrator'
      LAB_AUTOINSTALL_PASSWORD_HASH       = '$6$abc$def'
      LAB_AUTOINSTALL_SSH_AUTHORIZED_KEYS = "ssh-ed25519 KEY1 a@b`nssh-ed25519 KEY2 c@d"
    }

    $out = Get-AutoinstallUserData -TemplatePath $script:template -Values $values -Hostname 'k8s-cp1'
    $out | Should -Match 'hostname: k8s-cp1'
    $out | Should -Match 'username: labadmin'
    $out | Should -Match 'password: "\$6\$abc\$def"'
    $out | Should -Match '      - ssh-ed25519 KEY1 a@b'
    $out | Should -Match '      - ssh-ed25519 KEY2 c@d'
    $out | Should -Not -Match '\$\{'
    $out | Should -Not -Match '__SSH_AUTHORIZED_KEYS__'
  }

  It 'throws when a required value is missing' {
    { Get-AutoinstallUserData -TemplatePath $script:template -Values @{ LAB_AUTOINSTALL_USERNAME = 'x' } -Hostname 'h' } |
      Should -Throw '*Missing required*'
  }
}

Describe 'ConvertTo-WslPath' {
  It 'converts a Windows drive path to /mnt' {
    ConvertTo-WslPath -Path 'E:\ISO\ubuntu.iso' | Should -Be '/mnt/e/ISO/ubuntu.iso'
  }

  It 'handles spaces and forward slashes' {
    ConvertTo-WslPath -Path 'C:/a b/c' | Should -Be '/mnt/c/a b/c'
  }

  It 'throws on a non-rooted path' {
    { ConvertTo-WslPath -Path 'relative\path' } | Should -Throw
  }
}

Describe 'Add-AutoinstallKernelArgument' {
  It 'injects autoinstall immediately after the kernel image' {
    $grub = "menuentry x {`n    linux /casper/vmlinuz ---`n    initrd /casper/initrd`n}"
    Add-AutoinstallKernelArgument -GrubConfiguration $grub | Should -Match 'linux /casper/vmlinuz autoinstall ---'
  }

  It 'is idempotent' {
    Add-AutoinstallKernelArgument -GrubConfiguration 'linux /casper/vmlinuz autoinstall ---' |
      Should -Be 'linux /casper/vmlinuz autoinstall ---'
  }

  It 'adds multiple arguments preserving order' {
    Add-AutoinstallKernelArgument -GrubConfiguration 'linux /casper/vmlinuz ---' -KernelArguments @('autoinstall', 'ds=nocloud') |
      Should -Match 'vmlinuz autoinstall ds=nocloud ---'
  }

  It 'throws when no kernel line is present' {
    { Add-AutoinstallKernelArgument -GrubConfiguration 'set timeout=5' } | Should -Throw '*vmlinuz*'
  }
}

Describe 'Update-GrubConfigFile' {
  It 'rewrites grub.cfg in place with the autoinstall argument' {
    InModuleScope HyperVLab {
      $f = Join-Path -Path $TestDrive -ChildPath 'grub.cfg'
      Set-Content -LiteralPath $f -Value 'linux /casper/vmlinuz ---'
      Update-GrubConfigFile -Path $f -Confirm:$false | Out-Null
      Get-Content -LiteralPath $f -Raw | Should -Match 'vmlinuz autoinstall ---'
    }
  }
}

Describe 'New-AutoinstallIso' {
  It 'throws when the source ISO is missing' {
    { New-AutoinstallIso -SourceIsoPath (Join-Path -Path $TestDrive -ChildPath 'missing.iso') `
        -OutputIsoPath (Join-Path -Path $TestDrive -ChildPath 'out.iso') -Confirm:$false } |
      Should -Throw '*source ISO not found*'
  }

  It 'reuses an existing output ISO without invoking an engine' {
    $src = Join-Path -Path $TestDrive -ChildPath 'src.iso'
    Set-Content -LiteralPath $src -Value 'stub'
    $out = Join-Path -Path $TestDrive -ChildPath 'out.iso'
    Set-Content -LiteralPath $out -Value 'stub'
    New-AutoinstallIso -SourceIsoPath $src -OutputIsoPath $out -Confirm:$false | Should -Be $out
  }
}

Describe 'Resolve-EltoritoBootImage' {
  It 'locates BIOS and UEFI images by 7-Zip numeric prefix' {
    $extract = Join-Path -Path $TestDrive -ChildPath 'extract'
    $bootDir = Join-Path -Path $extract -ChildPath '[BOOT]'
    [System.IO.Directory]::CreateDirectory($bootDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $bootDir -ChildPath '1-Boot-NoEmul.img'), 'bios')
    [System.IO.File]::WriteAllText((Join-Path -Path $bootDir -ChildPath '2-Boot-NoEmul.img'), 'uefi')

    $result = Resolve-EltoritoBootImage -ExtractDirectory $extract
    $result.Bios | Should -Match '1-Boot-NoEmul\.img$'
    $result.Uefi | Should -Match '2-Boot-NoEmul\.img$'
  }

  It 'throws when the [BOOT] directory is missing' {
    { Resolve-EltoritoBootImage -ExtractDirectory (Join-Path -Path $TestDrive -ChildPath 'no-boot') } |
      Should -Throw '*directory not found*'
  }
}

Describe 'New-CloudInitSeedStaging autoinstall content' {
  It 'stages user-data supplied as content' {
    $content = "#cloud-config`nautoinstall:`n  version: 1`n"
    $dir = New-CloudInitSeedStaging -VmName 'k8s-cp1' -UserDataContent $content `
      -OutputRootPath $TestDrive -Hostname 'k8s-cp1' -Confirm:$false
    Get-Content (Join-Path $dir 'user-data') -Raw | Should -Match 'autoinstall:'
  }

  It 'rejects content that is not a #cloud-config document' {
    { New-CloudInitSeedStaging -VmName 'x' -UserDataContent 'nope: true' -OutputRootPath $TestDrive -Confirm:$false } |
      Should -Throw '*#cloud-config*'
  }
}

Describe 'Get-OscdimgPath' {
  It 'returns either $null or an existing oscdimg.exe path' {
    $path = Get-OscdimgPath
    if ($null -ne $path) {
      $path | Should -Match 'oscdimg\.exe$'
      Test-Path -LiteralPath $path | Should -BeTrue
    }
  }

  It 'agrees with Test-OscdimgAvailable' {
    [bool](Get-OscdimgPath) | Should -Be (Test-OscdimgAvailable)
  }
}

Describe 'New-CloudInitSeedImage' {
  It 'throws an actionable error when oscdimg is unavailable' {
    InModuleScope HyperVLab {
      Mock Get-OscdimgPath { $null }
      $seed = Join-Path -Path $TestDrive -ChildPath 'seed'
      New-Item -ItemType Directory -Path $seed -Force | Out-Null
      { New-CloudInitSeedImage -SeedDirectory $seed -OutputIsoPath (Join-Path $TestDrive 'out.iso') -Confirm:$false } |
        Should -Throw '*oscdimg*'
    }
  }
}

Describe 'New-LabVirtualMachine leftover disk handling' -Skip:(-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  It 'throws an actionable error when a disk already exists and -Force is not set' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $true }
      Mock Get-VM { $null }
      Mock New-VM { }
      Mock Set-VMProcessor { }
      Mock Add-VMNetworkAdapter { }

      $vhd = Join-Path -Path $TestDrive -ChildPath 'obs-admin.vhdx'
      Set-Content -LiteralPath $vhd -Value 'stub'

      { New-LabVirtualMachine -Name 'obs-admin' -MemoryStartupBytes 4294967296 -CpuCount 2 `
          -DiskSizeBytes 64424509440 -SwitchNames @('External-Lab') -VhdPath $vhd -Confirm:$false } |
        Should -Throw '*already exists*'
      Should -Not -Invoke New-VM
    }
  }

  It 'removes the leftover disk and recreates the VM when -Force is set' {
    InModuleScope HyperVLab {
      Mock Test-HyperVAvailable { $true }
      Mock Get-VM { $null }
      Mock New-VM { }
      Mock Set-VMProcessor { }
      Mock Set-VMFirmware { }
      Mock Add-VMNetworkAdapter { }

      $vhd = Join-Path -Path $TestDrive -ChildPath 'k8s-cp1.vhdx'
      Set-Content -LiteralPath $vhd -Value 'stub'

      $result = New-LabVirtualMachine -Name 'k8s-cp1' -MemoryStartupBytes 6442450944 -CpuCount 4 `
        -DiskSizeBytes 85899345920 -SwitchNames @('External-Lab') -VhdPath $vhd -Force -Confirm:$false

      $result | Should -BeTrue
      Test-Path -LiteralPath $vhd | Should -BeFalse
      Should -Invoke New-VM -Times 1
      Should -Invoke Set-VMFirmware -Times 1
    }
  }
}

