# install2.ps1
# Bootstrap installer for the optional AI hosts block helper.
#
# Default:
#   Downloads ai-hosts-block.ps1, applies the built-in AI hosts blocklist,
#   and schedules automatic restore after 5 hours.
#
# Usage:
#   irm https://raw.githubusercontent.com/<USER>/<REPO>/main/install2.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File .\install2.ps1 -DurationHours 3
#   powershell -ExecutionPolicy Bypass -File .\install2.ps1 -Until "2026-05-04 18:00"
#   powershell -ExecutionPolicy Bypass -File .\install2.ps1 -Restore

[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')] [switch]$Apply,
    [Parameter(ParameterSetName = 'Restore')] [switch]$Restore,
    [Parameter(ParameterSetName = 'Apply')] [int]$DurationHours = 5,
    [Parameter(ParameterSetName = 'Apply')] [string]$Until = '',
    [Parameter(ParameterSetName = 'Apply')] [switch]$NoSchedule,
    [string]$Root = "$env:SystemDrive\CPTools"
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'naixt1478'
$RepoName  = 'ContestSetup'
$Branch    = 'main'
$AiScriptName = 'ai-hosts-block.ps1'

$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$AiScriptUrl = "$RawBase/$AiScriptName"
$BootstrapDir = Join-Path $env:TEMP 'contest-env-installer'
$AiScriptPath = Join-Path $BootstrapDir $AiScriptName

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

function Quote-ProcessArgument {
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '""' }
    $Text = [string]$Value
    if ($Text -notmatch '[\s"]') { return $Text }
    $Escaped = $Text -replace '(\\*)"', '$1$1\"'
    $Escaped = $Escaped -replace '(\\+)$', '$1$1'
    return '"' + $Escaped + '"'
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host ''
Write-Host 'Contest AI Hosts Block Installer' -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host "Script     : $AiScriptName"
Write-Host ''

New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null

Write-Host 'Downloading AI hosts script...'
Write-Host $AiScriptUrl
Invoke-WebRequest -Uri $AiScriptUrl -OutFile $AiScriptPath -UseBasicParsing
if (-not (Test-Path $AiScriptPath)) { throw "Download failed: $AiScriptPath" }
Write-Host "Downloaded: $AiScriptPath" -ForegroundColor Green

$PowerShellExe = Get-PreferredPowerShell
$ForwardArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AiScriptPath)
if ($Restore) {
    $ForwardArgs += '-Restore'
} else {
    $ForwardArgs += '-Apply'
    $ForwardArgs += '-DurationHours'
    $ForwardArgs += [string]$DurationHours
    if (-not [string]::IsNullOrWhiteSpace($Until)) {
        $ForwardArgs += '-Until'
        $ForwardArgs += $Until
    }
    if ($NoSchedule) { $ForwardArgs += '-NoSchedule' }
}
$ForwardArgs += '-Root'
$ForwardArgs += $Root

if (Test-IsAdmin) {
    Write-Host 'Running AI hosts script as administrator...' -ForegroundColor Green
    & $PowerShellExe @ForwardArgs
} else {
    Write-Host 'Requesting administrator permission...' -ForegroundColor Yellow
    $ArgumentString = ($ForwardArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    Start-Process -FilePath $PowerShellExe -ArgumentList $ArgumentString -Verb RunAs -Wait
}

Write-Host ''
Write-Host 'AI hosts installer finished.' -ForegroundColor Green
