# setup-contest-env.ps1
# Windows contest environment setup.
# Java is intentionally excluded.
#
# Installs/configures:
# - VS Code, reset by default unless -KeepVSCode is used
# - VS Code extensions: Code Runner, C/C++, Python, Python Debugger
# - MSYS2 UCRT64 GCC/G++/GDB/Make/CMake/Ninja/coreutils
# - Python 3.10.12
# - commands: g++14, g++17, g++20, gcc, g++, python3, cat
# - Code Runner settings, tasks.json, launch.json
# - AI hosts blocklist unless -SkipAiBlock is used
#
# Options:
#   -SkipAiBlock  : do not modify hosts
#   -RestoreHosts : restore C:\Windows\System32\drivers\etc\hosts from hosts.bak
#   -KeepVSCode   : keep existing VS Code settings/extensions
#   -NoPause      : do not wait for Enter at the end

param(
    [switch]$SkipAiBlock,
    [switch]$RestoreHosts,
    [switch]$KeepVSCode,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try {
    chcp.com 65001 | Out-Null
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
}
catch {
}

try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

$Root        = "C:\CPTools"
$ToolBin     = "$Root\bin"
$DownloadDir = "$Root\downloads"
$TestDir     = "$Root\tests"
$LogDir      = "$Root\logs"
$TimeStamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$TranscriptPath = "$LogDir\setup-transcript-$TimeStamp.txt"
$ErrorLogPath   = "$LogDir\setup-error-$TimeStamp.txt"
$Script:TranscriptStarted = $false

$MsysRoot = "C:\msys64"
$MsysBash = "$MsysRoot\usr\bin\bash.exe"
$MsysCat  = "$MsysRoot\usr\bin\cat.exe"
$UcrtBin  = "$MsysRoot\ucrt64\bin"

$PythonDir       = "$Root\Python310"
$PythonExe       = "$PythonDir\python.exe"
$PythonUrl       = "https://www.python.org/ftp/python/3.10.12/python-3.10.12-amd64.exe"
$PythonInstaller = "$DownloadDir\python-3.10.12-amd64.exe"

$VSCodeInstallerUrl  = "https://update.code.visualstudio.com/latest/win32-x64/stable"
$VSCodeInstallerPath = "$DownloadDir\VSCodeSetup-x64.exe"

$Msys2InstallerUrl  = "https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe"
$Msys2InstallerPath = "$DownloadDir\msys2-x86_64-latest.exe"

$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$BackupPath = "$env:SystemRoot\System32\drivers\etc\hosts.bak"
$BlockDir = "$Root\ai-block"
$RawListPath = "$BlockDir\noai_hosts.txt"
$ParsedListPath = "$BlockDir\parsed-ai-hosts.txt"
$NoAiHostsUrl = "https://raw.githubusercontent.com/laylavish/uBlockOrigin-HUGE-AI-Blocklist/main/noai_hosts.txt"
$BeginMarker = "# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN"
$EndMarker   = "# <<< CP_CONTEST_AI_BLOCKLIST_END"

$AllowList = @(
    "localhost", "localhost.localdomain",
    "github.com", "raw.githubusercontent.com", "objects.githubusercontent.com", "githubusercontent.com",
    "code.visualstudio.com", "marketplace.visualstudio.com",
    "msys2.org", "packages.msys2.org", "repo.msys2.org", "mirror.msys2.org",
    "python.org", "www.python.org",
    "winget.azureedge.net", "cdn.winget.microsoft.com"
)

function Write-Section([string]$Message) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Test-CommandExists([string]$Command) {
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

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

function Start-SetupLogging {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    try {
        Start-Transcript -Path $TranscriptPath -Force | Out-Null
        $Script:TranscriptStarted = $true
        Write-Host "Logging started." -ForegroundColor Green
        Write-Host "Transcript log: $TranscriptPath"
        Write-Host "Error log     : $ErrorLogPath"
    } catch {
        Write-Warning "Failed to start transcript logging."
        Write-Warning $_.Exception.Message
    }
}

function Stop-SetupLogging {
    if ($Script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $Script:TranscriptStarted = $false
    }
}

function Write-ErrorLog($ErrorRecord) {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $Lines = @()
        $Lines += "============================================================"
        $Lines += "Fatal error"
        $Lines += "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $Lines += "============================================================"
        $Lines += ""
        $Lines += "Message:"
        $Lines += $ErrorRecord.Exception.Message
        $Lines += ""
        $Lines += "Exception:"
        $Lines += $ErrorRecord.Exception.GetType().FullName
        $Lines += ""
        $Lines += "Script stack trace:"
        $Lines += $ErrorRecord.ScriptStackTrace
        $Lines += ""
        $Lines += "Invocation:"
        $Lines += $ErrorRecord.InvocationInfo.PositionMessage
        $Lines += ""
        $Lines += "Full error:"
        $Lines += ($ErrorRecord | Format-List * -Force | Out-String)
        $Lines | Set-Content -Encoding UTF8 $ErrorLogPath
    } catch {
        Write-Warning "Failed to write error log."
    }
}

function Pause-BeforeExit {
    if (-not $NoPause) {
        Write-Host ""
        Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}

function Assert-Admin {
    if (Test-IsAdmin) { return }

    $ScriptPath = $null
    if ($PSCommandPath) { $ScriptPath = $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $ScriptPath = $MyInvocation.MyCommand.Path }

    if (-not $ScriptPath) {
        throw "Administrator permission is required. Run this script from a saved .ps1 file."
    }

    $Args = @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ScriptPath`"")
    if ($SkipAiBlock) { $Args += "-SkipAiBlock" }
    if ($RestoreHosts) { $Args += "-RestoreHosts" }
    if ($KeepVSCode) { $Args += "-KeepVSCode" }
    if ($NoPause) { $Args += "-NoPause" }

    Write-Host "Requesting administrator permission..." -ForegroundColor Yellow
    Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $Args -Verb RunAs -Wait
    exit
}

function Write-TextUtf8NoBom([string]$Path, [string]$Content) {
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom([string]$Path, [string[]]$Lines) {
    $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-TextUtf8NoBom -Path $Path -Content $Content
}

function Invoke-DownloadFile([string]$Url, [string]$OutFile) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Add-UserPathFront([string]$PathToAdd) {
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

function Test-WingetHelpSupports([string]$Command, [string]$Option) {
    try {
        $HelpText = (& winget $Command --help 2>$null) -join "`n"
        return $HelpText -match [regex]::Escape($Option)
    } catch {
        return $false
    }
}

function Invoke-Winget {
    param([string[]]$Arguments)

    Write-Host "winget $($Arguments -join ' ')" -ForegroundColor DarkGray

    # Capture winget output inside the function so it does not become
    # part of the function return value.
    $WingetOutput = & winget @Arguments 2>&1
    $ExitCode = [int]$LASTEXITCODE

    foreach ($Line in $WingetOutput) {
        if ($null -ne $Line) {
            Write-Host $Line
        }
    }

    return $ExitCode
}

function Update-WingetClient {
    Write-Section "Update winget / App Installer"

    if (-not (Test-CommandExists "winget")) {
        Write-Warning "winget not found. Continuing with direct installer fallback."
        return
    }

    Write-Host "Current winget version:"
    try { winget --version } catch {}

    $AppInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($AppInstaller) {
        Write-Host "Current App Installer version: $($AppInstaller.Version)"
    }

    $Args = @(
        "upgrade", "Microsoft.AppInstaller",
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
        } else {
            Write-Warning "winget update returned exit code $Exit. Continuing with current winget version."
        }
    } catch {
        Write-Warning "winget update failed. Continuing with current winget version."
    }

    Write-Host "winget version after update attempt:"
    try { winget --version } catch {}
}

