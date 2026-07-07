Set-StrictMode -Version Latest

function ConvertTo-WslPath {
  <#
  .SYNOPSIS
    Converts a Windows drive path to its WSL /mnt equivalent.
  .EXAMPLE
    ConvertTo-WslPath -Path 'E:\ISO\ubuntu.iso'  # -> /mnt/e/ISO/ubuntu.iso
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if ($Path -notmatch '^[A-Za-z]:[\\/]') {
    throw "Path must be a rooted Windows drive path (for example 'E:\ISO\file.iso'): $Path"
  }

  $drive = $Path.Substring(0, 1).ToLowerInvariant()
  $rest = $Path.Substring(2) -replace '\\', '/'
  $rest = $rest.TrimStart('/')
  return "/mnt/$drive/$rest"
}

function Add-AutoinstallKernelArgument {
  <#
  .SYNOPSIS
    Injects one or more kernel arguments (default 'autoinstall') into the GRUB kernel lines.
  .DESCRIPTION
    Adds the requested arguments immediately after the Ubuntu casper kernel image on every
    'linux /casper/vmlinuz ...' line, skipping arguments that are already present. Idempotent.
  .OUTPUTS
    The modified GRUB configuration text.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$GrubConfiguration,

    [string[]]$KernelArguments = @('autoinstall')
  )

  $lines = $GrubConfiguration -split "`r?`n"
  $found = $false

  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch 'vmlinuz') {
      continue
    }
    $found = $true
    $indent = [regex]::Match($lines[$i], '^\s*').Value
    $tokens = @($lines[$i] -split '\s+' | Where-Object { $_ -ne '' })

    $vmIndex = -1
    for ($j = 0; $j -lt $tokens.Count; $j++) {
      if ($tokens[$j] -like '*vmlinuz*') { $vmIndex = $j; break }
    }
    if ($vmIndex -lt 0) { continue }

    $missing = @($KernelArguments | Where-Object { $tokens -notcontains $_ })
    if ($missing.Count -eq 0) { continue }

    $newTokens = @($tokens[0..$vmIndex]) + $missing
    if ($vmIndex -lt ($tokens.Count - 1)) {
      $newTokens += $tokens[($vmIndex + 1)..($tokens.Count - 1)]
    }
    $lines[$i] = $indent + ($newTokens -join ' ')
  }

  if (-not $found) {
    throw 'No /casper/vmlinuz kernel line found in the GRUB configuration.'
  }

  return ($lines -join "`n")
}

function Resolve-EltoritoBootImage {
  <#
  .SYNOPSIS
    Locates the BIOS and UEFI El Torito boot images extracted by 7-Zip from an ISO.
  .DESCRIPTION
    7-Zip exposes the boot images under a synthetic '[BOOT]' directory (for example
    '1-Boot-NoEmul.img' for BIOS and '2-Boot-NoEmul.img' for UEFI). This resolves those images
    by their numeric prefix, falling back to enumeration order, so oscdimg can rebuild a hybrid
    bootable ISO.
  .OUTPUTS
    A hashtable with 'Bios' and 'Uefi' full paths (either may be $null).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ExtractDirectory
  )

  $bootDir = Join-Path -Path $ExtractDirectory -ChildPath '[BOOT]'
  if (-not (Test-Path -LiteralPath $bootDir)) {
    throw "El Torito '[BOOT]' directory not found under: $ExtractDirectory"
  }

  $images = @(Get-ChildItem -LiteralPath $bootDir -Filter '*.img' -File | Sort-Object Name)
  if ($images.Count -eq 0) {
    throw "No boot images (*.img) found in: $bootDir"
  }

  $bios = $images | Where-Object { $_.Name -match '^1' } | Select-Object -First 1
  $uefi = $images | Where-Object { $_.Name -match '^2' } | Select-Object -First 1
  if (-not $bios -and $images.Count -ge 1) { $bios = $images[0] }
  if (-not $uefi -and $images.Count -ge 2) { $uefi = $images[1] }

  $biosPath = if ($bios) { $bios.FullName } else { $null }
  $uefiPath = if ($uefi) { $uefi.FullName } else { $null }
  return @{ Bios = $biosPath; Uefi = $uefiPath }
}

