#requires -Version 5.1
# setup-contest-env.deepreview.fixed.ps1
# Windows contest environment setup.
# Re-exported from the deep-review revision for the current ChatGPT session.
# Java is intentionally excluded.
#
# Safer revision notes:
# - AI hosts blocking is opt-in: use -EnableAiBlock with -AiBlockListPath or the built-in default list.
# - VS Code user settings are not overwritten; optional contest settings can be created in Desktop\CP-Template\.vscode.
# - -KeepVSCode preserves existing VS Code profile; if VS Code is missing, it installs VS Code and required extensions.
# - Native commands are checked by exit code instead of relying on try/catch alone.
# - Directly downloaded installers are Authenticode-checked unless -SkipSignatureCheck is used.
# - C:\msys64\ucrt64\bin is added to the user PATH so gcc/g++ work directly in VS Code terminals.
# - C:\CPTools\bin is also added for versioned wrappers such as g++14, g++17, g++20, and python3.
#
# Common usage:
#   powershell -ExecutionPolicy Bypass -File .\setup-contest-env.deepreview.fixed.ps1 -NoPause
#   powershell -ExecutionPolicy Bypass -File .\setup-contest-env.deepreview.fixed.ps1 -KeepVSCode
#   powershell -ExecutionPolicy Bypass -File .\setup-contest-env.deepreview.fixed.ps1 -RestoreHosts
#   powershell -ExecutionPolicy Bypass -File .\setup-contest-env.deepreview.fixed.ps1 -EnableAiBlock
#
# Note: Python 3.10.11 is the default because it is the last Python 3.10 release with Windows installers.

[CmdletBinding()]
param(
    [switch]$EnableAiBlock,
    [switch]$SkipAiBlock,
    [string]$AiBlockListPath = '',
    [string]$AiBlockListUrl = '',
    [string]$AiBlockListSha256 = '',
    [switch]$AllowUnverifiedAiBlockUrl,

    [switch]$RestoreHosts,
    [switch]$RestoreHostsFromBackup,
    [switch]$KeepVSCode,
    [switch]$CreateTemplate,
    [switch]$NoPause,
    [switch]$SkipSignatureCheck,

    [string]$Root = "$env:SystemDrive\CPTools",
    [string]$MsysRoot = "$env:SystemDrive\msys64",
    [string]$Msys2CaCertificatePath = '',
    [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory),
    [string]$PythonVersion = '3.10.11'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

try {
    chcp.com 65001 | Out-Null
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning "Console UTF-8 setup failed. Continuing. $($_.Exception.Message)"
}

$ToolBin     = Join-Path $Root 'bin'
$DownloadDir = Join-Path $Root 'downloads'
$TestDir     = Join-Path $Root 'tests'
$LogDir      = Join-Path $Root 'logs'
$BackupDir   = Join-Path $Root 'backup'
$TimeStamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$TranscriptPath = Join-Path $LogDir "setup-transcript-$TimeStamp.txt"
$ErrorLogPath   = Join-Path $LogDir "setup-error-$TimeStamp.txt"
$Script:TranscriptStarted = $false

$MsysBash = Join-Path $MsysRoot 'usr\bin\bash.exe'
$MsysCat  = Join-Path $MsysRoot 'usr\bin\cat.exe'
$UcrtBin  = Join-Path $MsysRoot 'ucrt64\bin'
$MsysShellCmd = Join-Path $MsysRoot 'msys2_shell.cmd'

$VersionParts = $PythonVersion -split '\.'
if ($VersionParts.Count -lt 2) { throw "Invalid PythonVersion: $PythonVersion" }
$PythonDir       = Join-Path $Root ("Python{0}{1}" -f $VersionParts[0], $VersionParts[1])
$PythonExe       = Join-Path $PythonDir 'python.exe'
$PythonInstallerName = "python-$PythonVersion-amd64.exe"
$PythonUrl       = "https://www.python.org/ftp/python/$PythonVersion/$PythonInstallerName"
$PythonInstaller = Join-Path $DownloadDir $PythonInstallerName

$VSCodeInstallerUrl  = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
$VSCodeInstallerPath = Join-Path $DownloadDir 'VSCodeSetup-x64.exe'

$Msys2InstallerUrl  = 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe'
$Msys2InstallerPath = Join-Path $DownloadDir 'msys2-x86_64-latest.exe'

$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$BackupPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.bak'
$BlockDir = Join-Path $Root 'ai-block'
$RawListPath = Join-Path $BlockDir 'noai_hosts.txt'
$ParsedListPath = Join-Path $BlockDir 'parsed-ai-hosts.txt'
$BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
$EndMarker   = '# <<< CP_CONTEST_AI_BLOCKLIST_END'

$AllowList = @(
    'localhost', 'localhost.localdomain',
    'github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com', 'githubusercontent.com',
    'code.visualstudio.com', 'marketplace.visualstudio.com',
    'msys2.org', 'packages.msys2.org', 'repo.msys2.org', 'mirror.msys2.org',
    'python.org', 'www.python.org',
    'winget.azureedge.net', 'cdn.winget.microsoft.com'
)

$DefaultAiBlockDomains = @(
    'chat.openai.com',
    'chatgpt.com',
    'openai.com',
    'api.openai.com',
    'oaistatic.com',
    'oaiusercontent.com',
    'anthropic.com',
    'claude.ai',
    'api.anthropic.com',
    'gemini.google.com',
    'bard.google.com',
    'generativelanguage.googleapis.com',
    'makersuite.google.com',
    'copilot.microsoft.com',
    'bing.com',
    'edgeservices.bing.com',
    'api.githubcopilot.com',
    'copilot-proxy.githubusercontent.com',
    'githubcopilot.com',
    'cursor.com',
    'cursor.sh',
    'api.cursor.sh',
    'tabnine.com',
    'api.tabnine.com',
    'codeium.com',
    'windsurf.com',
    'supermaven.com',
    'perplexity.ai',
    'poe.com',
    'you.com',
    'phind.com',
    'huggingface.co',
    'replicate.com'
)

function Write-Section {
    param([Parameter(Mandatory = $true)] [string]$Message)
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)] [string]$Command)
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $SysnativePowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $SysnativePowerShell) { return $SysnativePowerShell }
    }

    $PowerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $PowerShell51) { return $PowerShell51 }

    $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Pwsh) { return $Pwsh.Source }

    throw 'No supported PowerShell executable was found for self-relaunch.'
}

function Quote-ProcessArgument {
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '""' }
    $Text = [string]$Value
    if ($Text -notmatch '[\s"]') { return $Text }

    # Windows command-line quoting: keep normal path backslashes intact,
    # but escape embedded quotes and trailing backslashes before the closing quote.
    $Escaped = $Text -replace '(\*)"', '$1$1\"'
    $Escaped = $Escaped -replace '(\+)$', '$1$1'
    return '"' + $Escaped + '"'
}

function Assert-SupportedEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script supports Windows only.'
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This script requires 64-bit Windows because it installs 64-bit toolchains and uses the native System32 view.'
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw 'This script requires Windows PowerShell 5.1 or PowerShell 7+.'
    }
}

function Ensure-PreferredHostAndAdmin {
    $Need64BitRelaunch = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    $NeedElevation = -not (Test-IsAdmin)
    if (-not $Need64BitRelaunch -and -not $NeedElevation) { return }

    if (-not $PSCommandPath) {
        throw 'Self-relaunch is only supported from a saved .ps1 file.'
    }

    $Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)

    foreach ($Name in @('EnableAiBlock', 'SkipAiBlock', 'RestoreHosts', 'RestoreHostsFromBackup', 'KeepVSCode', 'CreateTemplate', 'NoPause', 'SkipSignatureCheck', 'AllowUnverifiedAiBlockUrl')) {
        $Value = Get-Variable -Name $Name -ValueOnly
        if ($Value) { $Args += "-$Name" }
    }

    $StringParams = @{
        Root = $Root
        MsysRoot = $MsysRoot
        Msys2CaCertificatePath = $Msys2CaCertificatePath
        DesktopPath = $DesktopPath
        PythonVersion = $PythonVersion
        AiBlockListPath = $AiBlockListPath
        AiBlockListUrl = $AiBlockListUrl
        AiBlockListSha256 = $AiBlockListSha256
    }
    foreach ($Key in $StringParams.Keys) {
        $Val = $StringParams[$Key]
        if (-not [string]::IsNullOrWhiteSpace($Val)) {
            $Args += "-$Key"
            $Args += $Val
        }
    }

    $ArgumentString = ($Args | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $TargetPowerShell = Get-PreferredPowerShell

    if ($Need64BitRelaunch -and $NeedElevation) {
        Write-Host 'Requesting administrator permission in 64-bit PowerShell...' -ForegroundColor Yellow
        $Process = Start-Process -FilePath $TargetPowerShell -ArgumentList $ArgumentString -Verb RunAs -PassThru -Wait
        exit $Process.ExitCode
    }

    if ($Need64BitRelaunch) {
        Write-Host 'Relaunching in 64-bit PowerShell...' -ForegroundColor Yellow
        $Process = Start-Process -FilePath $TargetPowerShell -ArgumentList $ArgumentString -PassThru -Wait
        exit $Process.ExitCode
    }

    Write-Host 'Requesting administrator permission...' -ForegroundColor Yellow
    $Process = Start-Process -FilePath $TargetPowerShell -ArgumentList $ArgumentString -Verb RunAs -PassThru -Wait
    exit $Process.ExitCode
}

