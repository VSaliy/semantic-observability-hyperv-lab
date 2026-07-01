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
