# restore.ps1
# Modular Contest Environment Restore

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = "$env:SystemDrive\CPTools",
    [string]$MsysRoot = "$env:SystemDrive\msys64",
    [string]$PythonVersion = '3.10.11',
    [switch]$SkipVSCode,
    [switch]$SkipMSYS2,
    [switch]$SkipPython,
    [switch]$SkipPath,
    [switch]$SkipHosts,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# Predeclare restore backup root so restore-common.ps1 does not fail under StrictMode.
$script:RestoreBackupRoot = $null

$RepoOwner = "naixt1478"
$RepoName  = "ContestSetup"
$Branch    = "main"
$RawBase   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }

function Test-IsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell {
    $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Pwsh) { return $Pwsh.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Invoke-RestoreModule {
    param([Parameter(Mandatory = $true)] [string]$Module)

    $LocalModulePath = $null
    if (-not [string]::IsNullOrWhiteSpace($ScriptDir)) {
        $Candidate = Join-Path $ScriptDir $Module
        if (Test-Path -LiteralPath $Candidate) {
            $LocalModulePath = $Candidate
        }
    }

    if ($LocalModulePath) {
        Write-Host "Loading local module: $LocalModulePath" -ForegroundColor DarkGray
        Get-Content -LiteralPath $LocalModulePath -Raw | Invoke-Expression
    }
    else {
        Write-Host "Loading remote module: $RawBase/$Module" -ForegroundColor DarkGray
        Invoke-RestMethod "$RawBase/$Module" | Invoke-Expression
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host "Requesting administrator permission..." -ForegroundColor Yellow
    $Args = @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path)
    if ($SkipVSCode) { $Args += "-SkipVSCode" }
    if ($SkipMSYS2) { $Args += "-SkipMSYS2" }
    if ($SkipPython) { $Args += "-SkipPython" }
    if ($SkipPath) { $Args += "-SkipPath" }
    if ($SkipHosts) { $Args += "-SkipHosts" }
    if ($NoPause) { $Args += "-NoPause" }
    if ($WhatIfPreference) { $Args += "-WhatIf" }
    if ($Root) { $Args += "-Root"; $Args += $Root }
    if ($MsysRoot) { $Args += "-MsysRoot"; $Args += $MsysRoot }
    if ($PythonVersion) { $Args += "-PythonVersion"; $Args += $PythonVersion }
    Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $Args -Verb RunAs -Wait
    exit
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host "Contest Environment Restore (Modular)" -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host ""

$Modules = @("common.ps1", "restore-common.ps1")
if (-not $SkipHosts) { $Modules += "restore-hosts.ps1" }
if (-not $SkipVSCode) { $Modules += "restore-vscode.ps1" }
if (-not $SkipMSYS2) { $Modules += "restore-msys2.ps1" }
if (-not $SkipPython) { $Modules += "restore-python.ps1" }
if (-not $SkipPath) { $Modules += "restore-path.ps1" }

$Total = $Modules.Count
$Step = 1

try {
    foreach ($Module in $Modules) {
        Write-Host "[$Step/$Total] Running $Module..." -ForegroundColor Yellow
        Invoke-RestoreModule -Module $Module
        $Step++
    }

    Write-Host ""
    Write-Host "All restores completed successfully." -ForegroundColor Green
    Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
} catch {
    Write-Host ""
    Write-Host "FATAL ERROR during $Module" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    if (-not $NoPause) {
        Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}
