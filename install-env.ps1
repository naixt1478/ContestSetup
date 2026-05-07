# install-env.ps1
# Modular Contest Environment Setup Installer

[CmdletBinding()]
param(
  [switch]$KeepVSCode,
  [switch]$NoPause,
  [switch]$SkipSignatureCheck,
  [string]$Root = "$env:SystemDrive\CPTools",
  [string]$MsysRoot = "$env:SystemDrive\msys64",
  [string]$Msys2CaCertificatePath = '',
  [string]$PythonVersion = '3.10.11'
)

$ErrorActionPreference = "Stop"

# When run via irm|iex, param() is ignored. Ensure defaults are set.
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = "$env:SystemDrive\CPTools" }
if ([string]::IsNullOrWhiteSpace($MsysRoot)) { $MsysRoot = "$env:SystemDrive\msys64" }
if ([string]::IsNullOrWhiteSpace($Msys2CaCertificatePath)) { $Msys2CaCertificatePath = '' }
if ([string]::IsNullOrWhiteSpace($PythonVersion)) { $PythonVersion = '3.10.11' }

$RepoOwner = "naixt1478"
$RepoName = "ContestSetup"
$Branch = "main"
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

function Test-IsAdmin
{
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell
{
  $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($Pwsh) { return $Pwsh.Source }
  return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}
if (-not (Test-IsAdmin))
{
  Write-Host "Requesting administrator permission..." -ForegroundColor Yellow

  $SelfPath = $MyInvocation.MyCommand.Path

  if ([string]::IsNullOrWhiteSpace($SelfPath))
  {
    $TempRoot = Join-Path $env:TEMP "contest-env-installer"
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

    $SelfPath = Join-Path $TempRoot "install-env.ps1"
    $OldProgressPref = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-RestMethod -Uri "$RawBase/install-env.ps1" -OutFile $SelfPath -ErrorAction Stop
    } finally {
        $ProgressPreference = $OldProgressPref
    }
  }

  $StartArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $SelfPath
  )

  if ($KeepVSCode) { $StartArgs += "-KeepVSCode" }
  if ($NoPause) { $StartArgs += "-NoPause" }
  if ($SkipSignatureCheck) { $StartArgs += "-SkipSignatureCheck" }

  if (-not [string]::IsNullOrWhiteSpace($Root))
  {
    $StartArgs += "-Root"
    $StartArgs += $Root
  }

  if (-not [string]::IsNullOrWhiteSpace($MsysRoot))
  {
    $StartArgs += "-MsysRoot"
    $StartArgs += $MsysRoot
  }

  if (-not [string]::IsNullOrWhiteSpace($PythonVersion))
  {
    $StartArgs += "-PythonVersion"
    $StartArgs += $PythonVersion
  }

  if (-not [string]::IsNullOrWhiteSpace($Msys2CaCertificatePath))
  {
    $StartArgs += "-Msys2CaCertificatePath"
    $StartArgs += $Msys2CaCertificatePath
  }

  Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $StartArgs -Verb RunAs -Wait
  exit
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Prevent multiple instances from running concurrently
$MutexName = "Global\ContestSetupEnvironmentMutex"
$Global:SetupMutex = New-Object System.Threading.Mutex($false, $MutexName)
try {
    if (-not $Global:SetupMutex.WaitOne(0, $false)) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host " ERROR: Another installation process is already running." -ForegroundColor Red
        Write-Host " Please wait for it to finish or close the other window." -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "This window will close automatically in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        exit
    }
} catch {
    # In case of AbandonedMutexException from a previously crashed run, we acquire it automatically.
}

Write-Host "Contest Environment Setup (Modular)" -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host ""

# If CPTools folder already exists, remove it before starting fresh installation
if (Test-Path $Root)
{
  Write-Host "Existing CPTools folder found at $Root. Removing for clean installation..." -ForegroundColor Yellow
  Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "CPTools folder removed." -ForegroundColor Green
}

# Module display names for the outer progress bar
$ModuleDisplayNames = @{
  'common.ps1'            = 'Core Configuration'
  'setup-msys2.ps1'       = 'MSYS2 (GCC/GDB)'
  'setup-python.ps1'      = 'Python 3.10'
  'setup-visualstudio.ps1'= 'Visual Studio'
  'setup-vscode.ps1'      = 'VS Code'
  'setup-wrappers.ps1'    = 'Command Wrappers & Tests'
  'setup-ai-hosts.ps1'    = 'AI Hosts Block'
  'setup-restore-task.ps1'= 'Restore Task Scheduler'
}

