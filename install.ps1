# install.ps1
# Bootstrap installer for contest environment.
# Usage:
#   irm https://raw.githubusercontent.com/<USER>/<REPO>/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

# ==============================
# Edit here
# ==============================

$RepoOwner = "<USER>"
$RepoName  = "<REPO>"
$Branch    = "main"

$MainScriptName = "setup-contest-env.ps1"

# ==============================
# Internal settings
# ==============================

$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$MainScriptUrl = "$RawBase/$MainScriptName"

$BootstrapDir = Join-Path $env:TEMP "contest-env-installer"
$MainScriptPath = Join-Path $BootstrapDir $MainScriptName

function Test-IsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell {
    $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Pwsh) {
        return $Pwsh.Source
    }

    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
}

Write-Host ""
Write-Host "Contest Environment Installer" -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host "Script     : $MainScriptName"
Write-Host ""

New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null

Write-Host "Downloading setup script..."
Write-Host $MainScriptUrl

Invoke-WebRequest `
    -Uri $MainScriptUrl `
    -OutFile $MainScriptPath `
    -UseBasicParsing

if (-not (Test-Path $MainScriptPath)) {
    throw "Download failed: $MainScriptPath"
}

Write-Host "Downloaded: $MainScriptPath" -ForegroundColor Green

$PowerShellExe = Get-PreferredPowerShell

if (Test-IsAdmin) {
    Write-Host "Running setup script as administrator..." -ForegroundColor Green

    & $PowerShellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $MainScriptPath
}
else {
    Write-Host "Requesting administrator permission..." -ForegroundColor Yellow

    Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$MainScriptPath`""
        ) `
        -Verb RunAs `
        -Wait
}

Write-Host ""
Write-Host "Installer finished." -ForegroundColor Green