function Start-SetupLogging {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    try {
        Start-Transcript -Path $TranscriptPath -Force | Out-Null
        $Script:TranscriptStarted = $true
        Write-Host 'Logging started.' -ForegroundColor Green
        Write-Host "Transcript log: $TranscriptPath"
        Write-Host "Error log     : $ErrorLogPath"
    } catch {
        Write-Warning "Failed to start transcript logging. $($_.Exception.Message)"
    }
}

function Stop-SetupLogging {
    if ($Script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $Script:TranscriptStarted = $false
    }
}

function Write-ErrorLog {
    param([Parameter(Mandatory = $true)] $ErrorRecord)
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $Lines = @()
        $Lines += '============================================================'
        $Lines += 'Fatal error'
        $Lines += "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $Lines += '============================================================'
        $Lines += ''
        $Lines += 'Message:'
        $Lines += $ErrorRecord.Exception.Message
        $Lines += ''
        $Lines += 'Exception:'
        $Lines += $ErrorRecord.Exception.GetType().FullName
        $Lines += ''
        $Lines += 'Script stack trace:'
        $Lines += $ErrorRecord.ScriptStackTrace
        $Lines += ''
        $Lines += 'Invocation:'
        $Lines += $ErrorRecord.InvocationInfo.PositionMessage
        $Lines += ''
        $Lines += 'Full error:'
        $Lines += ($ErrorRecord | Format-List * -Force | Out-String)
        Write-LinesUtf8NoBom -Path $ErrorLogPath -Lines $Lines
    } catch {
        Write-Warning 'Failed to write error log.'
    }
}

function Pause-BeforeExit {
    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}

function Write-TextUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Content
    )
    $Directory = [IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines
    )
    $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-TextUtf8NoBom -Path $Path -Content $Content
}

function Write-JsonUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$InputObject,
        [int]$Depth = 30
    )
    $Json = $InputObject | ConvertTo-Json -Depth $Depth
    Write-TextUtf8NoBom -Path $Path -Content ($Json + [Environment]::NewLine)
}

function Convert-ToForwardSlashPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return ($Path -replace '\\', '/')
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet,
        [switch]$StreamOutput
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue) -and -not (Test-Path $FilePath)) {
        throw "Native command not found: $FilePath"
    }

    if (-not $Quiet) {
        Write-Host ("{0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray
    }

    $OldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($StreamOutput -and -not $Quiet) {
            $OutputList = New-Object System.Collections.Generic.List[string]
            & $FilePath @ArgumentList 2>&1 | ForEach-Object {
                if ($null -ne $_) {
                    $Line = $_.ToString()
                    $OutputList.Add($Line) | Out-Null
                    Write-Host $Line
                }
            }
            $ExitCode = [int]$LASTEXITCODE
            $Output = $OutputList.ToArray()
        } else {
            $Output = & $FilePath @ArgumentList 2>&1
            $ExitCode = [int]$LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $OldErrorActionPreference
    }

    if ((-not $Quiet) -and (-not $StreamOutput)) {
        foreach ($Line in $Output) {
            if ($null -ne $Line) { Write-Host $Line }
        }
    }

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output   = @($Output)
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Quiet,
        [switch]$StreamOutput
    )

    $Result = Invoke-NativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -Quiet:$Quiet -StreamOutput:$StreamOutput
    if ($SuccessExitCodes -notcontains $Result.ExitCode) {
        $OutputText = ($Result.Output | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $Message = "Native command failed with exit code $($Result.ExitCode): $FilePath $($ArgumentList -join ' ')"
        if (-not [string]::IsNullOrWhiteSpace($OutputText)) {
            $Message += [Environment]::NewLine + [Environment]::NewLine + 'Command output:' + [Environment]::NewLine + $OutputText
        }
        throw $Message
    }
    return $Result
}

function Invoke-WithMsysRuntimeChecked {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Quiet,
        [switch]$StreamOutput
    )

    $OldPath = $env:Path
    try {
        $MsysUsrBin = Split-Path $MsysBash -Parent
        $env:Path = "$UcrtBin;$MsysUsrBin;$OldPath"
        return Invoke-NativeChecked -FilePath $FilePath -ArgumentList $ArgumentList -SuccessExitCodes $SuccessExitCodes -Quiet:$Quiet -StreamOutput:$StreamOutput
    } finally {
        $env:Path = $OldPath
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$OutFile,
        [int]$MaxAttempts = 3
    )

    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $LastError = $null
    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        try {
            Write-Host "Downloading ($Attempt/$MaxAttempts): $Url"
            $Params = @{ Uri = $Url; OutFile = $OutFile; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
            Invoke-WebRequest @Params
            if (-not (Test-Path $OutFile)) { throw "Download did not create file: $OutFile" }
            return
        } catch {
            $LastError = $_
            if ($Attempt -lt $MaxAttempts) {
                Write-Warning "Download failed. Retrying in 2 seconds. $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }
    }
    throw "Download failed after $MaxAttempts attempts: $Url - $($LastError.Exception.Message)"
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return }
    $Actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($Actual -ine $ExpectedSha256) {
        throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $Actual"
    }
    Write-Host "SHA256 verified: $Path" -ForegroundColor Green
}

function Assert-AuthenticodeValid {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [string[]]$AllowedPublisherKeywords = @()
    )

    if ($SkipSignatureCheck) {
        Write-Warning "Skipping Authenticode check by -SkipSignatureCheck: $Path"
        return
    }

    $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($Extension -notin @('.exe', '.msi', '.msixbundle', '.appx', '.appxbundle')) { return }

    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') {
        throw "Invalid Authenticode signature: $Path ($($Signature.Status))"
    }

    if ($AllowedPublisherKeywords.Count -gt 0) {
        $Subject = $Signature.SignerCertificate.Subject
        $Issuer = $Signature.SignerCertificate.Issuer
        $Combined = "$Subject $Issuer"
        $Ok = $false
        foreach ($Keyword in $AllowedPublisherKeywords) {
            if ($Combined -like "*$Keyword*") { $Ok = $true; break }
        }
        if (-not $Ok) {
            throw "Unexpected signer for ${Path}: $Subject"
        }
    }

    Write-Host "Authenticode signature verified: $Path" -ForegroundColor Green
}

function Download-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$OutFile,
        [string]$ExpectedSha256 = '',
        [string[]]$AllowedPublisherKeywords = @()
    )

    Invoke-DownloadFile -Url $Url -OutFile $OutFile
    Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
    Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
}

function Normalize-PathForCompare {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Add-UserPathFront {
    param([Parameter(Mandatory = $true)] [string]$PathToAdd)

    if (-not (Test-Path $PathToAdd)) {
        Write-Warning "PATH target not found: $PathToAdd"
        return
    }

    $TargetNormalized = Normalize-PathForCompare $PathToAdd
    $Current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $Parts = @()
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $Parts = $Current.Split(';') | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and (Normalize-PathForCompare $_) -ne $TargetNormalized
        }
    }

    $NewPath = ($PathToAdd + ';' + ($Parts -join ';')).TrimEnd(';')
    [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')

    $EnvParts = @()
    if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
        $EnvParts = $env:Path.Split(';') | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and (Normalize-PathForCompare $_) -ne $TargetNormalized
        }
    }
    $env:Path = ($PathToAdd + ';' + ($EnvParts -join ';')).TrimEnd(';')

    Write-Host "PATH added: $PathToAdd" -ForegroundColor Green
}

