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
}

Describe 'Get-CloudInitNetworkConfig' {
  It 'produces netplan v2 with DHCP primary and static secondary interfaces' {
    $config = Get-CloudInitNetworkConfig -StaticIpCidr '10.50.0.11/24' -DnsServers @('1.1.1.1', '9.9.9.9')
    $config | Should -Match 'version: 2'
    $config | Should -Match 'eth0:\s*\n\s*dhcp4: true'
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
      Mock Add-VMNetworkAdapter { }

      $vhd = Join-Path -Path $TestDrive -ChildPath 'k8s-cp1.vhdx'
      Set-Content -LiteralPath $vhd -Value 'stub'

      $result = New-LabVirtualMachine -Name 'k8s-cp1' -MemoryStartupBytes 6442450944 -CpuCount 4 `
        -DiskSizeBytes 85899345920 -SwitchNames @('External-Lab') -VhdPath $vhd -Force -Confirm:$false

      $result | Should -BeTrue
      Test-Path -LiteralPath $vhd | Should -BeFalse
      Should -Invoke New-VM -Times 1
    }
  }
}

