# setup-msys2.ps1
# ContestSetup v2.0 -- Fast & Self-Healing MSYS2 UCRT64 GCC/GDB Provisioning

function Show-MSYS2PreservedNotice
{
  Write-Section 'Check existing MSYS2'
  Write-Host "MSYS2 is preserved at $MsysRoot. Existing files are not removed by ContestSetup." -ForegroundColor Yellow
}

function Stop-Msys2GpgDaemons
{
  foreach ($DaemonName in @('gpg-agent', 'dirmngr'))
  {
    Get-Process -Name $DaemonName -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -and (Test-PathInside -ChildPath $_.Path -ParentPath $MsysRoot) } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

function Remove-StaleMsys2Locks
{
  $DbLockPath = Join-Path $MsysRoot 'var\lib\pacman\db.lck'
  $ActivePacman = @(Get-Process -Name 'pacman' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and (Test-PathInside -ChildPath $_.Path -ParentPath $MsysRoot) } catch { $false }
  })

  if ($ActivePacman.Count -eq 0)
  {
    Stop-Msys2GpgDaemons

    if (Test-Path -LiteralPath $DbLockPath)
    {
      Write-Warning "Removing stale MSYS2 pacman lock file: $DbLockPath"
      Remove-Item -LiteralPath $DbLockPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-Msys2ToolsReady
{
  $RequiredPaths = @(
    (Join-Path $UcrtBin 'g++.exe'),
    (Join-Path $UcrtBin 'gcc.exe'),
    (Join-Path $UcrtBin 'gdb.exe'),
    $MsysCat
  )
  foreach ($ToolPath in $RequiredPaths)
  {
    if (-not (Test-Path -LiteralPath $ToolPath)) { return $false }
  }

  $OldPath = $env:Path
  try
  {
    $env:Path = "$UcrtBin;$(Split-Path -Path $MsysBash -Parent);$OldPath"
    foreach ($ToolPath in $RequiredPaths)
    {
      $Res = Invoke-NativeCommand -FilePath $ToolPath -ArgumentList @('--version') -Quiet
      if ($Res.ExitCode -ne 0) { return $false }
      $FirstVerLine = [string]($Res.Output | Select-Object -First 1)
      if (-not [string]::IsNullOrWhiteSpace($FirstVerLine) -and (Get-Variable -Name 'ContestToolVersions' -Scope Global -ErrorAction SilentlyContinue) -and ($Global:ContestToolVersions -is [hashtable]))
      {
        $Global:ContestToolVersions[$ToolPath] = $FirstVerLine
      }
    }
    return $true
  }
  catch
  {
    return $false
  }
  finally
  {
    $env:Path = $OldPath
  }
}

function Install-MSYS2Direct
{
  Write-Section 'Install MSYS2 directly'
  if (Test-Path -LiteralPath $MsysBash) { Write-Host "MSYS2 already installed: $MsysBash"; return }
  if ((Test-Path -LiteralPath $MsysRoot) -and (-not (Test-Path -LiteralPath $MsysBash)))
  {
    Write-Host 'MSYS2 root exists but bash is missing. Reinstalling over it...'
  }
  Download-VerifiedFile -Url $Msys2InstallerUrl -OutFile $Msys2InstallerPath -AllowedPublisherKeywords @() -SkipAuthenticodeCheck -MinValidBytes 40MB
  $RootForInstaller = Convert-ToForwardSlashPath $MsysRoot
  $QuotedInstallerArgs = (@('in', '--confirm-command', '--accept-messages', '--root', $RootForInstaller) | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
  $Process = Start-Process -FilePath $Msys2InstallerPath -ArgumentList $QuotedInstallerArgs -Wait -PassThru
  if ($Process.ExitCode -ne 0) { throw "MSYS2 installer failed. Exit code: $($Process.ExitCode)" }
  $WaitCount = 0; while (-not (Test-Path -LiteralPath $MsysBash) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
  if (-not (Test-Path -LiteralPath $MsysBash)) { throw "MSYS2 installed, but bash.exe not found: $MsysBash" }
  Write-Host 'MSYS2 direct install completed.' -ForegroundColor Green
}

function Invoke-MsysBashChecked
{
  param([Parameter(Mandatory = $true)] [string]$Command, [switch]$ExplainMsysTlsErrors)
  if (-not (Test-Path -LiteralPath $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
  $OldMSYSTEM = $env:MSYSTEM; $OldCHERE = $env:CHERE_INVOKING
  try
  {
    $env:MSYSTEM = 'UCRT64'; $env:CHERE_INVOKING = '1'
    $Result = Invoke-NativeCommand -FilePath $MsysBash -ArgumentList @('-lc', $Command) -StreamOutput
    if ($Result.ExitCode -ne 0)
    {
      $OutputText = ($Result.Output -join "`n")
      if ($ExplainMsysTlsErrors -and ($OutputText -match 'SSL certificate|self-signed certificate|verify|schannel|local issuer'))
      {
        throw "MSYS2 pacman failed TLS verify. Command: $Command`nOutput: $OutputText`nCheck anti-virus or proxy."
      }
      throw "Native command failed: $MsysBash -lc $Command"
    }
  }
  finally
  {
    if ($null -eq $OldMSYSTEM) { Remove-Item Env:\MSYSTEM -ErrorAction SilentlyContinue } else { $env:MSYSTEM = $OldMSYSTEM }
    if ($null -eq $OldCHERE) { Remove-Item Env:\CHERE_INVOKING -ErrorAction SilentlyContinue } else { $env:CHERE_INVOKING = $OldCHERE }
  }
}

function Invoke-MsysBashOutput
{
  param([Parameter(Mandatory = $true)] [string]$Command)
  if (-not (Test-Path -LiteralPath $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
  $OldMSYSTEM = $env:MSYSTEM; $OldCHERE = $env:CHERE_INVOKING
  try
  {
    $env:MSYSTEM = 'UCRT64'; $env:CHERE_INVOKING = '1'
    return Invoke-NativeCommand -FilePath $MsysBash -ArgumentList @('-lc', $Command) -StreamOutput
  }
  finally
  {
    if ($null -eq $OldMSYSTEM) { Remove-Item Env:\MSYSTEM -ErrorAction SilentlyContinue } else { $env:MSYSTEM = $OldMSYSTEM }
    if ($null -eq $OldCHERE) { Remove-Item Env:\CHERE_INVOKING -ErrorAction SilentlyContinue } else { $env:CHERE_INVOKING = $OldCHERE }
  }
}

function Set-Msys2OfficialMirrors
{
  Write-Section 'Configure MSYS2 high-speed Korean & official mirrors'
  $MirrorDir = Join-Path $MsysRoot 'etc\pacman.d'
  New-Item -ItemType Directory -Force -Path $MirrorDir | Out-Null

  $MirrorLists = @{
    'mirrorlist.msys' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/msys/$arch',
      'Server = https://mirror.harukasan.org/msys2/msys/$arch',
      'Server = https://mirror.msys2.org/msys/$arch',
      'Server = https://repo.msys2.org/msys/$arch'
    )
    'mirrorlist.mingw32' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/mingw/i686',
      'Server = https://mirror.harukasan.org/msys2/mingw/i686',
      'Server = https://mirror.msys2.org/mingw/i686',
      'Server = https://repo.msys2.org/mingw/i686'
    )
    'mirrorlist.mingw64' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/mingw/x86_64',
      'Server = https://mirror.harukasan.org/msys2/mingw/x86_64',
      'Server = https://mirror.msys2.org/mingw/x86_64',
      'Server = https://repo.msys2.org/mingw/x86_64'
    )
    'mirrorlist.ucrt64' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/mingw/ucrt64',
      'Server = https://mirror.harukasan.org/msys2/mingw/ucrt64',
      'Server = https://mirror.msys2.org/mingw/ucrt64',
      'Server = https://repo.msys2.org/mingw/ucrt64'
    )
    'mirrorlist.clang64' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/mingw/clang64',
      'Server = https://mirror.harukasan.org/msys2/mingw/clang64',
      'Server = https://mirror.msys2.org/mingw/clang64',
      'Server = https://repo.msys2.org/mingw/clang64'
    )
    'mirrorlist.clangarm64' = @(
      '## ContestSetup v2.0: prioritize Korean high-speed mirrors with official CDN/origin failover',
      'Server = https://ftp.kaist.ac.kr/msys2/mingw/clangarm64',
      'Server = https://mirror.harukasan.org/msys2/mingw/clangarm64',
      'Server = https://mirror.msys2.org/mingw/clangarm64',
      'Server = https://repo.msys2.org/mingw/clangarm64'
    )
  }

  foreach ($Name in $MirrorLists.Keys)
  {
    $TargetFile = Join-Path $MirrorDir $Name
    $BackupFile = "$TargetFile.contest-bak"
    if ((Test-Path -LiteralPath $TargetFile) -and (-not (Test-Path -LiteralPath $BackupFile)))
    {
      Copy-Item -LiteralPath $TargetFile -Destination $BackupFile -Force -ErrorAction SilentlyContinue
    }
    Write-LinesUtf8NoBom -Path $TargetFile -Lines ([string[]]$MirrorLists[$Name])
  }
}

function Optimize-Msys2PacmanConfig
{
  $PacmanConfPath = Join-Path $MsysRoot 'etc\pacman.conf'
  if (-not (Test-Path -LiteralPath $PacmanConfPath)) { return }

  try
  {
    $BackupConf = "$PacmanConfPath.contest-bak"
    if (-not (Test-Path -LiteralPath $BackupConf))
    {
      Copy-Item -LiteralPath $PacmanConfPath -Destination $BackupConf -Force -ErrorAction SilentlyContinue
    }

    $RawConf = Read-TextUtf8 -Path $PacmanConfPath
    if ([string]::IsNullOrWhiteSpace($RawConf)) { return }

    # Enable ParallelDownloads = 8
    if ($RawConf -match '(?m)^#?\s*ParallelDownloads\s*=.*$')
    {
      $RawConf = [regex]::Replace($RawConf, '(?m)^#?\s*ParallelDownloads\s*=.*$', 'ParallelDownloads = 8')
    }
    elseif ($RawConf -match '(?m)^\[options\]\s*$')
    {
      $RawConf = [regex]::Replace($RawConf, '(?m)^(\[options\]\s*)$', "`$1`nParallelDownloads = 8")
    }

    # Disable unused architecture repos (mingw32, mingw64, clang32, clang64, clangarm64) so pacman -Sy only syncs ucrt64 and msys
    foreach ($UnusedRepo in @('mingw32', 'mingw64', 'clang32', 'clang64', 'clangarm64'))
    {
      $Pattern = "(?m)^\[$UnusedRepo\]\r?\nInclude\s*=\s*/etc/pacman\.d/mirrorlist\.$UnusedRepo"
      $Replacement = "#[$UnusedRepo]`n#Include = /etc/pacman.d/mirrorlist.$UnusedRepo"
      $RawConf = [regex]::Replace($RawConf, $Pattern, $Replacement)
    }

    Write-TextUtf8NoBom -Path $PacmanConfPath -Content $RawConf
    Write-Host 'Optimized pacman.conf (ParallelDownloads = 8, active repos: ucrt64 + msys).' -ForegroundColor Green
  }
  catch
  {
    Write-Warning "Could not optimize pacman.conf: $($_.Exception.Message)"
  }
}

function Seed-Msys2PackageCacheFromCacheDir
{
  if ([string]::IsNullOrWhiteSpace($CacheDir) -or (-not (Test-Path -LiteralPath $CacheDir)))
  {
    return $false
  }

  $SeededAny = $false
  $PacmanPkgDest = Join-Path $MsysRoot 'var\cache\pacman\pkg'
  foreach ($PkgSubName in @('msys2-pkg', 'pacman-pkg'))
  {
    $SrcPkgDir = Join-Path $CacheDir $PkgSubName
    if (Test-Path -LiteralPath $SrcPkgDir)
    {
      $CachedPkgs = @(Get-ChildItem -Path $SrcPkgDir -Filter '*.pkg.tar.*' -File -ErrorAction SilentlyContinue)
      if ($CachedPkgs.Count -gt 0)
      {
        New-Item -ItemType Directory -Force -Path $PacmanPkgDest | Out-Null
        foreach ($PkgItem in $CachedPkgs)
        {
          $DestPkgFile = Join-Path $PacmanPkgDest $PkgItem.Name
          if (-not (Test-Path -LiteralPath $DestPkgFile))
          {
            Copy-Item -LiteralPath $PkgItem.FullName -Destination $DestPkgFile -Force
          }
        }
        Write-Host "Seeded $($CachedPkgs.Count) MSYS2 package archive(s) from $SrcPkgDir into $PacmanPkgDest" -ForegroundColor Green
        $SeededAny = $true
        break
      }
    }
  }

  $SrcSyncDir = Join-Path $CacheDir 'msys2-sync'
  $DestSyncDir = Join-Path $MsysRoot 'var\lib\pacman\sync'
  if (Test-Path -LiteralPath $SrcSyncDir)
  {
    $CachedDbs = @(Get-ChildItem -Path $SrcSyncDir -Filter '*.db*' -File -ErrorAction SilentlyContinue)
    if ($CachedDbs.Count -gt 0)
    {
      New-Item -ItemType Directory -Force -Path $DestSyncDir | Out-Null
      foreach ($DbItem in $CachedDbs)
      {
        $DestDbFile = Join-Path $DestSyncDir $DbItem.Name
        Copy-Item -LiteralPath $DbItem.FullName -Destination $DestDbFile -Force
      }
      Write-Host "Seeded $($CachedDbs.Count) MSYS2 sync database file(s) from $SrcSyncDir into $DestSyncDir" -ForegroundColor Green
    }
  }

  return $SeededAny
}

function Ensure-Msys2KeyringReady
{
  $TrustDbPath = Join-Path $MsysRoot 'etc\pacman.d\gnupg\trustdb.gpg'
  if (-not (Test-Path -LiteralPath $TrustDbPath))
  {
    Write-Host 'Initializing MSYS2 pacman keyring (pacman-key --init && pacman-key --populate msys2)...' -ForegroundColor Cyan
    Remove-StaleMsys2Locks
    Invoke-MsysBashChecked 'pacman-key --init && pacman-key --populate msys2'
    Stop-Msys2GpgDaemons
  }
}

function Sync-WindowsRootCertificatesToMsys2
{
  Write-Section 'Sync Windows root certificates to MSYS2 (single PEM bundle)'
  $AnchorDir = Join-Path $MsysRoot 'etc\pki\ca-trust\source\anchors'
  New-Item -ItemType Directory -Force -Path $AnchorDir | Out-Null
  $BundlePath = Join-Path $AnchorDir 'contestsetup-windows-roots.pem'

  $Certs = @()
  foreach ($StorePath in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root'))
  {
    try { $Certs += @(Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue) } catch {}
  }

  $PemBuilder = New-Object System.Text.StringBuilder
  $Written = 0
  foreach ($Cert in ($Certs | Where-Object { $_ -and $_.Thumbprint } | Sort-Object Thumbprint -Unique))
  {
    try
    {
      $Base64 = [Convert]::ToBase64String($Cert.RawData, [Base64FormattingOptions]::InsertLineBreaks)
      [void]$PemBuilder.AppendLine("-----BEGIN CERTIFICATE-----")
      [void]$PemBuilder.AppendLine($Base64)
      [void]$PemBuilder.AppendLine("-----END CERTIFICATE-----")
      $Written++
    }
    catch {}
  }

  if ($Written -gt 0)
  {
    Write-TextUtf8NoBom -Path $BundlePath -Content $PemBuilder.ToString()
    Invoke-MsysBashOutput 'update-ca-trust' | Out-Null
    Write-Host "Synced $Written Windows root certificates to MSYS2 bundle: $BundlePath" -ForegroundColor Green
  }
  else
  {
    Write-Host 'No Windows root certificates were exported.' -ForegroundColor Yellow
  }
}

$Script:MsysRootCertsSynced = $false

function Invoke-PacmanChecked
{
  param([Parameter(Mandatory = $true)] [string]$Arguments, [int]$MaxAttempts = 3)

  $LastOutput = ''
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    Remove-StaleMsys2Locks
    $Command = "pacman --noconfirm --disable-download-timeout --overwrite '*' $Arguments"
    $Result = Invoke-MsysBashOutput $Command
    if ($Result.ExitCode -eq 0) { return }

    $LastOutput = ($Result.Output -join "`n")
    $IsTlsError = $LastOutput -match 'SSL certificate problem|self-signed certificate|verify|schannel|local issuer'
    $IsLockError = $LastOutput -match 'unable to lock database|db\.lck'
    $IsPgpError = $LastOutput -match 'PGP signature|unknown trust|marginal trust|missing required signature|invalid or corrupted package \(PGP signature\)|key .* could not be looked up'
    $IsNetworkError = $LastOutput -match 'Could not resolve host|failed retrieving file|Connection timed out'
    $LooksRetryable = $IsTlsError -or $IsLockError -or $IsPgpError -or ($LastOutput -match 'requested URL returned error: 404|failed retrieving file|too many errors|error: failed to commit transaction')

    if ($IsTlsError -and (-not $Script:MsysRootCertsSynced))
    {
      Write-Warning 'Detected TLS/SSL error during pacman; syncing Windows root certificates into MSYS2 trust store...'
      Sync-WindowsRootCertificatesToMsys2
      $Script:MsysRootCertsSynced = $true
    }

    if ($IsPgpError)
    {
      Write-Warning 'Detected PGP/keyring trust error during pacman; refreshing msys2-keyring and repopulating keys...'
      try
      {
        Ensure-Msys2KeyringReady
        Invoke-MsysBashOutput 'pacman --noconfirm --disable-download-timeout -Sy msys2-keyring && pacman-key --populate msys2' | Out-Null
        Stop-Msys2GpgDaemons
      }
      catch
      {
        Write-Warning "Keyring refresh attempt encountered warning: $($_.Exception.Message)"
      }
    }

    if ($IsNetworkError)
    {
      $PkgCacheDir = Join-Path $MsysRoot 'var\cache\pacman\pkg'
      $CachedArchives = if (Test-Path -LiteralPath $PkgCacheDir) { @(Get-ChildItem -Path $PkgCacheDir -Filter '*.pkg.tar.*' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' }) } else { @() }
      if ($CachedArchives.Count -gt 0 -and ($Arguments -match 'mingw-w64-ucrt-x86_64-gcc'))
      {
        Write-Warning 'Network mirrors unreachable; attempting offline installation from seeded pacman package cache...'
        $OfflineRes = Invoke-MsysBashOutput 'pacman --noconfirm --needed --overwrite ''*'' -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils || (shopt -s nullglob; IFS=$''\n''; pkgs=(/var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.xz); [ ${#pkgs[@]} -gt 0 ] && pacman --noconfirm --needed --overwrite ''*'' -U ${pkgs[@]})'
        if ($OfflineRes.ExitCode -eq 0) { return }
      }
    }

    if ($Attempt -lt $MaxAttempts -and $LooksRetryable)
    {
      Write-Warning "pacman failed with a retryable error. Recovering locks/mirrors and retrying ($Attempt/$MaxAttempts)."
      Remove-StaleMsys2Locks
      Set-Msys2OfficialMirrors
      Invoke-MsysBashOutput 'pacman --noconfirm --disable-download-timeout -Syy' | Out-Null
      Start-Sleep -Seconds 2
      continue
    }

    if ($IsTlsError)
    {
      throw "MSYS2 pacman failed TLS verification. If this network uses antivirus/proxy HTTPS inspection, rerun with -Msys2CaCertificatePath pointing to the proxy root CA certificate.`nCommand: $Command`nOutput: $LastOutput"
    }
    throw "Native command failed: $MsysBash -lc $Command`nOutput: $LastOutput"
  }
}

function Install-Msys2CaCertificate
{
  if ([string]::IsNullOrWhiteSpace($Msys2CaCertificatePath)) { return }
  if (-not (Test-Path -LiteralPath $Msys2CaCertificatePath)) { throw "CA cert not found: $Msys2CaCertificatePath" }
  $AnchorDir = Join-Path $MsysRoot 'etc\pki\ca-trust\source\anchors'
  New-Item -ItemType Directory -Force -Path $AnchorDir | Out-Null
  $BaseName = [IO.Path]::GetFileNameWithoutExtension($Msys2CaCertificatePath); if (-not $BaseName) { $BaseName = 'custom-root-ca' }
  $CustomFileName = "$BaseName.crt"
  $DestPath = Join-Path $AnchorDir $CustomFileName
  Copy-Item -LiteralPath $Msys2CaCertificatePath -Destination $DestPath -Force
  Invoke-MsysBashChecked 'update-ca-trust'
  if (Get-Command Update-ContestStateManifest -ErrorAction SilentlyContinue)
  {
    Update-ContestStateManifest -Properties @{ CustomCaFileName = $CustomFileName }
  }
}

function Ensure-MsysCatInstalled
{
  if (Test-Path -LiteralPath $MsysCat) { Write-Host 'cat.exe found.'; return }
  Invoke-PacmanChecked '--needed -S coreutils'
  if (-not (Test-Path -LiteralPath $MsysCat)) { throw 'cat.exe not found.' }
}

function Test-Msys2RequiredBinariesExist
{
  foreach ($ReqBin in @((Join-Path $UcrtBin 'g++.exe'), (Join-Path $UcrtBin 'gcc.exe'), (Join-Path $UcrtBin 'gdb.exe'), $MsysCat))
  {
    if (-not (Test-Path -LiteralPath $ReqBin)) { return $false }
  }
  return $true
}

if (Test-Path -LiteralPath $MsysBash)
{
  Write-Host "MSYS2 bash.exe found at $MsysBash. Skipping base installation." -ForegroundColor Green
}
else
{
  $SystemDefaultMsysRoot = "$env:SystemDrive\msys64"
  $CanUseWingetForRequestedRoot = (Normalize-PathForCompare $MsysRoot) -eq (Normalize-PathForCompare $SystemDefaultMsysRoot)
  if ((Test-Path -LiteralPath $MsysRoot) -and (-not (Test-Path -LiteralPath $MsysBash)))
  {
    Show-MSYS2PreservedNotice
  }

  $WingetInstalledMsys2 = $false
  if ($CanUseWingetForRequestedRoot -and (-not (Test-ValidCachedInstallerFile -Path $Msys2InstallerPath -MinBytes 40MB)))
  {
    $WingetInstalledMsys2 = Install-ByWinget -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'
  }

  # Only wait for winget post-install population if winget actually reported success
  if ($WingetInstalledMsys2)
  {
    $WaitCount = 0
    while (-not (Test-Path -LiteralPath $MsysBash) -and $WaitCount -lt 30)
    {
      Start-Sleep -Seconds 2
      $WaitCount++
    }
  }

  if (-not (Test-Path -LiteralPath $MsysBash))
  {
    Install-MSYS2Direct
  }

  $WaitCount = 0; while (-not (Test-Path -LiteralPath $MsysBash) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
  if (-not (Test-Path -LiteralPath $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
}

Write-Section 'Install MSYS2 packages'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] MSYS2 Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Checking MSYS2 toolchain...' -PercentComplete 10

Remove-StaleMsys2Locks

if ((-not $ForceUpdate) -and (Test-Msys2ToolsReady))
{
  Write-Host 'MSYS2 UCRT64 GCC, GDB, and cat are already installed and verified. Skipping pacman sync/upgrade (use -ForceUpdate to force).' -ForegroundColor Green
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}
else
{
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Initializing MSYS2, Keyring & Mirrors...' -PercentComplete 20
  Invoke-MsysBashChecked 'echo MSYS2 initialized'
  Install-Msys2CaCertificate
  Ensure-Msys2KeyringReady
  $SeededFromCache = [bool](Seed-Msys2PackageCacheFromCacheDir)
  Set-Msys2OfficialMirrors
  Optimize-Msys2PacmanConfig

  $OfflineCacheInstallSucceeded = $false
  if ($SeededFromCache -and (-not $ForceUpdate))
  {
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Installing GCC, GDB, and coreutils from seeded offline cache...' -PercentComplete 45
    Write-Host 'Attempting zero-bandwidth offline installation from seeded pacman cache...' -ForegroundColor Cyan
    Remove-StaleMsys2Locks
    $OfflineCachedRes = Invoke-MsysBashOutput "pacman --noconfirm --needed --overwrite '*' -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils"
    if (($OfflineCachedRes.ExitCode -ne 0) -or (-not (Test-Msys2RequiredBinariesExist)))
    {
      Remove-StaleMsys2Locks
      $OfflineLocalRes = Invoke-MsysBashOutput 'shopt -s nullglob; IFS=$''\n''; pkgs=(/var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.xz); [ ${#pkgs[@]} -gt 0 ] && pacman --noconfirm --needed --overwrite ''*'' -U ${pkgs[@]}'
      if ($OfflineLocalRes.ExitCode -eq 0 -and (Test-Msys2RequiredBinariesExist))
      {
        $OfflineCacheInstallSucceeded = $true
      }
    }
    else
    {
      $OfflineCacheInstallSucceeded = $true
    }

    if ($OfflineCacheInstallSucceeded)
    {
      Write-Host 'Offline MSYS2 toolchain installation from seeded cache succeeded.' -ForegroundColor Green
    }
    else
    {
      Write-Warning 'Seeded MSYS2 cache did not satisfy all required packages offline; falling back to online mirror sync (-Syu)...'
    }
  }

  if (-not $OfflineCacheInstallSucceeded)
  {
    # Stage 1 combined pacman transaction (--needed -Syu); if SyncFirst updates core runtime and exits 0 early, Stage 2 installs toolchain
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Installing/Updating GCC, GDB, and coreutils...' -PercentComplete 55
    try
    {
      Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils'
    }
    catch
    {
      Write-Warning "Combined pacman transaction interrupted or required two-stage runtime upgrade ($($_.Exception.Message)). Falling back to two-stage upgrade..."
      Remove-StaleMsys2Locks
      Invoke-PacmanChecked '-Syuu'
      Remove-StaleMsys2Locks
      Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils'
    }

    Remove-StaleMsys2Locks

    # Two-stage SyncFirst post-check: when msys2-runtime/pacman/bash self-upgrades, stage 1 exits 0 before installing requested target packages
    if (-not (Test-Msys2RequiredBinariesExist))
    {
      Write-Host 'MSYS2 core runtime updated in stage 1 (SyncFirst); running stage-2 toolchain installation...' -ForegroundColor Cyan
      Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Running Stage-2 GCC/GDB/coreutils installation...' -PercentComplete 78
      Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils'
      Remove-StaleMsys2Locks
    }
  }

  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Verifying coreutils...' -PercentComplete 90
  Ensure-MsysCatInstalled
  Remove-StaleMsys2Locks

  # Populate version cache after installation so setup-wrappers.ps1 avoids redundant --version spawns
  Test-Msys2ToolsReady | Out-Null

  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}

foreach ($RequiredPath in @((Join-Path $UcrtBin 'g++.exe'), (Join-Path $UcrtBin 'gcc.exe'), (Join-Path $UcrtBin 'gdb.exe'), $MsysCat))
{
  if (-not (Test-Path -LiteralPath $RequiredPath)) { throw "Required tool not found: $RequiredPath" }
}
Write-Host 'MSYS2 UCRT64 GCC/GDB installed and verified.' -ForegroundColor Green