function Remove-PathEntriesMatching {
    param(
        [Parameter(Mandatory = $true)] [string]$Scope,
        [Parameter(Mandatory = $true)] [scriptblock]$ShouldRemove
    )

    $Current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if ([string]::IsNullOrWhiteSpace($Current)) { return }

    $Removed = New-Object System.Collections.Generic.List[string]
    $Kept = New-Object System.Collections.Generic.List[string]
    foreach ($Part in ($Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $Normalized = Normalize-PathForCompare $Part
        if (& $ShouldRemove $Part $Normalized) {
            $Removed.Add($Part) | Out-Null
        } else {
            $Kept.Add($Part) | Out-Null
        }
    }

    if ($Removed.Count -gt 0) {
        [Environment]::SetEnvironmentVariable('Path', ($Kept.ToArray() -join ';'), $Scope)
        foreach ($PathEntry in $Removed) {
            Write-Host "PATH removed ($Scope): $PathEntry" -ForegroundColor Yellow
        }
    }
}

function Remove-ConflictingPathEntries {
    Write-Section 'Clean conflicting PATH entries'

    $RootNorm = Normalize-PathForCompare $Root
    $MsysRootNorm = Normalize-PathForCompare $MsysRoot
    $PythonDirNorm = Normalize-PathForCompare $PythonDir
    $ToolBinNorm = Normalize-PathForCompare $ToolBin
    $VSCodeBinNorms = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')
    ) | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ }

    $ShouldRemove = {
        param($Original, $Normalized)
        return (
            $Normalized -eq $ToolBinNorm -or
            $Normalized -eq $PythonDirNorm -or
            $Normalized.StartsWith("$PythonDirNorm\") -or
            $Normalized -eq $MsysRootNorm -or
            $Normalized.StartsWith("$MsysRootNorm\") -or
            $Normalized -eq $RootNorm -or
            $VSCodeBinNorms -contains $Normalized
        )
    }.GetNewClosure()

    Remove-PathEntriesMatching -Scope 'User' -ShouldRemove $ShouldRemove
    Remove-PathEntriesMatching -Scope 'Process' -ShouldRemove $ShouldRemove
}

function Test-WingetHelpSupports {
    param(
        [Parameter(Mandatory = $true)] [string]$Command,
        [Parameter(Mandatory = $true)] [string]$Option
    )
    try {
        $HelpText = (& winget $Command --help 2>$null) -join "`n"
        return $HelpText -match [regex]::Escape($Option)
    } catch {
        return $false
    }
}

function Invoke-Winget {
    param([Parameter(Mandatory = $true)] [string[]]$Arguments)
    $Result = Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList $Arguments
    return $Result.ExitCode
}

function Update-WingetClient {
    Write-Section 'Update winget / App Installer'

    if (-not (Test-CommandExists 'winget')) {
        Write-Warning 'winget not found. Continuing with direct installer fallback.'
        return
    }

    Write-Host 'Current winget version:'
    try { Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList @('--version') | Out-Null } catch {}

    $AppInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($AppInstaller) { Write-Host "Current App Installer version: $($AppInstaller.Version)" }

    $Args = @('upgrade', 'Microsoft.AppInstaller', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if (Test-WingetHelpSupports -Command 'upgrade' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }

    try {
        $Exit = Invoke-Winget -Arguments $Args
        if ($Exit -eq 0) {
            Write-Host 'winget update completed or already up to date.' -ForegroundColor Green
        } else {
            Write-Warning "winget update returned exit code $Exit. Continuing with current winget version."
        }
    } catch {
        Write-Warning "winget update failed. Continuing with current winget version. $($_.Exception.Message)"
    }
}

function Install-ByWinget {
    param(
        [Parameter(Mandatory = $true)] [string]$Id,
        [Parameter(Mandatory = $true)] [string]$NameForLog
    )

    if (-not (Test-CommandExists 'winget')) {
        Write-Warning "winget not found. Fallback will be used for $NameForLog."
        return $false
    }

    Write-Host "Installing by winget: $NameForLog"
    $WingetLogDir = Join-Path $LogDir 'winget'
    New-Item -ItemType Directory -Force -Path $WingetLogDir | Out-Null
    $SafeName = $NameForLog -replace '[\\/:*?"<>| ]', '_'
    $WingetLogPath = Join-Path $WingetLogDir "$SafeName-install.log"

    $Args = @(
        'install',
        '--id', $Id,
        '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--log', $WingetLogPath
    )
    if (Test-WingetHelpSupports -Command 'install' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }

    try {
        $ExitCode = Invoke-Winget -Arguments $Args
    } catch {
        Write-Warning "winget crashed while installing $NameForLog. $($_.Exception.Message)"
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
    param(
        [Parameter(Mandatory = $true)] [string]$Id,
        [Parameter(Mandatory = $true)] [string]$NameForLog
    )

    if (-not (Test-CommandExists 'winget')) {
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

    $Args = @('uninstall', '--id', $Id, '--exact', '--silent')
    if (Test-WingetHelpSupports -Command 'uninstall' -Option '--source') { $Args += '--source'; $Args += 'winget' }
    if (Test-WingetHelpSupports -Command 'uninstall' -Option '--accept-source-agreements') { $Args += '--accept-source-agreements' }
    if (Test-WingetHelpSupports -Command 'uninstall' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }

    Write-Host "Uninstalling: $NameForLog"
    try {
        $Exit = Invoke-Winget -Arguments $Args
        if ($Exit -ne 0) { Write-Warning "winget uninstall returned exit code $Exit for $NameForLog. Continuing with folder cleanup." }
    } catch {
        Write-Warning "winget uninstall crashed for $NameForLog. Continuing with folder cleanup. $($_.Exception.Message)"
    }
}

function Get-VSCodeCommandPath {
    $Candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path $Candidate)) { return $Candidate }
    }

    $Cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }

    $Cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }

    return $null
}

function Stop-VSCodeProcesses {
    Write-Host 'Closing VS Code processes if running...'
    foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium')) {
        try { Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
}

function Get-PathHashToken {
    param([Parameter(Mandatory = $true)] [string]$Path)
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Path)
        return [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '').Substring(0, 12)
    } finally {
        $Sha.Dispose()
    }
}

function Backup-PathVerified {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$BackupRoot
    )

    if (-not (Test-Path $Path)) { return $null }
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

    $Leaf = Split-Path -Path $Path -Leaf
    $SafeLeaf = $Leaf -replace '[\\/:*?"<>|]', '_'
    $Hash = Get-PathHashToken -Path $Path
    $Destination = Join-Path $BackupRoot ("{0}-{1}" -f $SafeLeaf, $Hash)

    Write-Host "Backing up: $Path"
    Copy-Item -Path $Path -Destination $Destination -Recurse -Force -ErrorAction Stop
    if (-not (Test-Path $Destination)) { throw "Backup failed: $Path" }

    return $Destination
}

function Backup-And-RemovePathSafe {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$BackupRoot
    )

    if (-not (Test-Path $Path)) { return }
    $BackupTarget = Backup-PathVerified -Path $Path -BackupRoot $BackupRoot
    Write-Host "Removing after verified backup: $Path"
    Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
    Write-Host "Backup saved: $BackupTarget" -ForegroundColor Green
}

function Reset-MSYS2Completely {
    Write-Section 'Reset existing MSYS2'

    Uninstall-WingetPackageIfExists -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'

    if (Test-Path $MsysRoot) {
        $BackupRoot = Join-Path $BackupDir ("msys2-$TimeStamp")
        Backup-And-RemovePathSafe -Path $MsysRoot -BackupRoot $BackupRoot
    } else {
        Write-Host "MSYS2 folder not found: $MsysRoot"
    }
}

function Reset-ManagedPython {
    Write-Section "Reset managed Python $PythonVersion"

    if (Test-Path $PythonDir) {
        $BackupRoot = Join-Path $BackupDir ("python-$TimeStamp")
        Backup-And-RemovePathSafe -Path $PythonDir -BackupRoot $BackupRoot
    } else {
        Write-Host "Managed Python folder not found: $PythonDir"
    }
}

