Set-StrictMode -Version Latest

function Test-LabTcpPort {
  <#
  .SYNOPSIS
    Returns $true when a TCP port accepts a connection within the timeout.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$HostName,

    [Parameter(Mandatory)]
    [int]$Port,

    [int]$TimeoutMilliseconds = 2000
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $async = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
      return $false
    }
    $client.EndConnect($async)
    return $true
  }
  catch {
    return $false
  }
  finally {
    $client.Dispose()
  }
}

function Clear-LabSshKnownHost {
  <#
  .SYNOPSIS
    Removes stale SSH known_hosts entries for the given hosts (recreated VMs reuse IPs).
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [string[]]$HostName
  )

  $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
  if (-not $sshKeygen) {
    Write-Warning 'ssh-keygen was not found; skipping stale known_hosts cleanup.'
    return
  }

  foreach ($name in $HostName) {
    if ($PSCmdlet.ShouldProcess($name, 'Remove SSH known_hosts entry')) {
      & $sshKeygen.Source -R $name 2>&1 | Out-Null
    }
  }
}

function Wait-LabNodeSsh {
  <#
  .SYNOPSIS
    Waits until SSH (TCP 22 by default) is reachable on every address, or times out.
  .DESCRIPTION
    Use after starting autoinstall VMs to block until the freshly installed nodes are reachable,
    bridging Hyper-V provisioning to configuration (for example running Ansible).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string[]]$Address,

    [int]$Port = 22,

    [int]$TimeoutMinutes = 60,

    [int]$PollSeconds = 15
  )

  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $remaining = [System.Collections.Generic.List[string]]::new([string[]]$Address)

  while ($remaining.Count -gt 0) {
    foreach ($item in @($remaining)) {
      if (Test-LabTcpPort -HostName $item -Port $Port) {
        Write-LabStatus ("SSH reachable on {0}." -f $item) -Level Success
        [void]$remaining.Remove($item)
      }
    }

    if ($remaining.Count -eq 0) {
      break
    }
    if ((Get-Date) -ge $deadline) {
      throw "Timed out waiting for SSH on: $($remaining -join ', ')"
    }

    $minutesLeft = [Math]::Max(0, [Math]::Round(($deadline - (Get-Date)).TotalMinutes, 1))
    Write-LabStatus ("Waiting for SSH on: {0} ({1} minute(s) before timeout)" -f ($remaining -join ', '), $minutesLeft)
    Start-Sleep -Seconds $PollSeconds
  }

  return $true
}
