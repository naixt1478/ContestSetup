# setup-msys2.ps1

function Reset-MSYS2Completely
{
  Write-Section 'Reset existing MSYS2'
  Uninstall-WingetPackageIfExists -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'
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
  Invoke-MsysBashChecked 'pacman --needed --noconfirm --disable-download-timeout -S coreutils' -ExplainMsysTlsErrors
  if (-not (Test-Path $MsysCat)) { throw "cat.exe not found." }
}

if (Test-Path $MsysBash)
{
  Write-Host "MSYS2 bash.exe found at $MsysBash. Skipping installation." -ForegroundColor Green
}
else
{
  Reset-MSYS2Completely
  if (-not (Install-ByWinget -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2')) { Install-MSYS2Direct }

  $WaitCount = 0; while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
  if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
}

Write-Section 'Install MSYS2 packages'
Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Status "Initializing MSYS2" -PercentComplete 10
Invoke-MsysBashChecked 'echo MSYS2 initialized'
Install-Msys2CaCertificate

Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Status "Updating base packages (1/2)" -PercentComplete 30
Invoke-MsysBashChecked 'pacman --noconfirm --disable-download-timeout -Syuu' -ExplainMsysTlsErrors

Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Status "Updating base packages (2/2)" -PercentComplete 50
Invoke-MsysBashChecked 'pacman --noconfirm --disable-download-timeout -Syu' -ExplainMsysTlsErrors

$MsysPackages = @('mingw-w64-ucrt-x86_64-gcc', 'mingw-w64-ucrt-x86_64-gdb')
Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Status "Installing GCC/GDB" -PercentComplete 70
Invoke-MsysBashChecked ("pacman --needed --noconfirm --disable-download-timeout -S " + ($MsysPackages -join ' ')) -ExplainMsysTlsErrors

Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Status "Installing coreutils" -PercentComplete 90
Ensure-MsysCatInstalled

Write-Progress -Id 2 -ParentId 1 -Activity "MSYS2 Setup" -Completed

foreach ($RequiredPath in @((Join-Path $UcrtBin 'g++.exe'), (Join-Path $UcrtBin 'gcc.exe'), (Join-Path $UcrtBin 'gdb.exe'), $MsysCat))
{
  if (-not (Test-Path $RequiredPath)) { throw "Required tool not found: $RequiredPath" }
}
Write-Host 'MSYS2 UCRT64 GCC/GDB installed.' -ForegroundColor Green