function Reset-VSCodeCompletely {
    Write-Section 'Reset existing VS Code'
    Stop-VSCodeProcesses

    $BackupRoot = Join-Path $BackupDir ("vscode-$TimeStamp")
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Write-Host 'VS Code backup directory:'
    Write-Host "  $BackupRoot"

    $CodeCmdBeforeReset = Get-VSCodeCommandPath
    if ($CodeCmdBeforeReset) {
        try {
            $ExtPath = Join-Path $BackupRoot 'extensions-before-reset.txt'
            $ExtOutput = Invoke-NativeCommand -FilePath $CodeCmdBeforeReset -ArgumentList @('--list-extensions') -Quiet
            Write-LinesUtf8NoBom -Path $ExtPath -Lines ([string[]]$ExtOutput.Output)
            Write-Host 'Extension list backed up.' -ForegroundColor Green
        } catch {
            Write-Warning "Failed to back up extension list. $($_.Exception.Message)"
        }
    }

    foreach ($Path in @((Join-Path $env:APPDATA 'Code'), (Join-Path $env:LOCALAPPDATA 'Code'), (Join-Path $env:USERPROFILE '.vscode'))) {
        Backup-And-RemovePathSafe -Path $Path -BackupRoot $BackupRoot
    }

    Uninstall-WingetPackageIfExists -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code'

    foreach ($Folder in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code')
    )) {
        if ($Folder -and (Test-Path $Folder)) {
            Write-Host "Removing remaining VS Code install folder: $Folder"
            Remove-Item -Path $Folder -Recurse -Force -ErrorAction Stop
        }
    }

    Write-Host 'VS Code reset completed.' -ForegroundColor Green
}

function Install-VSCodeDirect {
    Write-Section 'Install VS Code directly'

    if (Get-VSCodeCommandPath) {
        Write-Host 'VS Code already appears to be installed.' -ForegroundColor Green
        return
    }

    Download-VerifiedFile -Url $VSCodeInstallerUrl -OutFile $VSCodeInstallerPath -AllowedPublisherKeywords @('Microsoft')

    Write-Host 'Installing VS Code directly...'
    $Process = Start-Process -FilePath $VSCodeInstallerPath -ArgumentList @('/VERYSILENT', '/NORESTART', '/MERGETASKS=addcontextmenufiles,addcontextmenufolders,addtopath') -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "VS Code direct installer failed. Exit code: $($Process.ExitCode)" }

    $WaitCount = 0
    while (-not (Get-VSCodeCommandPath) -and $WaitCount -lt 60) {
        Start-Sleep -Seconds 2
        $WaitCount++
    }
    if (-not (Get-VSCodeCommandPath)) { throw 'VS Code installed, but code.cmd was not found.' }

    Write-Host 'VS Code direct install completed.' -ForegroundColor Green
}

function Get-RequiredVSCodeExtensions {
    return @(
        'formulahendry.code-runner',
        'ms-vscode.cpptools',
        'ms-python.python',
        'ms-python.debugpy'
    )
}

function Get-BlockedVSCodeExtensions {
    return @(
        'github.copilot',
        'github.copilot-chat',
        'ms-vscode.vscode-ai',
        'tabnine.tabnine-vscode',
        'codeium.codeium',
        'supermaven.supermaven',
        'continue.continue',
        'sourcegraph.cody-ai',
        'amazonwebservices.amazon-q-vscode'
    )
}

function Get-VSCodeUserSettingsPath {
    return (Join-Path $env:APPDATA 'Code\User\settings.json')
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)] [object]$Object,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [AllowNull()] [object]$Value
    )

    $Property = $Object.PSObject.Properties[$Name]
    if ($Property) {
        $Property.Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-VSCodeAiHiddenSettings {
    Write-Section 'Apply VS Code AI hiding settings'

    $SettingsPath = Get-VSCodeUserSettingsPath
    $SettingsDir = Split-Path $SettingsPath -Parent
    New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null

    $Settings = [pscustomobject]@{}
    if (Test-Path $SettingsPath) {
        try {
            $Raw = Get-Content -Path $SettingsPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($Raw)) {
                $Settings = $Raw | ConvertFrom-Json
            }
        } catch {
            $BackupPathForSettings = "$SettingsPath.before-ai-hide.$TimeStamp"
            Copy-Item -Path $SettingsPath -Destination $BackupPathForSettings -Force -ErrorAction SilentlyContinue
            Write-Warning "Existing VS Code settings.json could not be parsed. Backup created: $BackupPathForSettings"
            $Settings = [pscustomobject]@{}
        }
    }

    $CopilotEnable = [ordered]@{
        '*' = $false
        plaintext = $false
        markdown = $false
        scminput = $false
        cpp = $false
        c = $false
        python = $false
    }

    $SettingsToApply = [ordered]@{
        'chat.commandCenter.enabled' = $false
        'chat.disableAIFeatures' = $true
        'inlineChat.enabled' = $false
        'inlineChat.accessibleDiffView' = 'off'
        'workbench.commandPalette.experimental.enableNaturalLanguageSearch' = $false
        'github.copilot.enable' = $CopilotEnable
        'github.copilot.chat.enabled' = $false
        'github.copilot.editor.enableAutoCompletions' = $false
        'github.copilot.nextEditSuggestions.enabled' = $false
        'github.copilot.inlineSuggest.enable' = $false
        'extensions.ignoreRecommendations' = $true
    }

    foreach ($Key in $SettingsToApply.Keys) {
        Set-ObjectProperty -Object $Settings -Name $Key -Value $SettingsToApply[$Key]
    }

    Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 30
    Write-Host "VS Code AI hiding settings applied: $SettingsPath" -ForegroundColor Green
}

function Remove-BlockedVSCodeExtensions {
    Write-Section 'Remove VS Code AI extensions'

    $CodeCmd = Get-VSCodeCommandPath
    if (-not $CodeCmd) {
        Write-Warning 'code.cmd not found. Skipping VS Code AI extension cleanup.'
        return
    }

    $InstalledResult = Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList @('--list-extensions') -Quiet
    $Installed = @($InstalledResult.Output | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() })
    foreach ($Extension in Get-BlockedVSCodeExtensions) {
        if ($Installed -contains $Extension.ToLowerInvariant()) {
            Write-Host "Removing VS Code AI extension: $Extension"
            Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList @('--uninstall-extension', $Extension) | Out-Null
        }
    }
}

function Warn-IfRequiredVSCodeExtensionsMissing {
    Write-Section 'Check VS Code extensions'

    $CodeCmd = Get-VSCodeCommandPath
    if (-not $CodeCmd) {
        Write-Warning 'VS Code command was not found; extension check skipped.'
        return
    }

    try {
        $InstalledExtensionsResult = Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList @('--list-extensions') -Quiet
        $InstalledExtensions = @($InstalledExtensionsResult.Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
        $Missing = @()
        foreach ($Extension in (Get-RequiredVSCodeExtensions)) {
            if ($InstalledExtensions -notcontains $Extension.ToLowerInvariant()) { $Missing += $Extension }
        }

        if ($Missing.Count -gt 0) {
            Write-Warning ('Required VS Code extensions are missing: ' + ($Missing -join ', '))
            Write-Warning 'Because -KeepVSCode was used and an existing VS Code profile was found, the script did not modify extensions automatically.'
        } else {
            Write-Host 'Required VS Code extensions are already installed.' -ForegroundColor Green
        }
    } catch {
        Write-Warning "Failed to check VS Code extensions. $($_.Exception.Message)"
    }
}

function Install-VSCodeExtensions {
    Write-Section 'Install VS Code extensions'

    $CodeCmd = $null
    $WaitCount = 0
    while (-not $CodeCmd -and $WaitCount -lt 60) {
        $CodeCmd = Get-VSCodeCommandPath
        if (-not $CodeCmd) { Start-Sleep -Seconds 2; $WaitCount++ }
    }
    if (-not $CodeCmd) { throw 'code.cmd not found after VS Code installation.' }

    $Extensions = Get-RequiredVSCodeExtensions

    foreach ($Extension in $Extensions) {
        Write-Host "Installing VS Code extension: $Extension"
        Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList @('--install-extension', $Extension, '--force') | Out-Null
    }

    $InstalledExtensionsResult = Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList @('--list-extensions') -Quiet
    $InstalledExtensions = ($InstalledExtensionsResult.Output -join "`n")
    foreach ($Extension in $Extensions) {
        if ($InstalledExtensions -notmatch [regex]::Escape($Extension)) {
            throw "Extension verification failed: $Extension"
        }
    }

    Write-Host 'VS Code extensions installed and verified.' -ForegroundColor Green
}

function Install-MSYS2Direct {
    Write-Section 'Install MSYS2 directly'

    if (Test-Path $MsysBash) {
        Write-Host "MSYS2 already appears to be installed: $MsysBash" -ForegroundColor Green
        return
    }

    if ((Test-Path $MsysRoot) -and (-not (Test-Path $MsysBash))) {
        $BackupRoot = Join-Path $BackupDir ("msys2-incomplete-$TimeStamp")
        Write-Warning "Incomplete MSYS2 folder found. Moving to backup: $BackupRoot"
        Move-Item -Path $MsysRoot -Destination $BackupRoot -Force
    }

    Download-VerifiedFile -Url $Msys2InstallerUrl -OutFile $Msys2InstallerPath -AllowedPublisherKeywords @()

    Write-Host 'Installing MSYS2 directly...'
    $RootForInstaller = Convert-ToForwardSlashPath $MsysRoot
    $Process = Start-Process -FilePath $Msys2InstallerPath -ArgumentList @('in', '--confirm-command', '--accept-messages', '--root', $RootForInstaller) -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "MSYS2 direct installer failed. Exit code: $($Process.ExitCode)" }

    $WaitCount = 0
    while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) {
        Start-Sleep -Seconds 2
        $WaitCount++
    }
    if (-not (Test-Path $MsysBash)) { throw "MSYS2 installed, but bash.exe was not found: $MsysBash" }

    Write-Host 'MSYS2 direct install completed.' -ForegroundColor Green
}

