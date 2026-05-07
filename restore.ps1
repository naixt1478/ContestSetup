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

$RepoOwner = "naixt1478"
$RepoName  = "ContestSetup"
$Branch    = "main"
$RawBase   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

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

if (-not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        Write-Host "웹에서 직접 실행(iex)할 경우 파워셸을 관리자 권한으로 열고 시도해주세요." -ForegroundColor Red
        exit
    }

    # 2. 경로가 있다면 관리자 권한으로 재실행 시도
    Write-Host "관리자 권한을 요청합니다..." -ForegroundColor Yellow
    $Args = @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
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
        Invoke-RestMethod "$RawBase/$Module" | Invoke-Expression
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