function Install-ByWinget {
    param(
        [Parameter(Mandatory = $true)] [string]$Id,
        [Parameter(Mandatory = $true)] [string]$NameForLog
    )

    if (-not (Test-CommandExists "winget")) {
        Write-Warning "winget not found. Fallback will be used for $NameForLog."
        return $false
    }

    Write-Host "Installing by winget: $NameForLog"
    $WingetLogDir = "$LogDir\winget"
    New-Item -ItemType Directory -Force -Path $WingetLogDir | Out-Null
    $SafeName = $NameForLog -replace '[\\/:*?"<>| ]', '_'
    $WingetLogPath = "$WingetLogDir\$SafeName-install.log"

    $Args = @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", "winget",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--log", $WingetLogPath
    )
    if (Test-WingetHelpSupports -Command "install" -Option "--disable-interactivity") {
        $Args += "--disable-interactivity"
    }

    try {
        $ExitCode = Invoke-Winget -Arguments $Args
    } catch {
        Write-Warning "winget crashed while installing $NameForLog."
        return $false
    }

    if ($ExitCode -eq 0) {
        Write-Host "$NameForLog installed by winget." -ForegroundColor Green
        return $true
    }

    Write-Warning "winget failed for $NameForLog. Exit code: $ExitCode"
    Write-Warning "winget log: $WingetLogPath"

    try {
        $ListOutput = (& winget list --id $Id --exact 2>$null) -join "`n"
        if ($ListOutput -match [regex]::Escape($Id)) {
            Write-Host "$NameForLog appears to be already installed. Continuing." -ForegroundColor Green
            return $true
        }
    } catch {}

    return $false
}