function New-Msys2TlsErrorMessage {
    param(
        [Parameter(Mandatory = $true)] [string]$Command,
        [Parameter(Mandatory = $true)] [string]$Output
    )

    return @"
MSYS2 pacman failed while verifying an HTTPS certificate.

Command:
  $Command

Detected output:
$Output

This usually happens when antivirus HTTPS inspection, a school/company proxy, or another SSL inspection tool replaces the real MSYS2 certificate with a locally signed certificate.

Fix one of these, then run this script again:
  1. Temporarily disable HTTPS/SSL scanning in the security product.
  2. Use another network, such as a phone hotspot.
  3. Export the proxy/security product root CA certificate and pass it to this script:
     powershell -ExecutionPolicy Bypass -File .\setup-contest-env.ps1 -Msys2CaCertificatePath C:\path\proxy-root.cer

To inspect the current certificate issuer:
  C:\msys64\usr\bin\bash.exe -lc "curl -Iv https://mirror.msys2.org"
"@
}

function Invoke-MsysBashChecked {
    param(
        [Parameter(Mandatory = $true)] [string]$Command,
        [switch]$ExplainMsysTlsErrors
    )

    if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }

    $OldMSYSTEM = $env:MSYSTEM
    $OldCHERE = $env:CHERE_INVOKING
    try {
        $env:MSYSTEM = 'UCRT64'
        $env:CHERE_INVOKING = '1'
        $Result = Invoke-NativeCommand -FilePath $MsysBash -ArgumentList @('-lc', $Command) -StreamOutput
        if ($Result.ExitCode -ne 0) {
            $OutputText = ($Result.Output -join "`n")
            if ($ExplainMsysTlsErrors -and
                ($OutputText -match 'SSL certificate|self-signed certificate|certificate.*verify|schannel|unable to get local issuer certificate')) {
                throw (New-Msys2TlsErrorMessage -Command $Command -Output $OutputText)
            }
            throw "Native command failed with exit code $($Result.ExitCode): $MsysBash -lc $Command"
        }
    } finally {
        if ($null -eq $OldMSYSTEM) { Remove-Item Env:\MSYSTEM -ErrorAction SilentlyContinue } else { $env:MSYSTEM = $OldMSYSTEM }
        if ($null -eq $OldCHERE) { Remove-Item Env:\CHERE_INVOKING -ErrorAction SilentlyContinue } else { $env:CHERE_INVOKING = $OldCHERE }
    }
}

function Install-Msys2CaCertificate {
    if ([string]::IsNullOrWhiteSpace($Msys2CaCertificatePath)) { return }
    if (-not (Test-Path $Msys2CaCertificatePath)) {
        throw "MSYS2 CA certificate file not found: $Msys2CaCertificatePath"
    }
    if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }

    $AnchorDir = Join-Path $MsysRoot 'etc\pki\ca-trust\source\anchors'
    New-Item -ItemType Directory -Force -Path $AnchorDir | Out-Null

    $BaseName = [IO.Path]::GetFileNameWithoutExtension($Msys2CaCertificatePath)
    if ([string]::IsNullOrWhiteSpace($BaseName)) { $BaseName = 'custom-root-ca' }
    $DestPath = Join-Path $AnchorDir "$BaseName.crt"

    Copy-Item -Path $Msys2CaCertificatePath -Destination $DestPath -Force
    Write-Host "Imported MSYS2 CA certificate: $DestPath" -ForegroundColor Green
    Invoke-MsysBashChecked 'update-ca-trust'
}

function Assert-Output {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Actual,
        [Parameter(Mandatory = $true)] [string]$Expected
    )
    $A = $Actual.Trim()
    $E = $Expected.Trim()
    if ($A -ne $E) { throw "$Name test failed. Expected: [$E], Actual: [$A]" }
    Write-Host "$Name test passed: $A" -ForegroundColor Green
}

function Remove-ManagedHostsSectionFromText {
    param([Parameter(Mandatory = $true)] [string]$HostsText)
    $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
    return ([regex]::Replace($HostsText, $Pattern, "`r`n")).TrimEnd()
}

function Restore-HostsManagedSection {
    Write-Section 'Restore hosts managed section'
    if (-not (Test-Path $HostsPath)) { throw "hosts file not found: $HostsPath" }
    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $NewHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    Write-TextUtf8NoBom -Path $HostsPath -Content ($NewHosts + "`r`n")
    Invoke-NativeChecked -FilePath 'ipconfig.exe' -ArgumentList @('/flushdns') -Quiet | Out-Null
    Write-Host 'Managed AI block section removed from hosts.' -ForegroundColor Green
}

function Restore-HostsBackupFull {
    Write-Section 'Restore hosts file from backup'
    if (-not (Test-Path $BackupPath)) { throw "hosts.bak not found: $BackupPath" }
    Copy-Item -Path $HostsPath -Destination "$HostsPath.before-full-restore.$TimeStamp" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $BackupPath -Destination $HostsPath -Force
    Invoke-NativeChecked -FilePath 'ipconfig.exe' -ArgumentList @('/flushdns') -Quiet | Out-Null
    Write-Host "hosts restored from: $BackupPath" -ForegroundColor Green
}

function Test-DomainAllowed {
    param([Parameter(Mandatory = $true)] [string]$Domain)
    $Lower = $Domain.ToLowerInvariant()
    foreach ($Allowed in $AllowList) {
        $A = $Allowed.ToLowerInvariant()
        if ($Lower -eq $A -or $Lower.EndsWith(".$A")) { return $true }
    }
    return $false
}