$Modules = @(
  "common.ps1",
  "setup-msys2.ps1",
  "setup-python.ps1",
  "setup-visualstudio.ps1",
  "setup-vscode.ps1",
  "setup-wrappers.ps1",
  "setup-ai-hosts.ps1",
  "setup-restore-task.ps1"
)

# Global progress IDs for two-tier progress bars
$Global:ProgressIdOuter = 0
$Global:ProgressIdInner = 1

$Total = $Modules.Count
$Step = 1

try
{
  foreach ($Module in $Modules)
  {
    $Global:SetupStepCurrent = $Step
    $Global:SetupStepTotal = $Total
    $Global:SetupModuleName = $Module

    $DisplayName = if ($ModuleDisplayNames.ContainsKey($Module)) { $ModuleDisplayNames[$Module] } else { $Module }
    $OuterPercent = [math]::Floor((($Step - 1) / $Total) * 100)
    Write-Progress -Id $Global:ProgressIdOuter -Activity "Contest Environment Setup" -Status "[$Step/$Total] $DisplayName" -PercentComplete $OuterPercent

    Write-Host "[$Step/$Total] Running $Module ($DisplayName)..." -ForegroundColor Yellow
    $CacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $ModuleUri = "{0}/{1}?cb={2}" -f $RawBase.TrimEnd('/'), $Module, $CacheBust

    $OldProgressPref = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-RestMethod -Uri $ModuleUri `
          -Headers @{ "Cache-Control" = "no-cache"; "Pragma" = "no-cache" } `
          -ErrorAction Stop |
          Invoke-Expression
    } finally {
        $ProgressPreference = $OldProgressPref
    }
    if ($Module -eq "common.ps1")
    {
      Start-SetupLogging
      Backup-PathEnvironment -BackupRoot (Join-Path $BackupDir ("path-$TimeStamp"))
      Remove-ConflictingPathEntries
    }

    # Clear inner progress bar after each module completes
    Write-Progress -Id $Global:ProgressIdInner -Activity "Module Detail" -Completed
    $Step++
  }
  Write-Progress -Id $Global:ProgressIdOuter -Activity "Contest Environment Setup" -Status "Complete!" -PercentComplete 100
  Start-Sleep -Milliseconds 500
  Write-Progress -Id $Global:ProgressIdOuter -Activity "Contest Environment Setup" -Completed

  Write-Host ""
  Write-Host "All setup and tests completed successfully." -ForegroundColor Green
  Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
}
catch
{
  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Red
  Write-Host " FATAL ERROR during $Module" -ForegroundColor Red
  Write-Host " $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "============================================================" -ForegroundColor Red
  
  if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) { Write-ErrorLog -ErrorRecord $_ }

  Write-Host ""
  Write-Host "Initiating automatic rollback to restore original system state..." -ForegroundColor Yellow
  try {
      $OldProgressPref = $ProgressPreference
      try {
          $ProgressPreference = 'SilentlyContinue'
          $RestoreScript = Invoke-RestMethod -Uri "$RawBase/restore.ps1" -UseBasicParsing
      } finally {
          $ProgressPreference = $OldProgressPref
      }
      & ([scriptblock]::Create($RestoreScript)) -NoPause
      Write-Host "Automatic rollback completed successfully." -ForegroundColor Green
  } catch {
      Write-Warning "Automatic rollback failed: $($_.Exception.Message)"
      Write-Host "You may need to manually run the restore script or delete C:\CPTools." -ForegroundColor Red
  }
}
finally
{
  if (Get-Command Stop-SetupLogging -ErrorAction SilentlyContinue)
  {
    try { Stop-SetupLogging } catch {}
  }

  if ($Global:SetupMutex)
  {
    try { $Global:SetupMutex.ReleaseMutex() } catch {}
  }

  Write-Host ""
  Write-Host "This window will close automatically in 5 seconds..." -ForegroundColor Yellow
  Start-Sleep -Seconds 5
}
