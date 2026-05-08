# setup-msys2.ps1

$MsysManagedMarker = Join-Path $MsysRoot '.contestsetup-managed'

function Write-Msys2ManagedMarker
{
  param([Parameter(Mandatory = $true)] [string]$InstallMethod)
  $Marker = [ordered]@{
    ManagedBy = 'ContestSetup'
    CreatedAt = (Get-Date).ToString('o')
    Root = $Root
    MsysRoot = $MsysRoot
    InstallMethod = $InstallMethod
  }
  Write-JsonUtf8NoBom -Path $MsysManagedMarker -InputObject $Marker -Depth 5
}

function Reset-MSYS2Completely
{
  Write-Section 'Reset existing MSYS2'
  $SystemDefaultMsysRoot = "$env:SystemDrive\msys64"
  if ((Normalize-PathForCompare $MsysRoot) -eq (Normalize-PathForCompare $SystemDefaultMsysRoot))
  {
    Uninstall-WingetPackageIfExists -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'
  }
  if (Test-Path $MsysRoot)
  {
    Write-Host "Removing existing MSYS2 without backup as requested..."
    Remove-Item -Path $MsysRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Install-MSYS2Direct
{
  Write-Section 'Install MSYS2 directly'
  if (Test-Path $MsysBash) { Write-Host "MSYS2 already installed: $MsysBash"; return }
  if ((Test-Path $MsysRoot) -and (-not (Test-Path $MsysBash)))
  {
    Write-Host "MSYS2 root exists but bash is missing. Reinstalling over it..."
  }
  Download-VerifiedFile -Url $Msys2InstallerUrl -OutFile $Msys2InstallerPath -AllowedPublisherKeywords @()
  $RootForInstaller = Convert-ToForwardSlashPath $MsysRoot
  $Process = Start-Process -FilePath $Msys2InstallerPath -ArgumentList @('in', '--confirm-command', '--accept-messages', '--root', $RootForInstaller) -Wait -PassThru
  if ($Process.ExitCode -ne 0) { throw "MSYS2 installer failed. Exit code: $($Process.ExitCode)" }
  $WaitCount = 0; while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
  if (-not (Test-Path $MsysBash)) { throw "MSYS2 installed, but bash.exe not found: $MsysBash" }
  Write-Host 'MSYS2 direct install completed.' -ForegroundColor Green
}

function Invoke-MsysBashChecked
{
  param([Parameter(Mandatory = $true)] [string]$Command, [switch]$ExplainMsysTlsErrors)
  if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
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
  if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
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
  Write-Section 'Configure MSYS2 official mirrors'
  $MirrorDir = Join-Path $MsysRoot 'etc\pacman.d'
  New-Item -ItemType Directory -Force -Path $MirrorDir | Out-Null

  $MirrorLists = @{
    'mirrorlist.msys' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/msys/$arch'
    )
    'mirrorlist.mingw32' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/mingw/i686'
    )
    'mirrorlist.mingw64' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/mingw/x86_64'
    )
    'mirrorlist.ucrt64' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/mingw/ucrt64'
    )
    'mirrorlist.clang64' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/mingw/clang64'
    )
    'mirrorlist.clangarm64' = @(
      '## ContestSetup: prefer the official MSYS2 repository to avoid stale mirror 404s.',
      'Server = https://repo.msys2.org/mingw/clangarm64'
    )
  }

  foreach ($Name in $MirrorLists.Keys)
  {
    Write-LinesUtf8NoBom -Path (Join-Path $MirrorDir $Name) -Lines ([string[]]$MirrorLists[$Name])
  }
}