function Apply-AiHostsBlock {
    Write-Section 'AI hosts block'

    if ($SkipAiBlock) {
        Write-Host 'AI hosts block skipped by -SkipAiBlock.' -ForegroundColor Yellow
        return
    }
    if (-not $EnableAiBlock) {
        Write-Host 'AI hosts block is disabled by default. Use -EnableAiBlock only when hosts changes are allowed.' -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Force -Path $BlockDir | Out-Null
    if (-not (Test-Path $HostsPath)) { throw "hosts file not found: $HostsPath" }

    if (-not [string]::IsNullOrWhiteSpace($AiBlockListPath)) {
        if (-not (Test-Path $AiBlockListPath)) { throw "AI blocklist file not found: $AiBlockListPath" }
        Copy-Item -Path $AiBlockListPath -Destination $RawListPath -Force
    } elseif (-not [string]::IsNullOrWhiteSpace($AiBlockListUrl)) {
        if ([string]::IsNullOrWhiteSpace($AiBlockListSha256) -and -not $AllowUnverifiedAiBlockUrl) {
            throw 'Remote AI blocklist requires -AiBlockListSha256. Use -AllowUnverifiedAiBlockUrl only for temporary testing.'
        }
        Invoke-DownloadFile -Url $AiBlockListUrl -OutFile $RawListPath
        Assert-FileSha256 -Path $RawListPath -ExpectedSha256 $AiBlockListSha256
    } else {
        $DefaultLines = @($DefaultAiBlockDomains | Sort-Object -Unique | ForEach-Object { "0.0.0.0 $_" })
        Write-LinesUtf8NoBom -Path $RawListPath -Lines ([string[]]$DefaultLines)
        Write-Host 'Using built-in default AI blocklist.' -ForegroundColor Yellow
    }

    if (-not (Test-Path $BackupPath)) {
        Copy-Item -Path $HostsPath -Destination $BackupPath -Force
        Write-Host "Backup created: $BackupPath" -ForegroundColor Green
    } else {
        $ExtraBackup = Join-Path (Split-Path $BackupPath -Parent) ("hosts.bak.$TimeStamp")
        Copy-Item -Path $HostsPath -Destination $ExtraBackup -Force
        Write-Host "Extra backup created: $ExtraBackup" -ForegroundColor Yellow
    }

    $RawContent = Get-Content -Path $RawListPath -Raw
    $DomainList = New-Object System.Collections.Generic.List[string]

    foreach ($Line in ($RawContent -split "`r`n|`n|`r")) {
        $Clean = ($Line -replace '#.*$', '').Trim()
        if (-not $Clean) { continue }

        $Parts = $Clean -split '\s+'
        if ($Parts.Count -lt 2) { continue }

        $First = $Parts[0].ToLowerInvariant()
        if ($First -in @('0.0.0.0', '127.0.0.1', '::1')) {
            for ($i = 1; $i -lt $Parts.Count; $i++) {
                $Domain = $Parts[$i].Trim().ToLowerInvariant()
                if ($Domain -and
                    -not (Test-DomainAllowed -Domain $Domain) -and
                    $Domain -notmatch '[/*\\]' -and
                    $Domain -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') {
                    $DomainList.Add($Domain)
                }
            }
        }
    }

    $Domains = @($DomainList | Sort-Object -Unique)
    if ($Domains.Count -eq 0) { throw 'No domains were parsed from the AI blocklist.' }

    Write-LinesUtf8NoBom -Path $ParsedListPath -Lines ([string[]]$Domains)
    Write-Host "Parsed domains: $($Domains.Count)" -ForegroundColor Green

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $BaseHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts

    $BlockLines = New-Object System.Collections.Generic.List[string]
    $BlockLines.Add('')
    $BlockLines.Add($BeginMarker)
    $BlockLines.Add('# Generated by setup-contest-env.fixed.ps1')
    $BlockLines.Add("# Backup: $BackupPath")
    $BlockLines.Add('')

    foreach ($Domain in $Domains) {
        $BlockLines.Add("0.0.0.0 $Domain")
        $BlockLines.Add("::1 $Domain")
    }

    $BlockLines.Add('')
    $BlockLines.Add($EndMarker)
    $BlockLines.Add('')

    $NewHosts = $BaseHosts + "`r`n" + ($BlockLines -join "`r`n") + "`r`n"
    Write-TextUtf8NoBom -Path $HostsPath -Content $NewHosts
    Invoke-NativeChecked -FilePath 'ipconfig.exe' -ArgumentList @('/flushdns') -Quiet | Out-Null

    Write-Host 'AI hosts block applied.' -ForegroundColor Green
    Write-Host 'Close and reopen browsers after this script finishes.' -ForegroundColor Yellow
}

function Install-PythonDirect {
    Write-Section "Install Python $PythonVersion"
    if (-not (Test-Path $PythonExe)) {
        if (-not (Test-Path $PythonInstaller)) {
            Download-VerifiedFile -Url $PythonUrl -OutFile $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation')
        } else {
            Assert-AuthenticodeValid -Path $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation')
        }
        Write-Host "Installing Python $PythonVersion..."
        $Args = "/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 TargetDir=`"$PythonDir`""
        $PythonProcess = Start-Process -FilePath $PythonInstaller -ArgumentList $Args -Wait -PassThru
        if ($PythonProcess.ExitCode -ne 0) { throw "Python installer failed. Exit code: $($PythonProcess.ExitCode)" }
    }
    if (-not (Test-Path $PythonExe)) { throw "Python install failed or python.exe not found: $PythonExe" }
    Invoke-NativeChecked -FilePath $PythonExe -ArgumentList @('--version') | Out-Null
    Write-Host "Python installed: $PythonExe" -ForegroundColor Green
}

function Create-CommandWrappers {
    Write-Section 'Create command wrappers'
    New-Item -ItemType Directory -Force -Path $ToolBin | Out-Null

    $MsysUsrBin = Split-Path $MsysBash -Parent
    $MsysToolPathLine = "set `"PATH=$UcrtBin;$MsysUsrBin;%PATH%`""

    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++14.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++14 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++17.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++17 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++20.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++20 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++.cmd')  @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'gcc.cmd')  @('@echo off', $MsysToolPathLine, "`"$UcrtBin\gcc.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'python3.cmd') @('@echo off', "`"$PythonExe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'cat.cmd') @('@echo off', "`"$MsysCat`" %*")

    Write-Host 'Wrappers created.' -ForegroundColor Green
}

function Configure-Path {
    Write-Section 'Configure PATH'
    Add-UserPathFront $ToolBin
    Add-UserPathFront $UcrtBin
    foreach ($Candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')
    )) {
        if ($Candidate -and (Test-Path $Candidate)) { Add-UserPathFront $Candidate; break }
    }
    Write-Host "MSYS2 UCRT64 bin added to PATH for direct gcc/g++ usage: $UcrtBin" -ForegroundColor Green
    Write-Host 'C:\CPTools\bin remains on PATH for versioned wrappers such as g++14, g++17, g++20, and python3.' -ForegroundColor Green
}

function Create-VSCodeTemplate {
    Write-Section 'Create VS Code CP template'

    if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
        $DesktopPath = Join-Path $env:USERPROFILE 'Desktop'
    }

    $TemplateRoot = Join-Path $DesktopPath 'CP-Template'
    $VSCodeDir = Join-Path $TemplateRoot '.vscode'
    New-Item -ItemType Directory -Force -Path $VSCodeDir | Out-Null

    Write-LinesUtf8NoBom (Join-Path $TemplateRoot 'main.cpp') @(
        '#include <bits/stdc++.h>',
        'using namespace std;',
        '',
        'int main() {',
        '    ios::sync_with_stdio(false);',
        '    cin.tie(nullptr);',
        '    cout << "Hello, C++17 Contest Environment!\n";',
        '    return 0;',
        '}'
    )
    Write-LinesUtf8NoBom (Join-Path $TemplateRoot 'main.c') @(
        '#include <stdio.h>',
        '',
        'int main(void) {',
        '    printf("Hello, C11!\n");',
        '    return 0;',
        '}'
    )
    Write-LinesUtf8NoBom (Join-Path $TemplateRoot 'main.py') @('print("Hello, Python 3!")')

    $MsysProfilePath = $MsysShellCmd
    if (-not (Test-Path $MsysProfilePath)) { $MsysProfilePath = $MsysBash }

    $CodeRunnerExecutorMap = [ordered]@{
        cpp    = 'Set-Location -LiteralPath "$dir"; & g++17 -g -O0 -Wall -Wextra "$fileName" -o "$fileNameWithoutExt.exe"; if ($LASTEXITCODE -eq 0) { & ".\$fileNameWithoutExt.exe" }'
        c      = 'Set-Location -LiteralPath "$dir"; & gcc -std=c11 -g -O0 -Wall -Wextra "$fileName" -o "$fileNameWithoutExt.exe"; if ($LASTEXITCODE -eq 0) { & ".\$fileNameWithoutExt.exe" }'
        python = '& python3 -u "$fullFileName"'
    }

    $WorkspaceSettings = [ordered]@{
        'terminal.integrated.profiles.windows' = [ordered]@{
            'MSYS2 UCRT64' = [ordered]@{
                path = $MsysProfilePath
                args = @('-defterm', '-here', '-no-start', '-ucrt64')
            }
        }
        'terminal.integrated.defaultProfile.windows' = 'PowerShell'
        'C_Cpp.default.compilerPath' = (Join-Path $UcrtBin 'g++.exe')
        'C_Cpp.default.cppStandard' = 'c++17'
        'C_Cpp.default.cStandard' = 'c11'
        'C_Cpp.default.intelliSenseMode' = 'windows-gcc-x64'
        'code-runner.executorMap' = $CodeRunnerExecutorMap
        'code-runner.runInTerminal' = $true
        'code-runner.fileDirectoryAsCwd' = $true
        'code-runner.saveFileBeforeRun' = $true
        'code-runner.clearPreviousOutput' = $true
        'code-runner.showExecutionMessage' = $false
        'code-runner.preserveFocus' = $false
        'code-runner.ignoreSelection' = $true
        'code-runner.enableAppInsights' = $false
        'python.defaultInterpreterPath' = $PythonExe
        'python.terminal.activateEnvironment' = $false
        'debug.openDebug' = 'openOnDebugBreak'
        'chat.commandCenter.enabled' = $false
        'chat.disableAIFeatures' = $true
        'inlineChat.enabled' = $false
        'workbench.commandPalette.experimental.enableNaturalLanguageSearch' = $false
        'github.copilot.enable' = [ordered]@{ '*' = $false; plaintext = $false; markdown = $false; scminput = $false; cpp = $false; c = $false; python = $false }
        'github.copilot.chat.enabled' = $false
        'github.copilot.editor.enableAutoCompletions' = $false
        'github.copilot.nextEditSuggestions.enabled' = $false
        'github.copilot.inlineSuggest.enable' = $false
    }
    Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'settings.json') -InputObject $WorkspaceSettings -Depth 30

    $TasksJson = [ordered]@{
        version = '2.0.0'
        tasks = @(
            [ordered]@{ label = 'build debug C++14'; type = 'shell'; command = 'g++14'; args = @('-g', '-O0', '-Wall', '-Wextra', '${file}', '-o', '${fileDirname}\${fileBasenameNoExtension}.exe'); group = 'build'; problemMatcher = @('$gcc') },
            [ordered]@{ label = 'build debug C++17'; type = 'shell'; command = 'g++17'; args = @('-g', '-O0', '-Wall', '-Wextra', '${file}', '-o', '${fileDirname}\${fileBasenameNoExtension}.exe'); group = [ordered]@{ kind = 'build'; isDefault = $true }; problemMatcher = @('$gcc') },
            [ordered]@{ label = 'build debug C++20'; type = 'shell'; command = 'g++20'; args = @('-g', '-O0', '-Wall', '-Wextra', '${file}', '-o', '${fileDirname}\${fileBasenameNoExtension}.exe'); group = 'build'; problemMatcher = @('$gcc') },
            [ordered]@{ label = 'build debug C11'; type = 'shell'; command = 'gcc'; args = @('-std=c11', '-g', '-O0', '-Wall', '-Wextra', '${file}', '-o', '${fileDirname}\${fileBasenameNoExtension}.exe'); group = 'build'; problemMatcher = @('$gcc') },
            [ordered]@{ label = 'run active executable'; type = 'shell'; command = '${fileDirname}\${fileBasenameNoExtension}.exe'; group = 'test'; problemMatcher = @() },
            [ordered]@{ label = 'run Python3'; type = 'shell'; command = 'python3'; args = @('${file}'); group = 'test'; problemMatcher = @() }
        )
    }
    Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'tasks.json') -InputObject $TasksJson -Depth 30

    $CppDebugSetup = @(
        [ordered]@{ description = 'Enable pretty-printing for gdb'; text = '-enable-pretty-printing'; ignoreFailures = $true }
    )
    $GdbPath = Convert-ToForwardSlashPath (Join-Path $UcrtBin 'gdb.exe')

    $LaunchJson = [ordered]@{
        version = '0.2.0'
        configurations = @(
            [ordered]@{ name = 'Debug C++14 active file'; type = 'cppdbg'; request = 'launch'; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = 'gdb'; miDebuggerPath = $GdbPath; preLaunchTask = 'build debug C++14'; setupCommands = $CppDebugSetup },
            [ordered]@{ name = 'Debug C++17 active file'; type = 'cppdbg'; request = 'launch'; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = 'gdb'; miDebuggerPath = $GdbPath; preLaunchTask = 'build debug C++17'; setupCommands = $CppDebugSetup },
            [ordered]@{ name = 'Debug C++20 active file'; type = 'cppdbg'; request = 'launch'; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = 'gdb'; miDebuggerPath = $GdbPath; preLaunchTask = 'build debug C++20'; setupCommands = $CppDebugSetup },
            [ordered]@{ name = 'Debug C11 active file'; type = 'cppdbg'; request = 'launch'; program = '${fileDirname}\${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $false; MIMode = 'gdb'; miDebuggerPath = $GdbPath; preLaunchTask = 'build debug C11'; setupCommands = $CppDebugSetup },
            [ordered]@{ name = 'Debug Python3 current file'; type = 'debugpy'; request = 'launch'; program = '${file}'; console = 'integratedTerminal'; cwd = '${fileDirname}'; justMyCode = $true }
        )
    }
    Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'launch.json') -InputObject $LaunchJson -Depth 30

    $CppPropertiesJson = [ordered]@{
        configurations = @(
            [ordered]@{
                name = 'MSYS2 UCRT64 GCC'
                includePath = @('${workspaceFolder}/**', (Convert-ToForwardSlashPath (Join-Path $UcrtBin 'include\**')))
                defines = @()
                compilerPath = Convert-ToForwardSlashPath (Join-Path $UcrtBin 'g++.exe')
                cStandard = 'c11'
                cppStandard = 'c++17'
                intelliSenseMode = 'windows-gcc-x64'
            }
        )
        version = 4
    }
    Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'c_cpp_properties.json') -InputObject $CppPropertiesJson -Depth 30

    Write-Host "Template created: $TemplateRoot" -ForegroundColor Green
    return $TemplateRoot
}

