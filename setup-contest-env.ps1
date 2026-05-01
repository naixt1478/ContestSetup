# setup-contest-env.ps1
# Windows Contest Environment Setup
#
# Installs and configures:
# - Visual Studio Code
# - Reset existing VS Code settings/extensions before reinstall
# - VS Code extensions:
#     formulahendry.code-runner
#     ms-vscode.cpptools
#     ms-python.python
#     ms-python.debugpy
# - MSYS2
# - Latest MSYS2 UCRT64 GCC/G++ supporting C++14, C++17, C++20
# - GDB, Make, CMake, Ninja
# - Python 3.10.12
# - cat
# - Code Runner settings
# - VS Code debug settings for C/C++ and Python
# - AI hosts blocklist
#
# Java is intentionally excluded.
#
# Commands after setup:
# - g++14
# - g++17
# - g++20
# - gcc
# - g++
# - python3
# - cat
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-contest-env.ps1
#
# Options:
#   -SkipAiBlock
#   -RestoreHosts
#   -KeepVSCode

param(
    [switch]$SkipAiBlock,
    [switch]$RestoreHosts,
    [switch]$KeepVSCode,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

try {
    $global:PSNativeCommandUseErrorActionPreference = $false
}
catch {
}

# ============================================================
# Paths
# ============================================================

$Root        = "C:\CPTools"
$ToolBin     = "$Root\bin"
$DownloadDir = "$Root\downloads"
$TestDir     = "$Root\tests"

$MsysRoot = "C:\msys64"
$MsysBash = "$MsysRoot\usr\bin\bash.exe"
$MsysCat  = "$MsysRoot\usr\bin\cat.exe"
$UcrtBin  = "$MsysRoot\ucrt64\bin"

$PythonDir       = "$Root\Python310"
$PythonExe       = "$PythonDir\python.exe"
$PythonUrl       = "https://www.python.org/ftp/python/3.10.12/python-3.10.12-amd64.exe"
$PythonInstaller = "$DownloadDir\python-3.10.12-amd64.exe"

$HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$BackupPath = "$env:SystemRoot\System32\drivers\etc\hosts.bak"
$BlockDir   = "$Root\ai-block"

$RawListPath    = "$BlockDir\noai_hosts.txt"
$ParsedListPath = "$BlockDir\parsed-ai-hosts.txt"
$NoAiHostsUrl   = "https://raw.githubusercontent.com/laylavish/uBlockOrigin-HUGE-AI-Blocklist/main/noai_hosts.txt"

$BeginMarker = "# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN"
$EndMarker   = "# <<< CP_CONTEST_AI_BLOCKLIST_END"

$AllowList = @(
    "localhost",
    "localhost.localdomain",
    "github.com",
    "raw.githubusercontent.com",
    "objects.githubusercontent.com",
    "githubusercontent.com",
    "code.visualstudio.com",
    "marketplace.visualstudio.com",
    "msys2.org",
    "packages.msys2.org",
    "repo.msys2.org",
    "mirror.msys2.org",
    "python.org",
    "www.python.org",
    "winget.azureedge.net",
    "cdn.winget.microsoft.com"
)

# ============================================================
# Helper functions
# ============================================================

function Write-Section {
    param([string]$Message)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Command)

    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

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

function Assert-Admin {
    if (Test-IsAdmin) {
        return
    }

    $ScriptPath = $null

    if ($PSCommandPath) {
        $ScriptPath = $PSCommandPath
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $ScriptPath = $MyInvocation.MyCommand.Path
    }

    if (-not $ScriptPath) {
        throw "Administrator permission is required. Please run this script from a saved .ps1 file."
    }

    $PowerShellExe = Get-PreferredPowerShell

    $Args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$ScriptPath`""
    )

    if ($SkipAiBlock) {
        $Args += "-SkipAiBlock"
    }

    if ($RestoreHosts) {
        $Args += "-RestoreHosts"
    }

    if ($KeepVSCode) {
        $Args += "-KeepVSCode"
    }

    Write-Host "Requesting administrator permission..." -ForegroundColor Yellow

    Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $Args `
        -Verb RunAs `
        -Wait

    exit
}

function Write-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-TextUtf8NoBom -Path $Path -Content $Content
}

function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$OutFile
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $OutFile `
        -UseBasicParsing
}

function Add-UserPathFront {
    param([string]$PathToAdd)

    if (-not (Test-Path $PathToAdd)) {
        Write-Warning "PATH target not found: $PathToAdd"
        return
    }

    $Current = [Environment]::GetEnvironmentVariable("Path", "User")

    $Parts = @()
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $Parts = $Current.Split(";") | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_.TrimEnd("\") -ne $PathToAdd.TrimEnd("\")
        }
    }

    $NewPath = ($PathToAdd + ";" + ($Parts -join ";")).TrimEnd(";")
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")

    $EnvParts = $env:Path.Split(";") | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_.TrimEnd("\") -ne $PathToAdd.TrimEnd("\")
    }

    $env:Path = ($PathToAdd + ";" + ($EnvParts -join ";")).TrimEnd(";")

    Write-Host "PATH added: $PathToAdd" -ForegroundColor Green
}

