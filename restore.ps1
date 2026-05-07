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

function Invoke-RestoreModuleFromRaw {
    param(
        [Parameter(Mandatory = $true)] [string]$ModuleName,
        [Parameter(Mandatory = $true)] [bool]$Critical
    )

    Write-Host "Running $ModuleName..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod "$RawBase/$ModuleName" | Invoke-Expression
        return $true
    }
    catch {
        if ($Critical) { throw }
        Write-Warning "Module failed but restore will continue: $ModuleName"
        Write-Warning $_.Exception.Message
        return $false
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

$CriticalModules = @("common.ps1", "restore-common.ps1")
$RestoreModules = @()
if (-not $SkipHosts) { $RestoreModules += "restore-hosts.ps1" }
if (-not $SkipVSCode) { $RestoreModules += "restore-vscode.ps1" }
if (-not $SkipMSYS2) { $RestoreModules += "restore-msys2.ps1" }
if (-not $SkipPython) { $RestoreModules += "restore-python.ps1" }
if (-not $SkipPath) { $RestoreModules += "restore-path.ps1" }

$Total = $CriticalModules.Count + $RestoreModules.Count
$Step = 1
$FailedModules = New-Object System.Collections.Generic.List[string]

try {
    foreach ($Module in $CriticalModules) {
        Write-Host "[$Step/$Total]" -NoNewline
        Invoke-RestoreModuleFromRaw -ModuleName $Module -Critical $true | Out-Null
        $Step++
    }

    foreach ($Module in $RestoreModules) {
        Write-Host "[$Step/$Total]" -NoNewline
        $Ok = Invoke-RestoreModuleFromRaw -ModuleName $Module -Critical $false
        if (-not $Ok) { $FailedModules.Add($Module) | Out-Null }
        $Step++
    }

    Write-Host ""
    if ($FailedModules.Count -eq 0) {
        Write-Host "All restores completed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Restore completed with partial failures." -ForegroundColor Yellow
        Write-Host "Failed modules: $($FailedModules -join ', ')" -ForegroundColor Yellow
        Write-Host "The modules after the failed one were still attempted." -ForegroundColor Yellow
    }
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