function Write-VersionReport {
    Write-Section 'Version report'
    New-Item -ItemType Directory -Force -Path $TestDir | Out-Null
    $VersionReport = @()
    $VersionReport += 'Contest commands'
    $VersionReport += '----------------'
    $VersionReport += 'C++      : g++'
    $VersionReport += 'C        : gcc'
    $VersionReport += 'C++14    : g++14'
    $VersionReport += 'C++17    : g++17'
    $VersionReport += 'C++20    : g++20'
    $VersionReport += 'Python 3 : python3'
    $VersionReport += 'Text     : cat'
    $VersionReport += ''
    $VersionReport += 'g++ version:'
    $GxxVersion = ((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'g++.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += [string]$GxxVersion
    $VersionReport += ''
    $VersionReport += 'gcc version:'
    $GccVersion = ((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'gcc.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += [string]$GccVersion
    $VersionReport += ''
    $VersionReport += 'gdb version:'
    $GdbVersion = ((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'gdb.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += [string]$GdbVersion
    $VersionReport += ''
    $VersionReport += 'python version:'
    $PythonVersionLine = ((Invoke-NativeChecked -FilePath $PythonExe -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += [string]$PythonVersionLine
    $VersionReport += ''
    $VersionReport += 'cat version:'
    $CatVersion = ((Invoke-NativeChecked -FilePath $MsysCat -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += [string]$CatVersion

    $ReportPath = Join-Path $TestDir 'version-report.txt'
    Write-LinesUtf8NoBom -Path $ReportPath -Lines ([string[]]$VersionReport)
    $VersionReport | ForEach-Object { Write-Host $_ }
}

function Run-SmokeTests {
    Write-Section 'Compile and run tests'
    New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

    $Cpp14 = @('#include <bits/stdc++.h>', 'using namespace std;', '', 'int main() {', '    auto f = [](auto x) { return x + 14; };', '    cout << "CPP14 OK " << f(0) << "\n";', '    return 0;', '}')
    Write-LinesUtf8NoBom (Join-Path $TestDir 'cpp14.cpp') $Cpp14
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'g++14.cmd') -ArgumentList @((Join-Path $TestDir 'cpp14.cpp'), '-O2', '-Wall', '-Wextra', '-o', (Join-Path $TestDir 'cpp14.exe')) -StreamOutput | Out-Null
    Assert-Output -Name 'C++14' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'cpp14.exe') -Quiet).Output) -join "`n") -Expected 'CPP14 OK 14'

    $Cpp17 = @('#include <bits/stdc++.h>', 'using namespace std;', '', 'int main() {', '    pair<int, int> p = {17, 0};', '    auto [a, b] = p;', '    cout << "CPP17 OK " << a + b << "\n";', '    return 0;', '}')
    Write-LinesUtf8NoBom (Join-Path $TestDir 'cpp17.cpp') $Cpp17
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'g++17.cmd') -ArgumentList @((Join-Path $TestDir 'cpp17.cpp'), '-O2', '-Wall', '-Wextra', '-o', (Join-Path $TestDir 'cpp17.exe')) -StreamOutput | Out-Null
    Assert-Output -Name 'C++17' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'cpp17.exe') -Quiet).Output) -join "`n") -Expected 'CPP17 OK 17'

    $Cpp20 = @('#include <bits/stdc++.h>', '#include <concepts>', 'using namespace std;', '', 'template <std::integral T>', 'T twice(T x) {', '    return x * 2;', '}', '', 'int main() {', '    cout << "CPP20 OK " << twice(10) << "\n";', '    return 0;', '}')
    Write-LinesUtf8NoBom (Join-Path $TestDir 'cpp20.cpp') $Cpp20
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'g++20.cmd') -ArgumentList @((Join-Path $TestDir 'cpp20.cpp'), '-O2', '-Wall', '-Wextra', '-o', (Join-Path $TestDir 'cpp20.exe')) -StreamOutput | Out-Null
    Assert-Output -Name 'C++20' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'cpp20.exe') -Quiet).Output) -join "`n") -Expected 'CPP20 OK 20'

    $C11 = @('#include <stdio.h>', '', '_Static_assert(__STDC_VERSION__ >= 201112L, "C11 required");', '', 'int main(void) {', '    printf("C11 OK 11\n");', '    return 0;', '}')
    Write-LinesUtf8NoBom (Join-Path $TestDir 'c11.c') $C11
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'gcc.cmd') -ArgumentList @((Join-Path $TestDir 'c11.c'), '-std=c11', '-O2', '-Wall', '-Wextra', '-o', (Join-Path $TestDir 'c11.exe')) -StreamOutput | Out-Null
    Assert-Output -Name 'C11' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'c11.exe') -Quiet).Output) -join "`n") -Expected 'C11 OK 11'

    Write-LinesUtf8NoBom (Join-Path $TestDir 'python3_test.py') @('print("PYTHON3 OK 6")')
    Assert-Output -Name 'Python3' -Actual (((Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'python3.cmd') -ArgumentList @((Join-Path $TestDir 'python3_test.py')) -Quiet).Output) -join "`n") -Expected 'PYTHON3 OK 6'

    Write-LinesUtf8NoBom (Join-Path $TestDir 'text_test.txt') @('TEXT OK')
    Assert-Output -Name 'Text cat' -Actual (((Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'cat.cmd') -ArgumentList @((Join-Path $TestDir 'text_test.txt')) -Quiet).Output) -join "`n") -Expected 'TEXT OK'
}