function Uninstall-WingetPackageIfExists {
    param([string]$Id, [string]$NameForLog)

    if (-not (Test-CommandExists "winget")) {
        Write-Host "winget not found. Skipping winget uninstall for $NameForLog."
        return
    }

    Write-Host "Checking installed package: $NameForLog"
    try {
        $ListOutput = (& winget list --id $Id --exact 2>$null) -join "`n"
    } catch {
        Write-Warning "winget list failed for $NameForLog. Skipping winget uninstall."
        return
    }

    if ($ListOutput -notmatch [regex]::Escape($Id)) {
        Write-Host "$NameForLog is not installed by winget or not detected. Continuing."
        return
    }

    $Args = @("uninstall", "--id", $Id, "--exact", "--silent")
    if (Test-WingetHelpSupports -Command "uninstall" -Option "--source") {
        $Args += "--source"; $Args += "winget"
    }
    if (Test-WingetHelpSupports -Command "uninstall" -Option "--accept-source-agreements") {
        $Args += "--accept-source-agreements"
    }
    if (Test-WingetHelpSupports -Command "uninstall" -Option "--disable-interactivity") {
        $Args += "--disable-interactivity"
    }

    Write-Host "Uninstalling: $NameForLog"
    try {
        $Exit = Invoke-Winget -Arguments $Args
        if ($Exit -ne 0) {
            Write-Warning "winget uninstall returned exit code $Exit for $NameForLog. Continuing with folder cleanup."
        }
    } catch {
        Write-Warning "winget uninstall crashed for $NameForLog. Continuing with folder cleanup."
    }
}

function Get-VSCodeCommandPath {
    $Candidates = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd"
    )
    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) { return $Candidate }
    }

    $Cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }

    $Cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }

    return $null
}