function Sync-WindowsRootCertificatesToMsys2
{
  Write-Section 'Sync Windows root certificates to MSYS2'
  $AnchorRoot = Join-Path $MsysRoot 'etc\pki\ca-trust\source\anchors\contestsetup-windows-roots'
  New-Item -ItemType Directory -Force -Path $AnchorRoot | Out-Null

  $Certs = @()
  foreach ($StorePath in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root'))
  {
    try { $Certs += @(Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue) } catch {}
  }

  $Written = 0
  foreach ($Cert in ($Certs | Where-Object { $_ -and $_.Thumbprint } | Sort-Object Thumbprint -Unique))
  {
    try
    {
      $PemPath = Join-Path $AnchorRoot ("{0}.crt" -f $Cert.Thumbprint)
      $Base64 = [Convert]::ToBase64String($Cert.RawData, [Base64FormattingOptions]::InsertLineBreaks)
      $Pem = "-----BEGIN CERTIFICATE-----`n$Base64`n-----END CERTIFICATE-----`n"
      Write-TextUtf8NoBom -Path $PemPath -Content $Pem
      $Written++
    }
    catch {}
  }

  if ($Written -gt 0)
  {
    Invoke-MsysBashOutput 'update-ca-trust' | Out-Null
    Write-Host "Synced Windows root certificates to MSYS2: $Written" -ForegroundColor Green
  }
  else
  {
    Write-Host 'No Windows root certificates were exported.' -ForegroundColor Yellow
  }
}

function Invoke-PacmanChecked
{
  param([Parameter(Mandatory = $true)] [string]$Arguments, [int]$MaxAttempts = 3)

  $LastOutput = ''
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    $Command = "pacman --noconfirm --disable-download-timeout --overwrite '*' $Arguments"
    $Result = Invoke-MsysBashOutput $Command
    if ($Result.ExitCode -eq 0) { return }

    $LastOutput = ($Result.Output -join "`n")
    $LooksRetryable = $LastOutput -match 'requested URL returned error: 404|SSL certificate problem|self-signed certificate|failed retrieving file|too many errors'
    if ($Attempt -lt $MaxAttempts -and $LooksRetryable)
    {
      Write-Warning "pacman failed with a retryable mirror/TLS error. Refreshing package databases and retrying ($Attempt/$MaxAttempts)."
      Set-Msys2OfficialMirrors
      Invoke-MsysBashOutput "pacman --noconfirm --disable-download-timeout -Syy" | Out-Null
      Start-Sleep -Seconds 2
      continue
    }

    if ($LastOutput -match 'SSL certificate problem|self-signed certificate|verify|schannel|local issuer')
    {
      throw "MSYS2 pacman failed TLS verification. If this network uses antivirus/proxy HTTPS inspection, rerun with -Msys2CaCertificatePath pointing to the proxy root CA certificate.`nCommand: $Command`nOutput: $LastOutput"
    }
    throw "Native command failed: $MsysBash -lc $Command`nOutput: $LastOutput"
  }
}

function Install-Msys2CaCertificate
{
  if ([string]::IsNullOrWhiteSpace($Msys2CaCertificatePath)) { return }
  if (-not (Test-Path $Msys2CaCertificatePath)) { throw "CA cert not found: $Msys2CaCertificatePath" }
  $AnchorDir = Join-Path $MsysRoot 'etc\pki\ca-trust\source\anchors'
  New-Item -ItemType Directory -Force -Path $AnchorDir | Out-Null
  $BaseName = [IO.Path]::GetFileNameWithoutExtension($Msys2CaCertificatePath); if (-not $BaseName) { $BaseName = 'custom-root-ca' }
  $DestPath = Join-Path $AnchorDir "$BaseName.crt"
  Copy-Item -Path $Msys2CaCertificatePath -Destination $DestPath -Force
  Invoke-MsysBashChecked 'update-ca-trust'
}

function Ensure-MsysCatInstalled
{
  if (Test-Path $MsysCat) { Write-Host "cat.exe found."; return }
  Invoke-PacmanChecked '--needed -S coreutils'
  if (-not (Test-Path $MsysCat)) { throw "cat.exe not found." }
}

if (Test-Path $MsysBash)
{
  Write-Host "MSYS2 bash.exe found at $MsysBash. Skipping installation." -ForegroundColor Green
}
else
{
  Reset-MSYS2Completely
  $MsysInstallMethod = 'direct'
  $SystemDefaultMsysRoot = "$env:SystemDrive\msys64"
  $CanUseWingetForRequestedRoot = (Normalize-PathForCompare $MsysRoot) -eq (Normalize-PathForCompare $SystemDefaultMsysRoot)

  if ($CanUseWingetForRequestedRoot -and (Install-ByWinget -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'))
  {
    $MsysInstallMethod = 'winget'
  }
  else
  {
    Install-MSYS2Direct
  }

  $WaitCount = 0; while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
  if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
  Write-Msys2ManagedMarker -InstallMethod $MsysInstallMethod
}

Write-Section 'Install MSYS2 packages'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] MSYS2 Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Initializing MSYS2" -PercentComplete 10
Invoke-MsysBashChecked 'echo MSYS2 initialized'
Sync-WindowsRootCertificatesToMsys2
Install-Msys2CaCertificate
Set-Msys2OfficialMirrors

# Keep '*' quoted so bash passes it as pacman's overwrite pattern instead of expanding files in the current directory.
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Updating base packages (1/2)" -PercentComplete 30
Invoke-PacmanChecked '-Syuu'

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Updating base packages (2/2)" -PercentComplete 50
Invoke-PacmanChecked '-Syu'

$MsysPackages = @('mingw-w64-ucrt-x86_64-gcc', 'mingw-w64-ucrt-x86_64-gdb')
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Installing GCC/GDB" -PercentComplete 70
Invoke-PacmanChecked ("--needed -S " + ($MsysPackages -join ' '))

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Installing coreutils" -PercentComplete 90
Ensure-MsysCatInstalled

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed

foreach ($RequiredPath in @((Join-Path $UcrtBin 'g++.exe'), (Join-Path $UcrtBin 'gcc.exe'), (Join-Path $UcrtBin 'gdb.exe'), $MsysCat))
{
  if (-not (Test-Path $RequiredPath)) { throw "Required tool not found: $RequiredPath" }
}
Write-Host 'MSYS2 UCRT64 GCC/GDB installed.' -ForegroundColor Green
