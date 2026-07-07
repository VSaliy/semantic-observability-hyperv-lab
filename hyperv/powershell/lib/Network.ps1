Set-StrictMode -Version Latest

function New-LabNatNetwork {
  <#
  .SYNOPSIS
    Creates an internal Hyper-V switch with a static host vNIC IP and WinNAT (idempotent).
  .DESCRIPTION
    Provides a stable cluster subnet and outbound internet via WinNAT without binding a physical
    adapter, which avoids external-switch "adapter already bound" conflicts and works on laptops
    and Wi-Fi. Detects route and NAT-prefix conflicts before making changes.
  .OUTPUTS
    $true when a change was made; $false when everything already matched.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$SwitchName,

    [Parameter(Mandatory)]
    [string]$HostIpAddress,

    [Parameter(Mandatory)]
    [int]$PrefixLength,

    [Parameter(Mandatory)]
    [string]$NatName,

    [Parameter(Mandatory)]
    [string]$NatPrefix
  )

  if (-not (Test-HyperVAvailable)) {
    throw 'Hyper-V cmdlets are not available on this host.'
  }

  $ifAlias = "vEthernet ($SwitchName)"
  $routeConflict = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.DestinationPrefix -eq $NatPrefix -and $_.InterfaceAlias -notlike "$ifAlias*"
  }
  if ($routeConflict) {
    throw "Route conflict for '$NatPrefix' on interface '$($routeConflict[0].InterfaceAlias)'. Resolve it or choose another NAT prefix."
  }

  $changed = $false

  if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($SwitchName, 'Create internal virtual switch')) {
      New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
      $changed = $true
    }
  }

  $ipInterface = Get-NetIPInterface -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
  if ($ipInterface -and $ipInterface.Dhcp -ne 'Disabled') {
    if ($PSCmdlet.ShouldProcess($ifAlias, 'Disable DHCP on the host vNIC')) {
      Set-NetIPInterface -InterfaceAlias $ifAlias -AddressFamily IPv4 -Dhcp Disabled
    }
  }

  $existingIp = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostIpAddress }
  if (-not $existingIp) {
    if ($PSCmdlet.ShouldProcess($ifAlias, "Assign host IP $HostIpAddress/$PrefixLength")) {
      New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostIpAddress -PrefixLength $PrefixLength | Out-Null
      $changed = $true
    }
  }

  $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
  if (-not $nat) {
    $prefixInUse = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $NatPrefix }
    if ($prefixInUse) {
      throw "NAT prefix '$NatPrefix' is already used by NAT '$($prefixInUse.Name)'."
    }
    if ($PSCmdlet.ShouldProcess($NatName, "Create WinNAT for $NatPrefix")) {
      New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
      $changed = $true
    }
  }
  elseif ($nat.InternalIPInterfaceAddressPrefix -ne $NatPrefix) {
    throw "NAT '$NatName' already exists with prefix '$($nat.InternalIPInterfaceAddressPrefix)', expected '$NatPrefix'."
  }

  return $changed
}