function Stop-VSCodeProcesses {
    Write-Host "Closing VS Code processes if running..."
    $Names = @("Code", "Code - Insiders", "VSCodium")
    foreach ($Name in $Names) {
        Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Backup-And-RemovePath([string]$Path, [string]$BackupRoot) {
    if (-not (Test-Path $Path)) { return }
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

    $BackupRoot = Join-Path $Root ("backup\vscode-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Write-Host "VS Code backup directory:"
    Write-Host "  $BackupRoot"

    $CodeCmdBeforeReset = Get-VSCodeCommandPath
    if ($CodeCmdBeforeReset) {
        try {
            & $CodeCmdBeforeReset --list-extensions | Set-Content -Encoding UTF8 "$BackupRoot\extensions-before-reset.txt"
            Write-Host "Extension list backed up." -ForegroundColor Green
        } catch {}
    }

    foreach ($Path in @("$env:APPDATA\Code", "$env:LOCALAPPDATA\Code", "$env:USERPROFILE\.vscode")) {
        Backup-And-RemovePath -Path $Path -BackupRoot $BackupRoot
    }

    Uninstall-WingetPackageIfExists -Id "Microsoft.VisualStudioCode" -NameForLog "Visual Studio Code"

    foreach ($Folder in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code", "$env:ProgramFiles\Microsoft VS Code", "${env:ProgramFiles(x86)}\Microsoft VS Code")) {
        if (Test-Path $Folder) {
            Write-Host "Removing remaining VS Code install folder: $Folder"
            Remove-Item -Path $Folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "VS Code reset completed." -ForegroundColor Green
}

function Install-VSCodeDirect {
    Write-Section "Install VS Code directly"

    if (Get-VSCodeCommandPath) {
        Write-Host "VS Code already appears to be installed." -ForegroundColor Green
        return
    }

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    Write-Host "Downloading VS Code installer..."
    Invoke-DownloadFile -Url $VSCodeInstallerUrl -OutFile $VSCodeInstallerPath

    Write-Host "Installing VS Code directly..."
    $Process = Start-Process `
        -FilePath $VSCodeInstallerPath `
        -ArgumentList @("/VERYSILENT", "/NORESTART", "/MERGETASKS=addcontextmenufiles,addcontextmenufolders,addtopath") `
        -Wait -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "VS Code direct installer failed. Exit code: $($Process.ExitCode)"
    }

    $WaitCount = 0
    while (-not (Get-VSCodeCommandPath) -and $WaitCount -lt 60) {
        Start-Sleep -Seconds 2
        $WaitCount++
    }
    if (-not (Get-VSCodeCommandPath)) {
        throw "VS Code installed, but code.cmd was not found."
    }

    Write-Host "VS Code direct install completed." -ForegroundColor Green
}

function Install-VSCodeExtensions {
    Write-Section "Install VS Code extensions"

    $CodeCmd = $null
    $WaitCount = 0
    while (-not $CodeCmd -and $WaitCount -lt 60) {
        $CodeCmd = Get-VSCodeCommandPath
        if (-not $CodeCmd) { Start-Sleep -Seconds 2; $WaitCount++ }
    }
    if (-not $CodeCmd) { throw "code.cmd not found after VS Code installation." }

    $Extensions = @(
        "formulahendry.code-runner",
        "ms-vscode.cpptools",
        "ms-python.python",
        "ms-python.debugpy"
    )

    foreach ($Extension in $Extensions) {
        Write-Host "Installing VS Code extension: $Extension"
        & $CodeCmd --install-extension $Extension --force
        if ($LASTEXITCODE -ne 0) { throw "Failed to install VS Code extension: $Extension" }
    }

    $InstalledExtensions = (& $CodeCmd --list-extensions) -join "`n"
    foreach ($Extension in $Extensions) {
        if ($InstalledExtensions -notmatch [regex]::Escape($Extension)) {
            throw "Extension verification failed: $Extension"
        }
    }

    Write-Host "VS Code extensions installed and verified." -ForegroundColor Green
}

function Install-MSYS2Direct {
    Write-Section "Install MSYS2 directly"

    if (Test-Path $MsysBash) {
        Write-Host "MSYS2 already appears to be installed: $MsysBash" -ForegroundColor Green
        return
    }

    if ((Test-Path $MsysRoot) -and (-not (Test-Path $MsysBash))) {
        Write-Warning "Incomplete MSYS2 folder found. Removing: $MsysRoot"
        Remove-Item -Path $MsysRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    Write-Host "Downloading MSYS2 installer..."
    Invoke-DownloadFile -Url $Msys2InstallerUrl -OutFile $Msys2InstallerPath

    Write-Host "Installing MSYS2 directly..."
    $Process = Start-Process `
        -FilePath $Msys2InstallerPath `
        -ArgumentList @("in", "--confirm-command", "--accept-messages", "--root", "C:/msys64") `
        -Wait -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "MSYS2 direct installer failed. Exit code: $($Process.ExitCode)"
    }

    $WaitCount = 0
    while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) {
        Start-Sleep -Seconds 2
        $WaitCount++
    }
    if (-not (Test-Path $MsysBash)) {
        throw "MSYS2 installed, but bash.exe was not found: $MsysBash"
    }

    Write-Host "MSYS2 direct install completed." -ForegroundColor Green
}

function Set-JsonProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Invoke-MsysBash([string]$Command) {
    & $MsysBash -lc $Command
}

function Assert-Output([string]$Name, [string]$Actual, [string]$Expected) {
    $A = $Actual.Trim()
    $E = $Expected.Trim()
    if ($A -ne $E) { throw "$Name test failed. Expected: [$E], Actual: [$A]" }
    Write-Host "$Name test passed: $A" -ForegroundColor Green
}

function Restore-HostsBackup {
    Write-Section "Restore hosts file"
    if (-not (Test-Path $BackupPath)) { throw "hosts.bak not found: $BackupPath" }
    Copy-Item -Path $BackupPath -Destination $HostsPath -Force
    ipconfig /flushdns | Out-Null
    Write-Host "hosts restored from: $BackupPath" -ForegroundColor Green
}

function Apply-AiHostsBlock {
    Write-Section "AI hosts block"

    New-Item -ItemType Directory -Force -Path $BlockDir | Out-Null
    if (-not (Test-Path $HostsPath)) { throw "hosts file not found: $HostsPath" }

    if (-not (Test-Path $BackupPath)) {
        Copy-Item -Path $HostsPath -Destination $BackupPath -Force
        Write-Host "Backup created: $BackupPath" -ForegroundColor Green
    } else {
        $ExtraBackup = "$env:SystemRoot\System32\drivers\etc\hosts.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $HostsPath -Destination $ExtraBackup -Force
        Write-Host "Extra backup created: $ExtraBackup" -ForegroundColor Yellow
    }

    Write-Host "Downloading AI blocklist..."
    Invoke-DownloadFile -Url $NoAiHostsUrl -OutFile $RawListPath

    $RawContent = Get-Content -Path $RawListPath -Raw
    $DomainList = New-Object System.Collections.Generic.List[string]

    foreach ($Line in ($RawContent -split "`r`n|`n|`r")) {
        $Clean = ($Line -replace "#.*$", "").Trim()
        if (-not $Clean) { continue }

        $Parts = $Clean -split "\s+"
        if ($Parts.Count -lt 2) { continue }

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
    if ($Domains.Count -eq 0) { throw "No domains were parsed from the AI blocklist." }

    $Domains | Set-Content -Encoding UTF8 $ParsedListPath
    Write-Host "Parsed domains: $($Domains.Count)" -ForegroundColor Green

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

trap {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "FATAL ERROR" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    Write-ErrorLog -ErrorRecord $_

    Write-Host "Transcript log:"
    Write-Host "  $TranscriptPath"
    Write-Host "Error log:"
    Write-Host "  $ErrorLogPath"

    Stop-SetupLogging
    Pause-BeforeExit
    exit 1
}

# ============================================================
# Main
# ============================================================

Assert-Admin
Start-SetupLogging

if ($RestoreHosts) {
    Restore-HostsBackup
    Stop-SetupLogging
    Pause-BeforeExit
    exit
}

Write-Section "1. Create folders"
New-Item -ItemType Directory -Force -Path $Root, $ToolBin, $DownloadDir, $TestDir, $LogDir | Out-Null

Write-Section "2. Check winget"
if (Test-CommandExists "winget") {
    Write-Host "winget found. Version:" -ForegroundColor Green
    try { winget --version } catch {}
    Write-Host "winget will be used as the primary installer when possible." -ForegroundColor Green
    try { Update-WingetClient } catch { Write-Warning "winget update failed. Continuing." }
} else {
    Write-Warning "winget not found. Direct installers will be used."
}

Write-Section "3. Reset and install VS Code / MSYS2"

if ($KeepVSCode) {
    Write-Host "VS Code reset skipped by -KeepVSCode." -ForegroundColor Yellow
} else {
    Reset-VSCodeCompletely
}

$VSCodeInstalled = Install-ByWinget -Id "Microsoft.VisualStudioCode" -NameForLog "Visual Studio Code"
if (-not $VSCodeInstalled) {
    Write-Warning "VS Code winget install failed. Using direct installer fallback."
    Install-VSCodeDirect
}

Install-VSCodeExtensions

$MSYS2Installed = Install-ByWinget -Id "MSYS2.MSYS2" -NameForLog "MSYS2"
if (-not $MSYS2Installed) {
    Write-Warning "MSYS2 winget install failed. Using direct installer fallback."
    Install-MSYS2Direct
}

$WaitCount = 0
while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) {
    Start-Sleep -Seconds 2
    $WaitCount++
}
if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
Write-Host "MSYS2 found: $MsysBash" -ForegroundColor Green

Write-Section "4. Install MSYS2 packages"
Invoke-MsysBash "echo MSYS2 initialized"

try { Invoke-MsysBash "pacman --noconfirm -Syuu" } catch { Write-Warning "First pacman update may require shell restart. Continuing." }
try { Invoke-MsysBash "pacman --noconfirm -Syu" } catch { Write-Warning "Second pacman update returned a warning. Continuing." }

$MsysPackages = @(
    "base-devel",
    "mingw-w64-ucrt-x86_64-gcc",
    "mingw-w64-ucrt-x86_64-gdb",
    "mingw-w64-ucrt-x86_64-make",
    "mingw-w64-ucrt-x86_64-cmake",
    "mingw-w64-ucrt-x86_64-ninja",
    "coreutils"
)
Invoke-MsysBash ("pacman --needed --noconfirm -S " + ($MsysPackages -join " "))

foreach ($RequiredPath in @("$UcrtBin\g++.exe", "$UcrtBin\gcc.exe", "$UcrtBin\gdb.exe", $MsysCat)) {
    if (-not (Test-Path $RequiredPath)) { throw "Required tool not found: $RequiredPath" }
}
Write-Host "MSYS2 UCRT64 GCC/GDB installed." -ForegroundColor Green

Write-Section "5. Install Python 3.10.12"
if (-not (Test-Path $PythonExe)) {
    if (-not (Test-Path $PythonInstaller)) {
        Write-Host "Downloading Python 3.10.12..."
        Invoke-DownloadFile -Url $PythonUrl -OutFile $PythonInstaller
    }
    Write-Host "Installing Python 3.10.12..."
    $PythonProcess = Start-Process -FilePath $PythonInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 TargetDir=`"$PythonDir`"" -Wait -PassThru
    if ($PythonProcess.ExitCode -ne 0) { throw "Python installer failed. Exit code: $($PythonProcess.ExitCode)" }
}
if (-not (Test-Path $PythonExe)) { throw "Python install failed or python.exe not found: $PythonExe" }
& $PythonExe --version
Write-Host "Python installed: $PythonExe" -ForegroundColor Green

Write-Section "6. Create command wrappers"
Write-LinesUtf8NoBom "$ToolBin\g++14.cmd" @("@echo off", "`"$UcrtBin\g++.exe`" -std=gnu++14 %*")
Write-LinesUtf8NoBom "$ToolBin\g++17.cmd" @("@echo off", "`"$UcrtBin\g++.exe`" -std=gnu++17 %*")
Write-LinesUtf8NoBom "$ToolBin\g++20.cmd" @("@echo off", "`"$UcrtBin\g++.exe`" -std=gnu++20 %*")
Write-LinesUtf8NoBom "$ToolBin\g++.cmd"  @("@echo off", "`"$UcrtBin\g++.exe`" %*")
Write-LinesUtf8NoBom "$ToolBin\gcc.cmd"  @("@echo off", "`"$UcrtBin\gcc.exe`" %*")
Write-LinesUtf8NoBom "$ToolBin\python3.cmd" @("@echo off", "`"$PythonExe`" %*")
Write-LinesUtf8NoBom "$ToolBin\cat.cmd" @("@echo off", "`"$MsysCat`" %*")

Write-Host "Wrappers created." -ForegroundColor Green

Write-Section "7. Configure PATH"
Add-UserPathFront $ToolBin
Add-UserPathFront $UcrtBin
Add-UserPathFront $PythonDir
foreach ($Candidate in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin", "$env:ProgramFiles\Microsoft VS Code\bin", "${env:ProgramFiles(x86)}\Microsoft VS Code\bin")) {
    if (Test-Path $Candidate) { Add-UserPathFront $Candidate; break }
}

Write-Section "8. Configure VS Code"
$CodeCmd = Get-VSCodeCommandPath
if (-not $CodeCmd) { throw "code.cmd not found. VS Code installation may have failed." }

$SettingsDir = "$env:APPDATA\Code\User"
$SettingsPath = "$SettingsDir\settings.json"
New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null

if (Test-Path $SettingsPath) {
    try {
        $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if (-not $Settings) { $Settings = [PSCustomObject]@{} }
    } catch {
        Copy-Item $SettingsPath "$SettingsPath.bak" -Force
        $Settings = [PSCustomObject]@{}
    }
} else {
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
Set-JsonProperty $Profiles "MSYS2 UCRT64" $MsysProfile

$CodeRunnerExecutorMap = [PSCustomObject]@{
    cpp    = 'cd $dir && g++17 -g -O0 -Wall -Wextra $fileName -o $fileNameWithoutExt.exe && .\$fileNameWithoutExt.exe'
    c      = 'cd $dir && gcc -std=c11 -g -O0 -Wall -Wextra $fileName -o $fileNameWithoutExt.exe && .\$fileNameWithoutExt.exe'
    python = 'python3 -u $fullFileName'
}

Set-JsonProperty $Settings "terminal.integrated.profiles.windows" $Profiles
Set-JsonProperty $Settings "terminal.integrated.defaultProfile.windows" "PowerShell"
Set-JsonProperty $Settings "C_Cpp.default.compilerPath" "$UcrtBin\g++.exe"
Set-JsonProperty $Settings "C_Cpp.default.cppStandard" "c++17"
Set-JsonProperty $Settings "C_Cpp.default.cStandard" "c11"
Set-JsonProperty $Settings "C_Cpp.default.intelliSenseMode" "windows-gcc-x64"
Set-JsonProperty $Settings "code-runner.executorMap" $CodeRunnerExecutorMap
Set-JsonProperty $Settings "code-runner.runInTerminal" $true
Set-JsonProperty $Settings "code-runner.fileDirectoryAsCwd" $true
Set-JsonProperty $Settings "code-runner.saveFileBeforeRun" $true
Set-JsonProperty $Settings "code-runner.clearPreviousOutput" $true
Set-JsonProperty $Settings "code-runner.showExecutionMessage" $false
Set-JsonProperty $Settings "code-runner.preserveFocus" $false
Set-JsonProperty $Settings "code-runner.ignoreSelection" $true
Set-JsonProperty $Settings "code-runner.enableAppInsights" $false
Set-JsonProperty $Settings "python.defaultInterpreterPath" "$PythonExe"
Set-JsonProperty $Settings "python.terminal.activateEnvironment" $false
Set-JsonProperty $Settings "debug.openDebug" "openOnDebugBreak"

$Settings | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $SettingsPath
Write-Host "VS Code settings configured." -ForegroundColor Green

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
Write-LinesUtf8NoBom "$TemplateRoot\main.py" @("print(`"Hello, Python 3!`")")

$TasksJson = [ordered]@{
    version = "2.0.0"
    tasks = @(
        [ordered]@{ label = "build debug C++14"; type = "shell"; command = "g++14"; args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe'); group = "build"; problemMatcher = @('$gcc') },
        [ordered]@{ label = "build debug C++17"; type = "shell"; command = "g++17"; args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe'); group = [ordered]@{ kind = "build"; isDefault = $true }; problemMatcher = @('$gcc') },
        [ordered]@{ label = "build debug C++20"; type = "shell"; command = "g++20"; args = @("-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe'); group = "build"; problemMatcher = @('$gcc') },
        [ordered]@{ label = "build debug C11"; type = "shell"; command = "gcc"; args = @("-std=c11", "-g", "-O0", "-Wall", "-Wextra", '${file}', "-o", '${fileDirname}\${fileBasenameNoExtension}.exe'); group = "build"; problemMatcher = @('$gcc') },
        [ordered]@{ label = "run active executable"; type = "shell"; command = '${fileDirname}\${fileBasenameNoExtension}.exe'; group = "test"; problemMatcher = @() },
        [ordered]@{ label = "run Python3"; type = "shell"; command = "python3"; args = @('${file}'); group = "test"; problemMatcher = @() }
    )
}
$TasksJson | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 "$VSCodeDir\tasks.json"

$CppDebugSetup = @(
    [ordered]@{ description = "Enable pretty-printing for gdb"; text = "-enable-pretty-printing"; ignoreFailures = $true }
)

$LaunchJson = [ordered]@{
    version = "0.2.0"
    configurations = @(
        [ordered]@{ name = "Debug C++14 active file"; type = "cppdbg"; request = "launch"; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = "gdb"; miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"; preLaunchTask = "build debug C++14"; setupCommands = $CppDebugSetup },
        [ordered]@{ name = "Debug C++17 active file"; type = "cppdbg"; request = "launch"; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = "gdb"; miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"; preLaunchTask = "build debug C++17"; setupCommands = $CppDebugSetup },
        [ordered]@{ name = "Debug C++20 active file"; type = "cppdbg"; request = "launch"; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = "gdb"; miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"; preLaunchTask = "build debug C++20"; setupCommands = $CppDebugSetup },
        [ordered]@{ name = "Debug C11 active file"; type = "cppdbg"; request = "launch"; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = "gdb"; miDebuggerPath = "C:/msys64/ucrt64/bin/gdb.exe"; preLaunchTask = "build debug C11"; setupCommands = $CppDebugSetup },
        [ordered]@{ name = "Debug Python3 current file"; type = "debugpy"; request = "launch"; program = '${file}'; console = "integratedTerminal"; cwd = '${fileDirname}'; justMyCode = $true }
    )
}
$LaunchJson | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 "$VSCodeDir\launch.json"

$CppPropertiesJson = [ordered]@{
    configurations = @(
        [ordered]@{
            name = "MSYS2 UCRT64 GCC"
            includePath = @('${workspaceFolder}/**', "C:/msys64/ucrt64/include/**")
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

Write-Section "11. Compile and run tests"
$Cpp14 = @("#include <bits/stdc++.h>", "using namespace std;", "", "int main() {", "    auto f = [](auto x) { return x + 14; };", "    cout << `"CPP14 OK `" << f(0) << `"\n`";", "    return 0;", "}")
Write-LinesUtf8NoBom "$TestDir\cpp14.cpp" $Cpp14
& "$ToolBin\g++14.cmd" "$TestDir\cpp14.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp14.exe"
Assert-Output -Name "C++14" -Actual ((& "$TestDir\cpp14.exe") -join "`n") -Expected "CPP14 OK 14"

$Cpp17 = @("#include <bits/stdc++.h>", "using namespace std;", "", "int main() {", "    pair<int, int> p = {17, 0};", "    auto [a, b] = p;", "    cout << `"CPP17 OK `" << a + b << `"\n`";", "    return 0;", "}")
Write-LinesUtf8NoBom "$TestDir\cpp17.cpp" $Cpp17
& "$ToolBin\g++17.cmd" "$TestDir\cpp17.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp17.exe"
Assert-Output -Name "C++17" -Actual ((& "$TestDir\cpp17.exe") -join "`n") -Expected "CPP17 OK 17"

$Cpp20 = @("#include <bits/stdc++.h>", "#include <concepts>", "using namespace std;", "", "template <std::integral T>", "T twice(T x) {", "    return x * 2;", "}", "", "int main() {", "    cout << `"CPP20 OK `" << twice(10) << `"\n`";", "    return 0;", "}")
Write-LinesUtf8NoBom "$TestDir\cpp20.cpp" $Cpp20
& "$ToolBin\g++20.cmd" "$TestDir\cpp20.cpp" -O2 -Wall -Wextra -o "$TestDir\cpp20.exe"
Assert-Output -Name "C++20" -Actual ((& "$TestDir\cpp20.exe") -join "`n") -Expected "CPP20 OK 20"

$C11 = @("#include <stdio.h>", "", "_Static_assert(__STDC_VERSION__ >= 201112L, `"C11 required`");", "", "int main(void) {", "    printf(`"C11 OK 11\n`");", "    return 0;", "}")
Write-LinesUtf8NoBom "$TestDir\c11.c" $C11
& "$ToolBin\gcc.cmd" "$TestDir\c11.c" -std=c11 -O2 -Wall -Wextra -o "$TestDir\c11.exe"
Assert-Output -Name "C11" -Actual ((& "$TestDir\c11.exe") -join "`n") -Expected "C11 OK 11"

Write-LinesUtf8NoBom "$TestDir\python3_test.py" @("print(`"PYTHON3 OK 6`")")
Assert-Output -Name "Python3" -Actual ((& "$ToolBin\python3.cmd" "$TestDir\python3_test.py") -join "`n") -Expected "PYTHON3 OK 6"

Write-LinesUtf8NoBom "$TestDir\text_test.txt" @("TEXT OK")
Assert-Output -Name "Text cat" -Actual ((& "$ToolBin\cat.cmd" "$TestDir\text_test.txt") -join "`n") -Expected "TEXT OK"

if ($SkipAiBlock) {
    Write-Section "12. AI hosts block skipped"
    Write-Host "AI hosts block was skipped by -SkipAiBlock." -ForegroundColor Yellow
} else {
    Apply-AiHostsBlock
}

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
Write-Host "Code Runner: Ctrl + Alt + N runs the current file in the integrated terminal."
Write-Host "Debug: F5 starts debugging using .vscode/launch.json."
Write-Host ""
Write-Host "Test directory: $TestDir"
Write-Host "Version report: $TestDir\version-report.txt"
Write-Host "VS Code template: $TemplateRoot"
Write-Host "hosts backup: $BackupPath"
Write-Host "Transcript log: $TranscriptPath"
Write-Host "Error log: $ErrorLogPath"
Write-Host ""
Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow

Stop-SetupLogging
Pause-BeforeExit
