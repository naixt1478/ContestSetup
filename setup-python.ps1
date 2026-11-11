# setup-python.ps1
# ContestSetup v2.0 -- Collision-Safe Python 3.10 Provisioning & Native python3.exe

function Reset-ManagedPython
{
  Write-Section "Reset managed Python $PythonVersion"
  if (Test-Path -LiteralPath $PythonDir)
  {
    $BackupRoot = Join-Path $BackupDir ("python-$TimeStamp")
    Backup-And-RemovePathSafe -Path $PythonDir -BackupRoot $BackupRoot
  }
}

function Find-ExistingSystemPython310
{
  $Candidates = New-Object System.Collections.Generic.List[string]
  if ($env:ProgramFiles) { $Candidates.Add((Join-Path $env:ProgramFiles 'Python310')) | Out-Null }
  if ($env:LOCALAPPDATA) { $Candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310')) | Out-Null }
  if (${env:ProgramFiles(x86)}) { $Candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Python310')) | Out-Null }

  foreach ($RegPath in @(
    "HKLM:\SOFTWARE\Python\PythonCore\3.10\InstallPath",
    "HKCU:\SOFTWARE\Python\PythonCore\3.10\InstallPath",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\3.10\InstallPath"
  )) {
    try
    {
      if (Test-Path -LiteralPath $RegPath)
      {
        $RegItem = Get-ItemProperty -LiteralPath $RegPath -ErrorAction SilentlyContinue
        if ($RegItem -and $RegItem.'(default)')
        {
          $Candidates.Add([string]$RegItem.'(default)'.TrimEnd('\')) | Out-Null
        }
      }
    }
    catch {}
  }

  foreach ($CandidateDir in ($Candidates | Select-Object -Unique))
  {
    if ([string]::IsNullOrWhiteSpace($CandidateDir)) { continue }
    if ((Normalize-PathForCompare $CandidateDir) -eq (Normalize-PathForCompare $PythonDir)) { continue }
    $CandidateExe = Join-Path $CandidateDir 'python.exe'
    if (Test-Path -LiteralPath $CandidateExe)
    {
      return $CandidateDir
    }
  }
  return $null
}

function Install-PythonFromNugetFallback
{
  Write-Host "Installing portable Python $PythonVersion from official PSF NuGet package into $PythonDir ..." -ForegroundColor Cyan
  Download-VerifiedFile -Url $PythonNugetUrl -OutFile $PythonNugetArchive -SkipAuthenticodeCheck -MinValidBytes 5MB
  $TempExtract = Join-Path $DownloadDir "python-nuget-extract-$TimeStamp"
  if (Test-Path -LiteralPath $TempExtract) { Remove-Item -LiteralPath $TempExtract -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $TempExtract | Out-Null
  try
  {
    Expand-ArchiveFast -ArchivePath $PythonNugetArchive -DestinationPath $TempExtract

    $ToolsDir = Join-Path $TempExtract 'tools'
    if (-not (Test-Path -LiteralPath (Join-Path $ToolsDir 'python.exe')))
    {
      throw 'NuGet package did not contain tools\python.exe'
    }
    New-Item -ItemType Directory -Force -Path $PythonDir | Out-Null
    Copy-Item -Path (Join-Path $ToolsDir '*') -Destination $PythonDir -Recurse -Force
  }
  finally
  {
    if (Test-Path -LiteralPath $TempExtract) { Remove-Item -LiteralPath $TempExtract -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Ensure-NativePython3Binary
{
  if ((Test-Path -LiteralPath $PythonExe) -and (-not (Test-Path -LiteralPath $Python3Exe)))
  {
    Copy-Item -LiteralPath $PythonExe -Destination $Python3Exe -Force
    Write-Host "Created native python3.exe binary: $Python3Exe" -ForegroundColor Green
  }
}

function Repair-PythonPthFileIfNeeded
{
  $StdLibOsPy = Join-Path $PythonDir 'Lib\os.py'
  if (-not (Test-Path -LiteralPath $StdLibOsPy)) { return }

  foreach ($PthFile in @(Get-ChildItem -Path $PythonDir -Filter 'python*._pth' -File -ErrorAction SilentlyContinue))
  {
    try
    {
      $RawPth = Read-TextUtf8 -Path $PthFile.FullName
      if ($RawPth -match '(?m)^#\s*import\s+site\b')
      {
        $UpdatedPth = [regex]::Replace($RawPth, '(?m)^#\s*import\s+site\b', 'import site')
        if ($UpdatedPth -notmatch '(?m)^Lib\s*$')
        {
          $UpdatedPth = "Lib`r`n" + $UpdatedPth
        }
        Write-TextUtf8NoBom -Path $PthFile.FullName -Content $UpdatedPth
        Write-Host "Enabled 'import site' in Python path configuration: $($PthFile.FullName)" -ForegroundColor Green
      }
    }
    catch
    {
      Write-Warning "Could not update $($PthFile.FullName): $($_.Exception.Message)"
    }
  }
}

function Assert-PythonRuntimeHealthy
{
  Repair-PythonPthFileIfNeeded
  Ensure-NativePython3Binary
  $PyVerResult = Invoke-NativeChecked -FilePath $PythonExe -ArgumentList @('--version') -Quiet
  $FirstVerLine = [string]($PyVerResult.Output | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($FirstVerLine) -and (Get-Variable -Name 'ContestToolVersions' -Scope Global -ErrorAction SilentlyContinue) -and ($Global:ContestToolVersions -is [hashtable]))
  {
    $Global:ContestToolVersions[$PythonExe] = $FirstVerLine
  }
  Invoke-NativeChecked -FilePath $Python3Exe -ArgumentList @('--version') -Quiet | Out-Null
  Invoke-NativeChecked -FilePath $PythonExe -ArgumentList @('-c', 'import site, encodings, collections, heapq, math') -Quiet | Out-Null
}

function Install-PythonDirect
{
  Write-Section "Install Python $PythonVersion"
  $PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Python Setup"
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Checking managed installation...' -PercentComplete 10

  $InstalledMsiByContestSetup = $false

  if (-not (Test-Path -LiteralPath $PythonExe))
  {
    $PreExistingSystemPy = Find-ExistingSystemPython310

    if (-not (Test-Path -LiteralPath $PythonInstaller))
    {
      Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Downloading Python...' -PercentComplete 30
      Download-VerifiedFile -Url $PythonUrl -OutFile $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation') -MinValidBytes 15MB
    }
    else
    {
      Assert-AuthenticodeValid -Path $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation')
    }

    Write-Host "Installing Python $PythonVersion..."
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Installing Python...' -PercentComplete 60
    $Args = "/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 Include_launcher=0 TargetDir=`"$PythonDir`""

    $LastExitCode = -1
    for ($MsiAttempt = 1; $MsiAttempt -le 5; $MsiAttempt++)
    {
      $PythonProcess = Start-Process -FilePath $PythonInstaller -ArgumentList $Args -Wait -PassThru
      $LastExitCode = [int]$PythonProcess.ExitCode
      # Exit code 1618 = ERROR_INSTALL_ALREADY_RUNNING (another MSI is in progress)
      if ($LastExitCode -eq 1618 -and $MsiAttempt -lt 5)
      {
        Write-Warning "Windows Installer is busy (exit code 1618). Waiting 5 seconds before retry ($MsiAttempt/5)..."
        Start-Sleep -Seconds 5
        continue
      }
      break
    }

    if (Test-Path -LiteralPath $PythonExe)
    {
      $InstalledMsiByContestSetup = ($null -eq $PreExistingSystemPy)
    }
    else
    {
      # If Python 3.10.11 was already installed elsewhere on the PC, WiX Burn may exit 0 (or 1638) without populating $PythonDir
      Write-Warning "Standard installer did not populate $PythonExe (exit code $LastExitCode; pre-existing Python 3.10 collision likely). Activating collision-safe fallback..."
      $ExistingPyDir = if ($PreExistingSystemPy) { $PreExistingSystemPy } else { Find-ExistingSystemPython310 }
      $SeededFromSystem = $false
      if (-not [string]::IsNullOrWhiteSpace($ExistingPyDir) -and (Test-Path -LiteralPath (Join-Path $ExistingPyDir 'python.exe')))
      {
        Write-Host "Seeding isolated $PythonDir from existing system Python 3.10 at $ExistingPyDir ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path $PythonDir | Out-Null
        & robocopy.exe $ExistingPyDir $PythonDir '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' '/MT:16' | Out-Null
        if ($LASTEXITCODE -ge 8)
        {
          Write-Warning "robocopy from $ExistingPyDir failed with exit code $LASTEXITCODE. Falling back to official PSF NuGet package..."
          Remove-Item -LiteralPath $PythonDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        elseif (Test-Path -LiteralPath $PythonExe)
        {
          $SeededFromSystem = $true
          $InstalledMsiByContestSetup = $false
        }
      }

      if (-not $SeededFromSystem)
      {
        Install-PythonFromNugetFallback
        $InstalledMsiByContestSetup = $false
      }
    }
  }

  if (-not (Test-Path -LiteralPath $PythonExe))
  {
    throw "Python install failed or python.exe not found: $PythonExe"
  }

  Assert-PythonRuntimeHealthy

  if (Get-Command Update-ContestStateManifest -ErrorAction SilentlyContinue)
  {
    Update-ContestStateManifest -Properties @{
      PythonInstalledByContestSetup = $InstalledMsiByContestSetup
      PythonDir                     = $PythonDir
    }
  }

  $Global:PythonExe = $PythonExe
  Write-Host "Python installed and verified: $PythonExe (python3: $Python3Exe)" -ForegroundColor Green
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}

if (Test-Path -LiteralPath $PythonDir)
{
  if (-not (Test-Path -LiteralPath $PythonExe))
  {
    Reset-ManagedPython
  }
  else
  {
    try
    {
      Assert-PythonRuntimeHealthy
      Write-Host "Managed Python $PythonVersion is already installed and healthy at $PythonExe. Skipping download/install." -ForegroundColor Green
      $Global:PythonExe = $PythonExe
    }
    catch
    {
      Write-Warning "Existing Python installation at $PythonDir failed runtime health check ($($_.Exception.Message)). Reinstalling..."
      Reset-ManagedPython
    }
  }
}

$ConfiguredPythonExe = Get-Variable -Name 'PythonExe' -Scope Global -ErrorAction SilentlyContinue
$ConfiguredPythonExeValue = if ($ConfiguredPythonExe) { [string]$ConfiguredPythonExe.Value } else { '' }
if ([string]::IsNullOrWhiteSpace($ConfiguredPythonExeValue) -or -not (Test-Path -LiteralPath $ConfiguredPythonExeValue))
{
  Install-PythonDirect
}
