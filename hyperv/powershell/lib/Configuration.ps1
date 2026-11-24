Set-StrictMode -Version Latest

function Import-LabConfiguration {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Lab configuration not found: $Path"
  }

  $content = Get-Content -LiteralPath $Path -Raw
  if ($Path.EndsWith('.json')) {
    return $content | ConvertFrom-Json -AsHashtable
  }

  if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    throw 'PowerShell YAML support is required to load YAML configuration.'
  }

  return $content | ConvertFrom-Yaml -Ordered
}

function Test-LabVmDefinition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Configuration
  )

  foreach ($vmName in $Configuration.vms.Keys) {
    $vm = $Configuration.vms[$vmName]
    if ([int]$vm['cpu'] -lt 1) {
      throw "VM $vmName must request at least one vCPU."
    }
    if (-not $vm['networks'] -or $vm['networks'].Count -lt 1) {
      throw "VM $vmName must define at least one network."
    }
  }

  return $true
}

function Get-LabVmPlan {
  <#
  .SYNOPSIS
    Produces a normalized, provider-agnostic provisioning plan from lab configuration.
  .DESCRIPTION
    The returned plan contains fully resolved virtual switches and virtual machines with
    byte counts already computed. It performs no side effects and is safe to unit test.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  $switches = [System.Collections.Generic.List[hashtable]]::new()
  if ($Configuration.networks) {
    foreach ($networkKey in $Configuration.networks.Keys) {
      $network = $Configuration.networks[$networkKey]
      $switchName = [string]$network['name']
      $switchType = [string]$network['type']

      if ([string]::IsNullOrWhiteSpace($switchName)) {
        throw "Network '$networkKey' must define a name."
      }
      if ($switchType -notin @('External', 'Internal', 'Private')) {
        throw "Network '$networkKey' has unsupported type '$switchType'."
      }

      $subnet = $null
      if ($network['subnet']) {
        $subnet = [string]$network['subnet']
      }

      $adapterName = $null
      if ($network['adapterName']) {
        $adapterName = [string]$network['adapterName']
      }

      $gateway = $null
      if ($network['gateway']) {
        $gateway = [string]$network['gateway']
      }

      $switches.Add(@{
          Key         = [string]$networkKey
          Name        = $switchName
          Type        = $switchType
          Subnet      = $subnet
          AdapterName = $adapterName
          Gateway     = $gateway
        })
    }
  }

  $vms = [System.Collections.Generic.List[hashtable]]::new()
  if ($Configuration.vms) {
    foreach ($vmName in $Configuration.vms.Keys) {
      $vm = $Configuration.vms[$vmName]

      if ([int]$vm['cpu'] -lt 1) {
        throw "VM $vmName must request at least one vCPU."
      }
      if (-not $vm['networks'] -or $vm['networks'].Count -lt 1) {
        throw "VM $vmName must define at least one network."
      }
      if (-not $vm['memoryStartupBytes']) {
        throw "VM $vmName must define memoryStartupBytes."
      }
      if (-not $vm['diskSizeBytes']) {
        throw "VM $vmName must define diskSizeBytes."
      }

      $generation = 2
      if ($vm['generation']) {
        $generation = [int]$vm['generation']
      }

      $hostname = [string]$vmName
      if ($vm['hostname']) {
        $hostname = [string]$vm['hostname']
      }

      $ipAddress = $null
      if ($vm['ipAddress']) {
        $ipAddress = [string]$vm['ipAddress']
      }

      $cloudInit = $null
      if ($vm['cloudInit']) {
        $cloudInit = [string]$vm['cloudInit']
      }

      $role = $null
      if ($vm['role']) {
        $role = [string]$vm['role']
      }

      $vms.Add(@{
          Name               = [string]$vmName
          Hostname           = $hostname
          Role               = $role
          CpuCount           = [int]$vm['cpu']
          MemoryStartupBytes = ConvertTo-ByteCount -Size ([string]$vm['memoryStartupBytes'])
          DiskSizeBytes      = ConvertTo-ByteCount -Size ([string]$vm['diskSizeBytes'])
          Networks           = @($vm['networks'] | ForEach-Object { [string]$_ })
          Generation         = $generation
          IpAddress          = $ipAddress
          CloudInit          = $cloudInit
        })
    }
  }

  return @{
    Switches = $switches.ToArray()
    Vms      = $vms.ToArray()
  }
}

function Get-LabAnsibleInventory {
  <#
  .SYNOPSIS
    Generates an Ansible YAML inventory from the lab configuration.
  .DESCRIPTION
    Groups virtual machines by their declared role and emits an inventory that matches the
    layout under ansible/inventories/lab. The static lab IP address (with any CIDR suffix
    stripped) is used as ansible_host so the Hyper-V configuration remains the single source
    of truth for host addressing. Output is deterministic (hosts and groups are sorted).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  $plan = Get-LabVmPlan -Configuration $Configuration

  $groups = [System.Collections.Specialized.OrderedDictionary]::new()
  foreach ($vm in ($plan.Vms | Sort-Object -Property Name)) {
    $groupName = if ([string]::IsNullOrWhiteSpace($vm.Role)) { 'ungrouped' } else { $vm.Role }
    if (-not $groups.Contains($groupName)) {
      $groups[$groupName] = [System.Collections.Generic.List[hashtable]]::new()
    }
    $address = $null
    if ($vm.IpAddress) {
      $address = ($vm.IpAddress -split '/')[0]
    }
    $groups[$groupName].Add(@{ Name = $vm.Name; Address = $address })
  }

  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine('all:')
  [void]$builder.AppendLine('  children:')
  foreach ($groupName in ($groups.Keys | Sort-Object)) {
    [void]$builder.AppendLine(('    {0}:' -f $groupName))
    [void]$builder.AppendLine('      hosts:')
    foreach ($entry in $groups[$groupName]) {
      [void]$builder.AppendLine(('        {0}:' -f $entry.Name))
      if ($entry.Address) {
        [void]$builder.AppendLine(('          ansible_host: {0}' -f $entry.Address))
      }
    }
  }

  return $builder.ToString().TrimEnd() + "`n"
}
