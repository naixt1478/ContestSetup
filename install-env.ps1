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
  $StartArgs = @(
    "-NoExit"
    "-NoProfile"
    "-ExecutionPolicy", "Bypass"
    "-File", $MyInvocation.MyCommand.Path
  )
  if ($KeepVSCode)
  {
    $StartArgs += "-KeepVSCode"
  }
  if ($NoPause)
  {
    $StartArgs += "-NoPause"
  }
  if ($SkipSignatureCheck)
  {
    $StartArgs += "-SkipSignatureCheck"
  }
  if ($Root)
  {
    $StartArgs += "-Root"
    $StartArgs += $Root
  }
  if ($MsysRoot)
  {
    $StartArgs += "-MsysRoot"
    $StartArgs += $MsysRoot
  }
  if ($PythonVersion)
  {
    $StartArgs += "-PythonVersion"
    $StartArgs += $PythonVersion
  }
  if ($Msys2CaCertificatePath)
  {
    $StartArgs += "-Msys2CaCertificatePath"
    $StartArgs += $Msys2CaCertificatePath
  }
  Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $StartArgs -Verb RunAs -Wait
  exit
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host "Contest Environment Setup (Modular)" -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host ""

$Modules = @(
  "common.ps1",
  "setup-vscode.ps1",
  "setup-visualstudio.ps1",
  "setup-msys2.ps1",
  "setup-python.ps1",
  "setup-wrappers.ps1"
)

$Total = $Modules.Count
$Step = 1

try
{
  foreach ($Module in $Modules)
  {
    Write-Host "[$Step/$Total] Running $Module..." -ForegroundColor Yellow
    Invoke-RestMethod "$RawBase/$Module" | Invoke-Expression

    if ($Module -eq "common.ps1")
    {
      Start-SetupLogging
      Backup-PathEnvironment -BackupRoot (Join-Path $BackupDir ("path-$TimeStamp"))
      Remove-ConflictingPathEntries
    }

    $Step++
  }

  Write-Host ""
  Write-Host "All setup and tests completed successfully." -ForegroundColor Green
  Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
}
catch
{
  Write-Host ""
  Write-Host "FATAL ERROR during $Module" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) { Write-ErrorLog -ErrorRecord $_ }
}
finally
{
  Stop-SetupLogging
  if (-not $NoPause)
  {
    Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch {}
  }
}
