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

# restore-common.ps1에서 StrictMode 상태로 미초기화 변수를 읽지 않도록 미리 선언합니다.
$script:RestoreBackupRoot = $null

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

function Get-ScriptDirectory {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return (Get-Location).Path
}

$ScriptDir = Get-ScriptDirectory

if (-not (Test-IsAdmin)) {
    if (-not $MyInvocation.MyCommand.Path) {
        throw '관리자 권한 재실행을 하려면 restore.ps1 파일로 저장한 뒤 -File 방식으로 실행해야 합니다.'
    }

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

Write-Host "Contest Environment Restore (Modular / Local)" -ForegroundColor Cyan
Write-Host "ScriptDir : $ScriptDir"
Write-Host "Root      : $Root"
Write-Host "MsysRoot  : $MsysRoot"
Write-Host ""

$Modules = @("common.ps1", "restore-common.ps1")
if (-not $SkipHosts) { $Modules += "restore-hosts.ps1" }
if (-not $SkipVSCode) { $Modules += "restore-vscode.ps1" }
if (-not $SkipMSYS2) { $Modules += "restore-msys2.ps1" }
if (-not $SkipPython) { $Modules += "restore-python.ps1" }
if (-not $SkipPath) { $Modules += "restore-path.ps1" }

$Total = $Modules.Count
$Step = 1
$Module = $null

try {
    foreach ($Module in $Modules) {
        $ModulePath = Join-Path $ScriptDir $Module
        if (-not (Test-Path -LiteralPath $ModulePath)) {
            throw "필수 복구 모듈을 찾지 못했습니다: $ModulePath"
        }

        Write-Host "[$Step/$Total] Running $Module..." -ForegroundColor Yellow
        # 중요: Invoke-Expression을 함수 내부에서 실행하지 않고 dot-source로 현재 스크립트 scope에 로드합니다.
        . $ModulePath
        $Step++
    }

    Write-Host ""
    Write-Host "All restores completed successfully." -ForegroundColor Green
    Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "FATAL ERROR during $Module" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
finally {
    if (-not $NoPause) {
        Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}