function Get-OscdimgPath {
  <#
  .SYNOPSIS
    Resolves the full path to oscdimg.exe from PATH or well-known Windows ADK locations.
  .DESCRIPTION
    oscdimg.exe ships with the Windows ADK "Deployment Tools" and is usually not added to
    PATH. This helper checks PATH first, then the standard ADK install directories under
    Program Files, preferring the amd64 build.
  .OUTPUTS
    The full path to oscdimg.exe, or $null when it cannot be found.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $command = Get-Command -Name 'oscdimg.exe' -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $roots = @()
  if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
  if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }

  foreach ($root in $roots) {
    $deploymentTools = Join-Path -Path $root -ChildPath 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    if (-not (Test-Path -LiteralPath $deploymentTools)) {
      continue
    }
    $candidates = Get-ChildItem -Path $deploymentTools -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue
    $preferred = $candidates | Where-Object { $_.FullName -match '\\amd64\\' } | Select-Object -First 1
    if ($preferred) {
      return $preferred.FullName
    }
    if ($candidates) {
      return ($candidates | Select-Object -First 1).FullName
    }
  }

  return $null
}

function Test-OscdimgAvailable {
  <#
  .SYNOPSIS
    Indicates whether oscdimg.exe (Windows ADK) can be located on this host.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  return [bool](Get-OscdimgPath)
}

function New-CloudInitSeedImage {
  <#
  .SYNOPSIS
    Builds a cloud-init NoCloud seed ISO from a staging directory using oscdimg.exe.
  .DESCRIPTION
    The ISO is labelled 'cidata' so cloud-init's NoCloud data source discovers it automatically
    when the disk is attached to the guest. Requires oscdimg.exe from the Windows ADK.
  .OUTPUTS
    The absolute path to the ISO that was created.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$SeedDirectory,

    [Parameter(Mandatory)]
    [string]$OutputIsoPath,

    [string]$OscdimgPath
  )

  if (-not (Test-Path -LiteralPath $SeedDirectory)) {
    throw "cloud-init seed directory not found: $SeedDirectory"
  }

  if ([string]::IsNullOrWhiteSpace($OscdimgPath)) {
    $OscdimgPath = Get-OscdimgPath
  }
  if ([string]::IsNullOrWhiteSpace($OscdimgPath) -or -not (Test-Path -LiteralPath $OscdimgPath)) {
    throw 'oscdimg.exe could not be located. Install the Windows ADK (Deployment Tools) or pass -OscdimgPath.'
  }

  if (-not $PSCmdlet.ShouldProcess($OutputIsoPath, 'Build cloud-init NoCloud seed image')) {
    return $OutputIsoPath
  }

  $isoDirectory = Split-Path -Path $OutputIsoPath -Parent
  if ($isoDirectory -and -not (Test-Path -LiteralPath $isoDirectory)) {
    New-Item -ItemType Directory -Path $isoDirectory -Force | Out-Null
  }

  if (Test-Path -LiteralPath $OutputIsoPath) {
    Remove-Item -LiteralPath $OutputIsoPath -Force
  }

  $oscdimgOutput = & $OscdimgPath '-lcidata' '-j2' '-m' '-o' $SeedDirectory $OutputIsoPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "oscdimg.exe failed with exit code $LASTEXITCODE while building '$OutputIsoPath': $oscdimgOutput"
  }

  return $OutputIsoPath
}