function Main {
    Assert-SupportedEnvironment
    Ensure-PreferredHostAndAdmin
    Start-SetupLogging

    if ($SkipAiBlock) {
        Write-Warning '-SkipAiBlock is set. AI hosts blocking will not be applied.'
    } elseif (-not $EnableAiBlock) {
        Write-Host 'AI hosts blocking is disabled by default to avoid security software conflicts.' -ForegroundColor Yellow
    }

    if ($RestoreHostsFromBackup) {
        Restore-HostsBackupFull
        return
    }

    if ($RestoreHosts) {
        Restore-HostsManagedSection
        return
    }

    Write-Section '1. Create folders'
    New-Item -ItemType Directory -Force -Path $Root, $ToolBin, $DownloadDir, $TestDir, $LogDir, $BackupDir | Out-Null
    Remove-ConflictingPathEntries

    Write-Section '2. Check winget'
    if (Test-CommandExists 'winget') {
        Write-Host 'winget found. Version:' -ForegroundColor Green
        try { Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList @('--version') | Out-Null } catch {}
        Write-Host 'winget will be used as the primary installer when possible.' -ForegroundColor Green
        try { Update-WingetClient } catch { Write-Warning "winget update failed. Continuing. $($_.Exception.Message)" }
    } else {
        Write-Warning 'winget not found. Direct installers will be used.'
    }

    Write-Section '3. Install VS Code / MSYS2'
    if ($KeepVSCode) {
        Write-Host 'VS Code reset skipped by -KeepVSCode.' -ForegroundColor Yellow
        if (-not (Get-VSCodeCommandPath)) {
            Write-Warning 'VS Code is not currently detected. Installing VS Code and the required extensions because there is no existing profile to preserve.'
            $VSCodeInstalled = Install-ByWinget -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code'
            if (-not $VSCodeInstalled) { Install-VSCodeDirect }
            Install-VSCodeExtensions
        } else {
            Warn-IfRequiredVSCodeExtensionsMissing
        }
    } else {
        Reset-VSCodeCompletely
        $VSCodeInstalled = Install-ByWinget -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code'
        if (-not $VSCodeInstalled) {
            Write-Warning 'VS Code winget install failed. Using direct installer fallback.'
            Install-VSCodeDirect
        }
        Install-VSCodeExtensions
    }
    Remove-BlockedVSCodeExtensions
    Set-VSCodeAiHiddenSettings

    Reset-MSYS2Completely
    $MSYS2Installed = Install-ByWinget -Id 'MSYS2.MSYS2' -NameForLog 'MSYS2'
    if (-not $MSYS2Installed) {
        Write-Warning 'MSYS2 winget install failed. Using direct installer fallback.'
        Install-MSYS2Direct
    }

    $WaitCount = 0
    while (-not (Test-Path $MsysBash) -and $WaitCount -lt 60) {
        Start-Sleep -Seconds 2
        $WaitCount++
    }
    if (-not (Test-Path $MsysBash)) { throw "MSYS2 bash.exe not found: $MsysBash" }
    Write-Host "MSYS2 found: $MsysBash" -ForegroundColor Green

# ...existing code...

Write-Section '4. Install MSYS2 packages'
Invoke-MsysBashChecked 'echo MSYS2 initialized'
Install-Msys2CaCertificate
Invoke-MsysBashChecked 'pacman --noconfirm --disable-download-timeout -Syuu' -ExplainMsysTlsErrors
Invoke-MsysBashChecked 'pacman --noconfirm --disable-download-timeout -Syu' -ExplainMsysTlsErrors

$MsysPackages = @(
    'mingw-w64-ucrt-x86_64-gcc',
    'mingw-w64-ucrt-x86_64-gdb',
    'coreutils'
)
Invoke-MsysBashChecked ("pacman --needed --noconfirm --disable-download-timeout -S " + ($MsysPackages -join ' ')) -ExplainMsysTlsErrors

# ...existing code...
    foreach ($RequiredPath in @((Join-Path $UcrtBin 'g++.exe'), (Join-Path $UcrtBin 'gcc.exe'), (Join-Path $UcrtBin 'gdb.exe'), $MsysCat)) {
        if (-not (Test-Path $RequiredPath)) { throw "Required tool not found: $RequiredPath" }
    }
    Write-Host 'MSYS2 UCRT64 GCC/GDB/coreutils installed.' -ForegroundColor Green

    Reset-ManagedPython
    Install-PythonDirect
    Create-CommandWrappers
    Configure-Path
    $TemplateRoot = $null
    if ($CreateTemplate) {
        $TemplateRoot = Create-VSCodeTemplate
    } else {
        Write-Host 'VS Code CP template creation skipped. Use -CreateTemplate if you want the Desktop\CP-Template sample workspace.' -ForegroundColor Yellow
    }
    Write-VersionReport
    Run-SmokeTests
    Apply-AiHostsBlock

    Write-Section 'Done'
    Write-Host 'All setup and tests completed.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Available commands:'
    Write-Host '  C++      : g++'
    Write-Host '  C        : gcc'
    Write-Host '  C++14    : g++14'
    Write-Host '  C++17    : g++17'
    Write-Host '  C++20    : g++20'
    Write-Host '  Python 3 : python3'
    Write-Host '  Text     : cat'
    Write-Host ''
    if ($TemplateRoot) {
        Write-Host 'VS Code template:'
        Write-Host "  $TemplateRoot"
        Write-Host 'Code Runner: open the CP-Template folder, then Ctrl + Alt + N runs the current file in the integrated terminal.'
        Write-Host 'Debug: F5 starts debugging using .vscode\launch.json.'
        Write-Host ''
    }
    Write-Host "Test directory: $TestDir"
    Write-Host "Version report: $(Join-Path $TestDir 'version-report.txt')"
    Write-Host "hosts backup: $BackupPath"
    Write-Host "Transcript log: $TranscriptPath"
    Write-Host "Error log: $ErrorLogPath"
    Write-Host ''
    Write-Host 'Important: restart PowerShell and VS Code to reload PATH.' -ForegroundColor Yellow
}

$Script:ExitCode = 0
try {
    Main
} catch {
    $Script:ExitCode = 1
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host 'FATAL ERROR' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-ErrorLog -ErrorRecord $_
    Write-Host 'Transcript log:'
    Write-Host "  $TranscriptPath"
    Write-Host 'Error log:'
    Write-Host "  $ErrorLogPath"
} finally {
    Stop-SetupLogging
    Pause-BeforeExit
}

exit $Script:ExitCode
