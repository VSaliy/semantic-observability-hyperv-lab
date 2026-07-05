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
}