function Test-WingetHelpSupports {
    param(
        [string]$Command,
        [string]$Option
    )

    try {
        $HelpText = (& winget $Command --help 2>$null) -join "`n"
        return $HelpText -match [regex]::Escape($Option)
    }
    catch {
        return $false
    }
}

function Invoke-Winget {
    param([string[]]$Arguments)

    & winget @Arguments
    return $LASTEXITCODE
}

function Update-WingetClient {
    Write-Section "Update winget / App Installer"

    if (-not (Test-CommandExists "winget")) {
        throw "winget not found. Install or update App Installer from Microsoft Store, then run again."
    }

    Write-Host "Current winget version:"
    winget --version

    $AppInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue

    if ($AppInstaller) {
        Write-Host "Current App Installer version: $($AppInstaller.Version)"
    }
    else {
        Write-Warning "Microsoft.DesktopAppInstaller package was not found by Get-AppxPackage."
    }

    Write-Host "Trying to update App Installer / winget..."

    $Args = @(
        "upgrade",
        "Microsoft.AppInstaller",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    if (Test-WingetHelpSupports -Command "upgrade" -Option "--disable-interactivity") {
        $Args += "--disable-interactivity"
    }

    try {
        $Exit = Invoke-Winget -Arguments $Args

        if ($Exit -eq 0) {
            Write-Host "winget update completed or already up to date." -ForegroundColor Green
        }
        else {
            Write-Warning "winget update returned exit code $Exit. Continuing with compatibility mode."
        }
    }
    catch {
        Write-Warning "winget update failed. Continuing with compatibility mode."
        Write-Warning $_.Exception.Message
    }

    Write-Host "winget version after update attempt:"
    winget --version
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$NameForLog
    )

    Write-Host "Installing or checking: $NameForLog"

    $Args = @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", "winget",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    if (Test-WingetHelpSupports -Command "install" -Option "--disable-interactivity") {
        $Args += "--disable-interactivity"
    }

    $Exit = Invoke-Winget -Arguments $Args

    if ($Exit -ne 0) {
        Write-Warning "winget returned exit code $Exit for $NameForLog."

        $ListOutput = (& winget list --id $Id --exact 2>$null) -join "`n"

        if ($ListOutput -match [regex]::Escape($Id)) {
            Write-Host "$NameForLog is already installed. Continuing." -ForegroundColor Green
            return
        }

        throw "Failed to install $NameForLog by winget. Package id: $Id"
    }

    Write-Host "$NameForLog install/check completed." -ForegroundColor Green
}

function Uninstall-WingetPackageIfExists {
    param(
        [string]$Id,
        [string]$NameForLog
    )

    Write-Host "Checking installed package: $NameForLog"

    $ListOutput = (& winget list --id $Id --exact 2>$null) -join "`n"

    if ($ListOutput -notmatch [regex]::Escape($Id)) {
        Write-Host "$NameForLog is not installed by winget or not detected. Continuing."
        return
    }

    Write-Host "Uninstalling: $NameForLog"

    $Args = @(
        "uninstall",
        "--id", $Id,
        "--exact",
        "--silent"
    )

    if (Test-WingetHelpSupports -Command "uninstall" -Option "--source") {
        $Args += "--source"
        $Args += "winget"
    }

    if (Test-WingetHelpSupports -Command "uninstall" -Option "--accept-source-agreements") {
        $Args += "--accept-source-agreements"
    }

    if (Test-WingetHelpSupports -Command "uninstall" -Option "--disable-interactivity") {
        $Args += "--disable-interactivity"
    }

    $Exit = Invoke-Winget -Arguments $Args

    if ($Exit -ne 0) {
        Write-Warning "winget uninstall returned exit code $Exit for $NameForLog. Continuing with folder cleanup."
    }
    else {
        Write-Host "$NameForLog uninstalled." -ForegroundColor Green
    }
}

function Get-VSCodeCommandPath {
    $Candidates = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd"
    )

    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }

    $Cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($Cmd) {
        return $Cmd.Source
    }

    $Cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($Cmd) {
        return $Cmd.Source
    }

    return $null
}