function New-AutoinstallIso {
  <#
  .SYNOPSIS
    Builds an autoinstall-enabled Ubuntu Server ISO from a source ISO.
  .DESCRIPTION
    Injects the 'autoinstall' kernel argument into the ISO's GRUB configuration and repacks a
    UEFI-bootable ISO. No credentials are placed in the ISO; the per-VM cloud-init cidata seed
    supplies the autoinstall data at install time.

    Engines:
      wsl     - (default) host WSL + xorriso; '-boot_image any replay' preserves the exact boot
                structure and Rock Ridge/Joliet metadata (most faithful). Requires xorriso in WSL.
      docker  - same xorriso pipeline inside a container (installs xorriso per run; slower).
      oscdimg - fully native Windows: 7-Zip extracts the ISO, the GRUB configs are edited, and
                oscdimg.exe (Windows ADK) repacks a hybrid BIOS+UEFI ISO. No WSL/Docker needed.
                Note: oscdimg does not write Rock Ridge extensions, so on-ISO symlinks are not
                preserved (boot/install still work; offline apt from the ISO pool may not).

    Idempotent: an existing output ISO is reused unless -Force is set.
  .OUTPUTS
    The absolute path to the autoinstall ISO.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$SourceIsoPath,

    [Parameter(Mandatory)]
    [string]$OutputIsoPath,

    [string[]]$KernelArguments = @('autoinstall'),

    [ValidateSet('wsl', 'docker', 'oscdimg')]
    [string]$Engine = 'wsl',

    [string]$WslDistribution,

    [string]$DockerImage = 'ubuntu:24.04',

    [string]$VolumeLabel = 'UBUNTU_AUTO',

    [switch]$Force
  )

  if (-not (Test-Path -LiteralPath $SourceIsoPath)) {
    throw "source ISO not found: $SourceIsoPath"
  }
  if ((Test-Path -LiteralPath $OutputIsoPath) -and -not $Force) {
    Write-Verbose "Autoinstall ISO '$OutputIsoPath' already exists; reusing it (use -Force to rebuild)."
    return $OutputIsoPath
  }
  if (-not $PSCmdlet.ShouldProcess($OutputIsoPath, "Build autoinstall ISO from $SourceIsoPath")) {
    return $OutputIsoPath
  }

  $workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('autoinstall-iso-{0}' -f ([guid]::NewGuid()))
  New-Item -ItemType Directory -Path $workDir -Force | Out-Null
  $grubHostPath = Join-Path -Path $workDir -ChildPath 'grub.cfg'

  Write-LabStatus ("Building autoinstall ISO ({0}) from '{1}' - this can take a few minutes..." -f $Engine, (Split-Path -Path $SourceIsoPath -Leaf)) -Level Step

  try {
    switch ($Engine) {
      'wsl' {
        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
          throw 'wsl.exe is not available. Install WSL with an Ubuntu distribution or use -Engine docker/oscdimg.'
        }
        $distroArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($WslDistribution)) { $distroArgs = @('-d', $WslDistribution) }

        $wslIso = ConvertTo-WslPath -Path $SourceIsoPath
        $wslOut = ConvertTo-WslPath -Path $OutputIsoPath
        $wslGrub = ConvertTo-WslPath -Path $grubHostPath

        $extract = "set -e; command -v osirrox >/dev/null 2>&1 || { echo MISSING_XORRISO; exit 3; }; osirrox -indev '$wslIso' -extract /boot/grub/grub.cfg '$wslGrub'"
        Write-LabStatus 'Extracting GRUB config via WSL/xorriso...'
        $extractOut = & wsl @distroArgs -- bash -lc $extract 2>&1
        if ($LASTEXITCODE -eq 3 -or ($extractOut -match 'MISSING_XORRISO')) {
          $install = 'sudo apt-get update && sudo apt-get install -y xorriso'
          if ($distroArgs.Count -gt 0) { $install = "wsl -d $WslDistribution $install" } else { $install = "wsl $install" }
          throw "xorriso is not installed in WSL. Install it with: $install"
        }
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to extract grub.cfg via WSL (exit $LASTEXITCODE): $extractOut"
        }

        $null = Update-GrubConfigFile -Path $grubHostPath -KernelArguments $KernelArguments

        $repack = "set -e; xorriso -indev '$wslIso' -outdev '$wslOut' -boot_image any replay -map '$wslGrub' /boot/grub/grub.cfg -end"
        Write-LabStatus 'Repacking bootable ISO via WSL/xorriso...'
        $repackOut = & wsl @distroArgs -- bash -lc $repack 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to repack ISO via WSL (exit $LASTEXITCODE): $repackOut"
        }
      }

      'docker' {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
          throw 'docker is not available. Install Docker or use -Engine wsl/oscdimg.'
        }
        $isoDir = (Split-Path -Path $SourceIsoPath -Parent) -replace '\\', '/'
        $isoName = Split-Path -Path $SourceIsoPath -Leaf
        $outDir = (Split-Path -Path $OutputIsoPath -Parent) -replace '\\', '/'
        $outName = Split-Path -Path $OutputIsoPath -Leaf
        $workDirFwd = $workDir -replace '\\', '/'
        $aptPrefix = 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq xorriso >/dev/null 2>&1;'

        $extract = "set -e; $aptPrefix osirrox -indev '/iso/$isoName' -extract /boot/grub/grub.cfg /work/grub.cfg"
        Write-LabStatus 'Extracting GRUB config via Docker/xorriso (installing xorriso in container)...'
        $extractOut = & docker run --rm -v "${isoDir}:/iso:ro" -v "${workDirFwd}:/work" $DockerImage bash -lc $extract 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to extract grub.cfg via Docker (exit $LASTEXITCODE): $extractOut"
        }

        $null = Update-GrubConfigFile -Path $grubHostPath -KernelArguments $KernelArguments

        $repack = "set -e; $aptPrefix xorriso -indev '/iso/$isoName' -outdev '/out/$outName' -boot_image any replay -map /work/grub.cfg /boot/grub/grub.cfg -end"
        Write-LabStatus 'Repacking bootable ISO via Docker/xorriso...'
        $repackOut = & docker run --rm -v "${isoDir}:/iso:ro" -v "${workDirFwd}:/work" -v "${outDir}:/out" $DockerImage bash -lc $repack 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to repack ISO via Docker (exit $LASTEXITCODE): $repackOut"
        }
      }

      'oscdimg' {
        $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if (-not $sevenZip) { $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue }
        if (-not $sevenZip) {
          throw '7-Zip (7z) was not found. Install 7-Zip (or add it to PATH), or use -Engine wsl/docker.'
        }
        $oscdimgPath = Get-OscdimgPath
        if ([string]::IsNullOrWhiteSpace($oscdimgPath)) {
          throw 'oscdimg.exe was not found. Install the Windows ADK Deployment Tools, or use -Engine wsl/docker.'
        }

        $extractDir = Join-Path -Path $workDir -ChildPath 'extract'
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        Write-LabStatus 'Extracting installer ISO with 7-Zip...'
        $extractOut = & $sevenZip.Source x $SourceIsoPath "-o$extractDir" -y 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "7-Zip extraction failed (exit $LASTEXITCODE): $extractOut"
        }

        $grubCfg = Join-Path -Path $extractDir -ChildPath 'boot\grub\grub.cfg'
        if (-not (Test-Path -LiteralPath $grubCfg)) {
          throw "grub.cfg not found after extraction: $grubCfg"
        }
        Write-LabStatus 'Injecting autoinstall kernel argument into GRUB...'
        $null = Update-GrubConfigFile -Path $grubCfg -KernelArguments $KernelArguments

        $loopbackCfg = Join-Path -Path $extractDir -ChildPath 'boot\grub\loopback.cfg'
        if (Test-Path -LiteralPath $loopbackCfg) {
          try { $null = Update-GrubConfigFile -Path $loopbackCfg -KernelArguments $KernelArguments }
          catch { Write-Warning "Skipped loopback.cfg (no kernel line?): $($_.Exception.Message)" }
        }

        $boot = Resolve-EltoritoBootImage -ExtractDirectory $extractDir
        if ($boot.Bios -and $boot.Uefi) {
          $bootData = "-bootdata:2#p0,e,b$($boot.Bios)#pEF,e,b$($boot.Uefi)"
        }
        elseif ($boot.Uefi) {
          $bootData = "-bootdata:1#pEF,e,b$($boot.Uefi)"
        }
        elseif ($boot.Bios) {
          $bootData = "-bootdata:1#p0,e,b$($boot.Bios)"
        }
        else {
          throw 'No El Torito boot images were found in the extracted [BOOT] directory.'
        }

        if (Test-Path -LiteralPath $OutputIsoPath) {
          Remove-Item -LiteralPath $OutputIsoPath -Force
        }

        Write-LabStatus 'Repacking bootable ISO with oscdimg...'
        # Flags match the proven istio-practical-lab build (-m -o -j2 -bootdata:...); Joliet is what
        # GRUB/casper read on the Ubuntu ISO, so -j2 is the verified-bootable choice.
        $oscdimgOut = & $oscdimgPath -m -o -j2 $bootData "-l$VolumeLabel" $extractDir $OutputIsoPath 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "oscdimg.exe failed (exit $LASTEXITCODE): $oscdimgOut"
        }
      }
    }
  }
  finally {
    if (Test-Path -LiteralPath $workDir) {
      Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-LabStatus "Autoinstall ISO ready: $OutputIsoPath" -Level Success
  return $OutputIsoPath
}

function Update-GrubConfigFile {
  <#
  .SYNOPSIS
    Applies Add-AutoinstallKernelArgument to a grub.cfg file in place.
  #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string[]]$KernelArguments = @('autoinstall')
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "grub.cfg not found (extraction may have failed): $Path"
  }
  if (-not $PSCmdlet.ShouldProcess($Path, 'Inject autoinstall kernel arguments')) {
    return $Path
  }

  $content = Get-Content -LiteralPath $Path -Raw
  $updated = Add-AutoinstallKernelArgument -GrubConfiguration $content -KernelArguments $KernelArguments
  Set-Content -LiteralPath $Path -Value $updated -NoNewline:$false
  return $Path
}