function Stop-VSCodeProcesses {
    Write-Host "Closing VS Code processes if running..."

    $Names = @(
        "Code",
        "Code - Insiders",
        "VSCodium"
    )

    foreach ($Name in $Names) {
        Get-Process -Name $Name -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}

function Backup-And-RemovePath {
    param(
        [string]$Path,
        [string]$BackupRoot
    )

    if (-not (Test-Path $Path)) {
        return
    }

    $Leaf = Split-Path $Path -Leaf
    $SafeLeaf = $Leaf -replace '[\\/:*?"<>|]', '_'
    $BackupTarget = Join-Path $BackupRoot $SafeLeaf

    Write-Host "Backing up: $Path"
    Copy-Item -Path $Path -Destination $BackupTarget -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Removing: $Path"
    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Reset-VSCodeCompletely {
    Write-Section "Reset existing VS Code"

    Stop-VSCodeProcesses

    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $VSCodeBackupRoot = Join-Path $Root "backup\vscode-$Timestamp"

    New-Item -ItemType Directory -Force -Path $VSCodeBackupRoot | Out-Null

    Write-Host "VS Code backup directory:"
    Write-Host "  $VSCodeBackupRoot"

    $CodeCmdBeforeReset = Get-VSCodeCommandPath

    if ($CodeCmdBeforeReset) {
        try {
            & $CodeCmdBeforeReset --list-extensions |
                Set-Content -Encoding UTF8 "$VSCodeBackupRoot\extensions-before-reset.txt"

            Write-Host "Extension list backed up." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to backup extension list. Continuing."
        }
    }

    $PathsToBackupAndRemove = @(
        "$env:APPDATA\Code",
        "$env:LOCALAPPDATA\Code",
        "$env:USERPROFILE\.vscode"
    )

    foreach ($Path in $PathsToBackupAndRemove) {
        Backup-And-RemovePath -Path $Path -BackupRoot $VSCodeBackupRoot
    }

    Uninstall-WingetPackageIfExists -Id "Microsoft.VisualStudioCode" -NameForLog "Visual Studio Code"

    $InstallFolders = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code",
        "$env:ProgramFiles\Microsoft VS Code",
        "${env:ProgramFiles(x86)}\Microsoft VS Code"
    )

    foreach ($Folder in $InstallFolders) {
        if (Test-Path $Folder) {
            Write-Host "Removing remaining VS Code install folder: $Folder"
            Remove-Item -Path $Folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "VS Code reset completed." -ForegroundColor Green
}

function Install-VSCodeExtensions {
    Write-Section "Install VS Code extensions"

    $CodeCmd = $null
    $WaitCount = 0

    while (-not $CodeCmd -and $WaitCount -lt 60) {
        $CodeCmd = Get-VSCodeCommandPath
        if (-not $CodeCmd) {
            Start-Sleep -Seconds 2
            $WaitCount++
        }
    }

    if (-not $CodeCmd) {
        throw "code.cmd not found after VS Code installation."
    }

    $Extensions = @(
        "formulahendry.code-runner",
        "ms-vscode.cpptools",
        "ms-python.python",
        "ms-python.debugpy"
    )

    foreach ($Extension in $Extensions) {
        Write-Host "Installing VS Code extension: $Extension"
        & $CodeCmd --install-extension $Extension --force

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install VS Code extension: $Extension"
        }
    }

    $InstalledExtensions = (& $CodeCmd --list-extensions) -join "`n"

    foreach ($Extension in $Extensions) {
        if ($InstalledExtensions -notmatch [regex]::Escape($Extension)) {
            throw "Extension verification failed: $Extension"
        }
    }

    Write-Host "VS Code extensions installed and verified." -ForegroundColor Green
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Invoke-MsysBash {
    param([string]$Command)

    & $MsysBash -lc $Command
}

function Assert-Output {
    param(
        [string]$Name,
        [string]$Actual,
        [string]$Expected
    )

    $A = $Actual.Trim()
    $E = $Expected.Trim()

    if ($A -ne $E) {
        throw "$Name test failed. Expected: [$E], Actual: [$A]"
    }

    Write-Host "$Name test passed: $A" -ForegroundColor Green
}

function Restore-HostsBackup {
    Write-Section "Restore hosts file"

    if (-not (Test-Path $BackupPath)) {
        throw "hosts.bak not found: $BackupPath"
    }

    Copy-Item -Path $BackupPath -Destination $HostsPath -Force
    ipconfig /flushdns | Out-Null

    Write-Host "hosts restored from: $BackupPath" -ForegroundColor Green
}

function Apply-AiHostsBlock {
    Write-Section "AI hosts block"

    New-Item -ItemType Directory -Force -Path $BlockDir | Out-Null

    if (-not (Test-Path $HostsPath)) {
        throw "hosts file not found: $HostsPath"
    }

    if (-not (Test-Path $BackupPath)) {
        Copy-Item -Path $HostsPath -Destination $BackupPath -Force
        Write-Host "Backup created: $BackupPath" -ForegroundColor Green
    }
    else {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ExtraBackup = "$env:SystemRoot\System32\drivers\etc\hosts.bak.$Timestamp"
        Copy-Item -Path $HostsPath -Destination $ExtraBackup -Force
        Write-Host "Extra backup created: $ExtraBackup" -ForegroundColor Yellow
    }

    Write-Host "Downloading AI blocklist..."
    Invoke-DownloadFile -Url $NoAiHostsUrl -OutFile $RawListPath

    $RawContent = Get-Content -Path $RawListPath -Raw
    $DomainList = New-Object System.Collections.Generic.List[string]

    foreach ($Line in ($RawContent -split "`r`n|`n|`r")) {
        $Clean = ($Line -replace "#.*$", "").Trim()

        if (-not $Clean) {
            continue
        }

        $Parts = $Clean -split "\s+"

        if ($Parts.Count -lt 2) {
            continue
        }

        $First = $Parts[0].ToLowerInvariant()

        if ($First -in @("0.0.0.0", "127.0.0.1", "::1")) {
            for ($i = 1; $i -lt $Parts.Count; $i++) {
                $Domain = $Parts[$i].Trim().ToLowerInvariant()

                if ($Domain -and
                    $Domain -notin $AllowList -and
                    $Domain -notmatch "[/*\\]" -and
                    $Domain -match "^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$") {
                    $DomainList.Add($Domain)
                }
            }
        }
    }

    $Domains = @($DomainList | Sort-Object -Unique)

    if ($Domains.Count -eq 0) {
        throw "No domains were parsed from the AI blocklist."
    }

    $Domains | Set-Content -Encoding UTF8 $ParsedListPath

    Write-Host "Parsed domains: $($Domains.Count)" -ForegroundColor Green
    Write-Host "Parsed list: $ParsedListPath"

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker) + "\r?\n?"
    $BaseHosts = [regex]::Replace($CurrentHosts, $Pattern, "`r`n").TrimEnd()

    $BlockLines = New-Object System.Collections.Generic.List[string]
    $BlockLines.Add("")
    $BlockLines.Add($BeginMarker)
    $BlockLines.Add("# Generated by setup-contest-env.ps1")
    $BlockLines.Add("# Source: laylavish/uBlockOrigin-HUGE-AI-Blocklist noai_hosts.txt")
    $BlockLines.Add("# Backup: $BackupPath")
    $BlockLines.Add("")

    foreach ($Domain in $Domains) {
        $BlockLines.Add("0.0.0.0 $Domain")
        $BlockLines.Add("::1 $Domain")
    }

    $BlockLines.Add("")
    $BlockLines.Add($EndMarker)
    $BlockLines.Add("")

    $NewHosts = $BaseHosts + "`r`n" + ($BlockLines -join "`r`n") + "`r`n"

    Write-TextUtf8NoBom -Path $HostsPath -Content $NewHosts

    ipconfig /flushdns | Out-Null

    Write-Host "AI hosts block applied." -ForegroundColor Green
    Write-Host "Close and reopen browsers after this script finishes." -ForegroundColor Yellow
}

# ============================================================
# 0. Admin and restore mode
# ============================================================

Assert-Admin

if ($RestoreHosts) {
    Restore-HostsBackup
    exit
}

# ============================================================
# 1. Create folders
# ============================================================

Write-Section "1. Create folders"

New-Item -ItemType Directory -Force -Path $Root        | Out-Null
New-Item -ItemType Directory -Force -Path $ToolBin     | Out-Null
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $TestDir     | Out-Null

# ============================================================
# 2. Check and update winget
# ============================================================

Write-Section "2. Check winget"

if (-not (Test-CommandExists "winget")) {
    throw "winget not found. Install or update App Installer from Microsoft Store, then run again."
}

winget --version
Write-Host "winget found." -ForegroundColor Green

Update-WingetClient

# ============================================================
# 3. Reset and install VS Code / MSYS2
# ============================================================

Write-Section "3. Reset and install VS Code / MSYS2"

if ($KeepVSCode) {
    Write-Host "VS Code reset skipped by -KeepVSCode." -ForegroundColor Yellow
}
else {
    Reset-VSCodeCompletely
}

Install-WingetPackage -Id "Microsoft.VisualStudioCode" -NameForLog "Visual Studio Code"

Install-VSCodeExtensions

Install-WingetPackage -Id "MSYS2.MSYS2" -NameForLog "MSYS2"

$WaitCount = 0
while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) {
    Start-Sleep -Seconds 2
    $WaitCount++
}

if (-not (Test-Path $MsysBash)) {
    throw "MSYS2 bash.exe not found: $MsysBash"
}

Write-Host "MSYS2 found: $MsysBash" -ForegroundColor Green

# ============================================================
# 4. Install MSYS2 packages
# ============================================================

Write-Section "4. Install MSYS2 packages"

Invoke-MsysBash "echo MSYS2 initialized"

try {
    Invoke-MsysBash "pacman --noconfirm -Syuu"
}
catch {
    Write-Warning "First pacman update may require shell restart. Continuing."
}

try {
    Invoke-MsysBash "pacman --noconfirm -Syu"
}
catch {
    Write-Warning "Second pacman update returned a warning. Continuing."
}

$MsysPackages = @(
    "base-devel",
    "mingw-w64-ucrt-x86_64-gcc",
    "mingw-w64-ucrt-x86_64-gdb",
    "mingw-w64-ucrt-x86_64-make",
    "mingw-w64-ucrt-x86_64-cmake",
    "mingw-w64-ucrt-x86_64-ninja",
    "coreutils"
)

$PackageLine = $MsysPackages -join " "

Invoke-MsysBash "pacman --needed --noconfirm -S $PackageLine"

if (-not (Test-Path "$UcrtBin\g++.exe")) {
    throw "g++.exe not found: $UcrtBin\g++.exe"
}

if (-not (Test-Path "$UcrtBin\gcc.exe")) {
    throw "gcc.exe not found: $UcrtBin\gcc.exe"
}

if (-not (Test-Path "$UcrtBin\gdb.exe")) {
    throw "gdb.exe not found: $UcrtBin\gdb.exe"
}

if (-not (Test-Path $MsysCat)) {
    throw "cat.exe not found: $MsysCat"
}

Write-Host "MSYS2 UCRT64 GCC/GDB installed." -ForegroundColor Green

# ============================================================
# 5. Install Python 3.10.12
# ============================================================

Write-Section "5. Install Python 3.10.12"

if (-not (Test-Path $PythonExe)) {
    if (-not (Test-Path $PythonInstaller)) {
        Write-Host "Downloading Python 3.10.12..."
        Invoke-DownloadFile -Url $PythonUrl -OutFile $PythonInstaller
    }

    Write-Host "Installing Python 3.10.12..."

    Start-Process `
        -FilePath $PythonInstaller `
        -ArgumentList "/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 TargetDir=`"$PythonDir`"" `
        -Wait
}

if (-not (Test-Path $PythonExe)) {
    throw "Python install failed or python.exe not found: $PythonExe"
}

& $PythonExe --version
Write-Host "Python installed: $PythonExe" -ForegroundColor Green

# ============================================================
# 6. Create command wrappers
# ============================================================

Write-Section "6. Create command wrappers"

Write-LinesUtf8NoBom "$ToolBin\g++14.cmd" @(
    "@echo off",
    "`"$UcrtBin\g++.exe`" -std=gnu++14 %*"
)

Write-LinesUtf8NoBom "$ToolBin\g++17.cmd" @(
    "@echo off",
    "`"$UcrtBin\g++.exe`" -std=gnu++17 %*"
)

Write-LinesUtf8NoBom "$ToolBin\g++20.cmd" @(
    "@echo off",
    "`"$UcrtBin\g++.exe`" -std=gnu++20 %*"
)

Write-LinesUtf8NoBom "$ToolBin\g++.cmd" @(
    "@echo off",
    "`"$UcrtBin\g++.exe`" %*"
)

Write-LinesUtf8NoBom "$ToolBin\gcc.cmd" @(
    "@echo off",
    "`"$UcrtBin\gcc.exe`" %*"
)

Write-LinesUtf8NoBom "$ToolBin\python3.cmd" @(
    "@echo off",
    "`"$PythonExe`" %*"
)

Write-LinesUtf8NoBom "$ToolBin\cat.cmd" @(
    "@echo off",
    "`"$MsysCat`" %*"
)

Write-Host "Wrappers created:" -ForegroundColor Green
Write-Host "  g++14"
Write-Host "  g++17"
Write-Host "  g++20"
Write-Host "  g++"
Write-Host "  gcc"
Write-Host "  python3"
Write-Host "  cat"

# ============================================================
# 7. Configure PATH
# ============================================================

Write-Section "7. Configure PATH"

Add-UserPathFront $ToolBin
Add-UserPathFront $UcrtBin
Add-UserPathFront $PythonDir

$VSCodeBinCandidates = @(
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin",
    "$env:ProgramFiles\Microsoft VS Code\bin",
    "${env:ProgramFiles(x86)}\Microsoft VS Code\bin"
)

foreach ($Candidate in $VSCodeBinCandidates) {
    if (Test-Path $Candidate) {
        Add-UserPathFront $Candidate
        break
    }
}

# ============================================================
# 8. Configure VS Code global settings
# ============================================================

Write-Section "8. Configure VS Code"

$CodeCmd = Get-VSCodeCommandPath

if (-not $CodeCmd) {
    throw "code.cmd not found. VS Code installation may have failed."
}

$SettingsDir = "$env:APPDATA\Code\User"
$SettingsPath = "$SettingsDir\settings.json"

New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null

if (Test-Path $SettingsPath) {
    try {
        $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if (-not $Settings) {
            $Settings = [PSCustomObject]@{}
        }
    }
    catch {
        Copy-Item $SettingsPath "$SettingsPath.bak" -Force
        $Settings = [PSCustomObject]@{}
    }
}
else {
    $Settings = [PSCustomObject]@{}
}

$Profiles = [PSCustomObject]@{}

if ($Settings.PSObject.Properties.Name -contains "terminal.integrated.profiles.windows") {
    $Profiles = $Settings."terminal.integrated.profiles.windows"
}

$MsysProfile = [PSCustomObject]@{
    path = $MsysBash
    args = @("--login")
    env = [PSCustomObject]@{
        MSYSTEM = "UCRT64"
        CHERE_INVOKING = "1"
    }
}

Set-JsonProperty -Object $Profiles -Name "MSYS2 UCRT64" -Value $MsysProfile

$CodeRunnerExecutorMap = [PSCustomObject]@{
    cpp    = 'cd $dir && g++17 -g -O0 -Wall -Wextra $fileName -o $fileNameWithoutExt.exe && .\$fileNameWithoutExt.exe'
    c      = 'cd $dir && gcc -std=c11 -g -O0 -Wall -Wextra $fileName -o $fileNameWithoutExt.exe && .\$fileNameWithoutExt.exe'
    python = 'python3 -u $fullFileName'
}

Set-JsonProperty -Object $Settings -Name "terminal.integrated.profiles.windows"       -Value $Profiles
Set-JsonProperty -Object $Settings -Name "terminal.integrated.defaultProfile.windows" -Value "PowerShell"

Set-JsonProperty -Object $Settings -Name "C_Cpp.default.compilerPath"                -Value "$UcrtBin\g++.exe"
Set-JsonProperty -Object $Settings -Name "C_Cpp.default.cppStandard"                 -Value "c++17"
Set-JsonProperty -Object $Settings -Name "C_Cpp.default.cStandard"                   -Value "c11"
Set-JsonProperty -Object $Settings -Name "C_Cpp.default.intelliSenseMode"             -Value "windows-gcc-x64"

Set-JsonProperty -Object $Settings -Name "code-runner.executorMap"          -Value $CodeRunnerExecutorMap
Set-JsonProperty -Object $Settings -Name "code-runner.runInTerminal"        -Value $true
Set-JsonProperty -Object $Settings -Name "code-runner.fileDirectoryAsCwd"   -Value $true
Set-JsonProperty -Object $Settings -Name "code-runner.saveFileBeforeRun"    -Value $true
Set-JsonProperty -Object $Settings -Name "code-runner.clearPreviousOutput"  -Value $true
Set-JsonProperty -Object $Settings -Name "code-runner.showExecutionMessage" -Value $false
Set-JsonProperty -Object $Settings -Name "code-runner.preserveFocus"        -Value $false
Set-JsonProperty -Object $Settings -Name "code-runner.ignoreSelection"      -Value $true
Set-JsonProperty -Object $Settings -Name "code-runner.enableAppInsights"    -Value $false

Set-JsonProperty -Object $Settings -Name "python.defaultInterpreterPath"       -Value "$PythonExe"
Set-JsonProperty -Object $Settings -Name "python.terminal.activateEnvironment" -Value $false

$Settings | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $SettingsPath

Write-Host "VS Code settings configured." -ForegroundColor Green

# ============================================================
# 9. Create VS Code CP template
# ============================================================

Write-Section "9. Create VS Code CP template"

$TemplateRoot = "$env:USERPROFILE\Desktop\CP-Template"
$VSCodeDir = "$TemplateRoot\.vscode"

New-Item -ItemType Directory -Force -Path $VSCodeDir | Out-Null

Write-LinesUtf8NoBom "$TemplateRoot\main.cpp" @(
    "#include <bits/stdc++.h>",
    "using namespace std;",
    "",
    "int main() {",
    "    ios::sync_with_stdio(false);",
    "    cin.tie(nullptr);",
    "",
    "    cout << `"Hello, C++17 Contest Environment!\n`";",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TemplateRoot\main.c" @(
    "#include <stdio.h>",
    "",
    "int main(void) {",
    "    printf(`"Hello, C11!\n`");",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TemplateRoot\main.py" @(
    "print(`"Hello, Python 3!`")"
)

$TasksJson = [ordered]@{
    version = "2.0.0"
    tasks = @(
        [ordered]@{
            label = "build debug C++14"
            type = "shell"
            command = "g++14"
            args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe')
            group = "build"
            problemMatcher = @('$gcc')
        },
        [ordered]@{
            label = "build debug C++17"
            type = "shell"
            command = "g++17"
            args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe')
            group = [ordered]@{
                kind = "build"
                isDefault = $true
            }
            problemMatcher = @('$gcc')
        },
        [ordered]@{
            label = "build debug C++20"
            type = "shell"
            command = "g++20"
            args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe')
            group = "build"
            problemMatcher = @('$gcc')
        },
        [ordered]@{
            label = "build debug C11"
            type = "shell"
            command = "gcc"
            args = @("-std=c11", "-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe')
            group = "build"
            problemMatcher = @('$gcc')
        },
        [ordered]@{
            label = "run active executable"
            type = "shell"
            command = '${fileDirname}\${fileBasenameNoExtension}.exe'
            group = "test"
            problemMatcher = @()
        },
        [ordered]@{
            label = "run Python3"
            type = "shell"
            command = "python3"
            args = @('${file}')
            group = "test"
            problemMatcher = @()
        }
    )
}

$TasksJson | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 "$VSCodeDir\tasks.json"

$LaunchJson = [ordered]@{
    version = "0.2.0"
    configurations = @(
        [ordered]@{
            name = "Debug C++14 active file"
            type = "cppdbg"
            request = "launch"
            program = '${fileDirname}\${fileBasenameNoExtension}.exe'
            args = @()
            stopAtEntry = $false
            cwd = '${fileDirname}'
            environment = @()
            externalConsole = $false
            MIMode = "gdb"
            miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"
            preLaunchTask = "build debug C++14"
            setupCommands = @(
                [ordered]@{
                    description = "Enable pretty-printing for gdb"
                    text = "-enable-pretty-printing"
                    ignoreFailures = $true
                }
            )
        },
        [ordered]@{
            name = "Debug C++17 active file"
            type = "cppdbg"
            request = "launch"
            program = '${fileDirname}\${fileBasenameNoExtension}.exe'
            args = @()
            stopAtEntry = $false
            cwd = '${fileDirname}'
            environment = @()
            externalConsole = $false
            MIMode = "gdb"
            miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"
            preLaunchTask = "build debug C++17"
            setupCommands = @(
                [ordered]@{
                    description = "Enable pretty-printing for gdb"
                    text = "-enable-pretty-printing"
                    ignoreFailures = $true
                }
            )
        },
        [ordered]@{
            name = "Debug C++20 active file"
            type = "cppdbg"
            request = "launch"
            program = '${fileDirname}\${fileBasenameNoExtension}.exe'
            args = @()
            stopAtEntry = $false
            cwd = '${fileDirname}'
            environment = @()
            externalConsole = $false
            MIMode = "gdb"
            miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"
            preLaunchTask = "build debug C++20"
            setupCommands = @(
                [ordered]@{
                    description = "Enable pretty-printing for gdb"
                    text = "-enable-pretty-printing"
                    ignoreFailures = $true
                }
            )
        },
        [ordered]@{
            name = "Debug C11 active file"
            type = "cppdbg"
            request = "launch"
            program = '${fileDirname}\${fileBasenameNoExtension}.exe'
            args = @()
            stopAtEntry = $false
            cwd = '${fileDirname}'
            environment = @()
            externalConsole = $false
            MIMode = "gdb"
            miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"
            preLaunchTask = "build debug C11"
            setupCommands = @(
                [ordered]@{
                    description = "Enable pretty-printing for gdb"
                    text = "-enable-pretty-printing"
                    ignoreFailures = $true
                }
            )
        },
        [ordered]@{
            name = "Debug Python3 current file"
            type = "debugpy"
            request = "launch"
            program = '${file}'
            console = "integratedTerminal"
            cwd = '${fileDirname}'
            justMyCode = $true
        }
    )
}

$LaunchJson | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 "$VSCodeDir\launch.json"

$CppPropertiesJson = [ordered]@{
    configurations = @(
        [ordered]@{
            name = "MSYS2 UCRT64 GCC"
            includePath = @(
                '${workspaceFolder}/**',
                "C:/msys64/ucrt64/include/**"
            )
            defines = @()
            compilerPath = "C:/msys64/ucrt64/bin/g++.exe"
            cStandard = "c11"
            cppStandard = "c++17"
            intelliSenseMode = "windows-gcc-x64"
        }
    )
    version = 4
}

$CppPropertiesJson | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 "$VSCodeDir\c_cpp_properties.json"

Write-Host "Template created: $TemplateRoot" -ForegroundColor Green

# ============================================================
# 10. Version report
# ============================================================

Write-Section "10. Version report"

$VersionReport = @()

$VersionReport += "Contest commands"
$VersionReport += "----------------"
$VersionReport += "C++14    : g++14"
$VersionReport += "C++17    : g++17"
$VersionReport += "C++20    : g++20"
$VersionReport += "C        : gcc"
$VersionReport += "Python 3 : python3"
$VersionReport += "Text     : cat"
$VersionReport += ""
$VersionReport += "g++ version:"
$VersionReport += (& "$UcrtBin\g++.exe" --version | Select-Object -First 1)
$VersionReport += ""
$VersionReport += "gcc version:"
$VersionReport += (& "$UcrtBin\gcc.exe" --version | Select-Object -First 1)
$VersionReport += ""
$VersionReport += "gdb version:"
$VersionReport += (& "$UcrtBin\gdb.exe" --version | Select-Object -First 1)
$VersionReport += ""
$VersionReport += "python version:"
$VersionReport += (& "$PythonExe" --version)
$VersionReport += ""
$VersionReport += "cat version:"
$VersionReport += (& "$MsysCat" --version | Select-Object -First 1)

$VersionReport | Set-Content -Encoding UTF8 "$TestDir\version-report.txt"
$VersionReport | ForEach-Object { Write-Host $_ }

# ============================================================
# 11. Compile and run tests
# ============================================================

Write-Section "11. Compile and run tests"

$Cpp14 = @(
    "#include <bits/stdc++.h>",
    "using namespace std;",
    "",
    "int main() {",
    "    auto f = [](auto x) { return x + 14; };",
    "    cout << `"CPP14 OK `" << f(0) << `"\n`";",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TestDir\cpp14.cpp" $Cpp14
& "$ToolBin\g++14.cmd" "$TestDir\cpp14.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp14.exe"
$Out = (& "$TestDir\cpp14.exe") -join "`n"
Assert-Output -Name "C++14" -Actual $Out -Expected "CPP14 OK 14"

$Cpp17 = @(
    "#include <bits/stdc++.h>",
    "using namespace std;",
    "",
    "int main() {",
    "    pair<int, int> p = {17, 0};",
    "    auto [a, b] = p;",
    "    cout << `"CPP17 OK `" << a + b << `"\n`";",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TestDir\cpp17.cpp" $Cpp17
& "$ToolBin\g++17.cmd" "$TestDir\cpp17.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp17.exe"
$Out = (& "$TestDir\cpp17.exe") -join "`n"
Assert-Output -Name "C++17" -Actual $Out -Expected "CPP17 OK 17"

$Cpp20 = @(
    "#include <bits/stdc++.h>",
    "#include <concepts>",
    "using namespace std;",
    "",
    "template <std::integral T>",
    "T twice(T x) {",
    "    return x * 2;",
    "}",
    "",
    "int main() {",
    "    cout << `"CPP20 OK `" << twice(10) << `"\n`";",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TestDir\cpp20.cpp" $Cpp20
& "$ToolBin\g++20.cmd" "$TestDir\cpp20.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp20.exe"
$Out = (& "$TestDir\cpp20.exe") -join "`n"
Assert-Output -Name "C++20" -Actual $Out -Expected "CPP20 OK 20"

$C11 = @(
    "#include <stdio.h>",
    "",
    "_Static_assert(__STDC_VERSION__ >= 201112L, `"C11 required`");",
    "",
    "int main(void) {",
    "    printf(`"C11 OK 11\n`");",
    "    return 0;",
    "}"
)

Write-LinesUtf8NoBom "$TestDir\c11.c" $C11
& "$ToolBin\gcc.cmd" "$TestDir\c11.c" -std=c11 -O2 -Wall -Wextra -o "$TestDir\c11.exe"
$Out = (& "$TestDir\c11.exe") -join "`n"
Assert-Output -Name "C11" -Actual $Out -Expected "C11 OK 11"

Write-LinesUtf8NoBom "$TestDir\python3_test.py" @(
    "print(`"PYTHON3 OK 6`")"
)

$Out = (& "$ToolBin\python3.cmd" "$TestDir\python3_test.py") -join "`n"
Assert-Output -Name "Python3" -Actual $Out -Expected "PYTHON3 OK 6"

Write-LinesUtf8NoBom "$TestDir\text_test.txt" @(
    "TEXT OK"
)

$Out = (& "$ToolBin\cat.cmd" "$TestDir\text_test.txt") -join "`n"
Assert-Output -Name "Text cat" -Actual $Out -Expected "TEXT OK"

# ============================================================
# 12. AI hosts block
# ============================================================

if ($SkipAiBlock) {
    Write-Section "12. AI hosts block skipped"
    Write-Host "AI hosts block was skipped by -SkipAiBlock." -ForegroundColor Yellow
}
else {
    Apply-AiHostsBlock
}

# ============================================================
# 13. Final
# ============================================================

Write-Section "13. Done"

Write-Host "All setup and tests completed." -ForegroundColor Green
Write-Host ""
Write-Host "Available commands:"
Write-Host "  C++14    : g++14"
Write-Host "  C++17    : g++17"
Write-Host "  C++20    : g++20"
Write-Host "  C        : gcc"
Write-Host "  Python 3 : python3"
Write-Host "  Text     : cat"
Write-Host ""
Write-Host "VS Code extensions:"
Write-Host "  formulahendry.code-runner"
Write-Host "  ms-vscode.cpptools"
Write-Host "  ms-python.python"
Write-Host "  ms-python.debugpy"
Write-Host ""
Write-Host "Code Runner:"
Write-Host "  Ctrl + Alt + N runs the current file in the integrated terminal."
Write-Host ""
Write-Host "Debug:"
Write-Host "  F5 starts debugging using .vscode/launch.json."
Write-Host ""
Write-Host "Test directory:"
Write-Host "  $TestDir"
Write-Host ""
Write-Host "Version report:"
Write-Host "  $TestDir\version-report.txt"
Write-Host ""
Write-Host "VS Code template:"
Write-Host "  $TemplateRoot"
Write-Host ""
Write-Host "hosts backup:"
Write-Host "  $BackupPath"
Write-Host ""
Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
