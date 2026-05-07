#requires -Version 5.1
# AI hosts block helper for contest day.
#
# Default:
#   Apply the built-in AI blocklist and schedule automatic restore after 5 hours.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -DurationHours 3
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -Until "2026-05-04 18:00"
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -Restore

[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')] [switch]$Apply,
    [Parameter(ParameterSetName = 'Restore')] [switch]$Restore,

    [Parameter(ParameterSetName = 'Apply')] [int]$DurationHours = 5,
    [Parameter(ParameterSetName = 'Apply')] [string]$Until = '',
    [Parameter(ParameterSetName = 'Apply')] [switch]$NoSchedule,

    [Parameter(ParameterSetName = 'Apply')] [string]$BlockListPath = '',
    [Parameter(ParameterSetName = 'Apply')] [string]$BlockListUrl = '',
    [Parameter(ParameterSetName = 'Apply')] [string]$BlockListSha256 = '',
    [Parameter(ParameterSetName = 'Apply')] [switch]$AllowUnverifiedBlockListUrl,

    [string]$Root = "$env:SystemDrive\CPTools"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BlockDir = Join-Path $Root 'ai-block'
$LogDir = Join-Path $Root 'logs'
$StableScriptPath = Join-Path $BlockDir 'ai-hosts-block.ps1'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$BackupPath = Join-Path $BlockDir 'hosts.before-ai-block.bak'
$RawListPath = Join-Path $BlockDir 'ai-block-hosts.txt'
$ParsedListPath = Join-Path $BlockDir 'ai-block-domains.txt'
$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$TaskName = 'ContestSetupRestoreAiHostsBlock'
$BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
$EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'

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
    'replicate.com',
    'cdn.openai.com',
    'auth.openai.com',
    'auth0.openai.com',
    'events.statsigapi.net',
    'x.com',
    'groq.com',
    'api.claude.ai'
)

function Write-Section {
    param([Parameter(Mandatory = $true)] [string]$Message)
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
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

function Quote-ProcessArgument {
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '""' }
    $Text = [string]$Value
    if ($Text -notmatch '[\s"]') { return $Text }
    $Escaped = $Text -replace '(\\*)"', '$1$1\"'
    $Escaped = $Escaped -replace '(\\+)$', '$1$1'
    return '"' + $Escaped + '"'
}

function Ensure-Admin {
    if (Test-IsAdmin) { return }
    if (-not $PSCommandPath) { throw 'Administrator relaunch requires a saved .ps1 file.' }

    $Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Restore) { $Args += '-Restore' } else { $Args += '-Apply' }
    if ($NoSchedule) { $Args += '-NoSchedule' }
    foreach ($Pair in @{
        DurationHours = $DurationHours
        Until = $Until
        BlockListPath = $BlockListPath
        BlockListUrl = $BlockListUrl
        BlockListSha256 = $BlockListSha256
        Root = $Root
    }.GetEnumerator()) {
        if ($null -ne $Pair.Value -and -not [string]::IsNullOrWhiteSpace([string]$Pair.Value)) {
            $Args += "-$($Pair.Key)"
            $Args += [string]$Pair.Value
        }
    }
    if ($AllowUnverifiedBlockListUrl) { $Args += '-AllowUnverifiedBlockListUrl' }

    $ArgumentString = ($Args | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $ArgumentString -Verb RunAs -Wait
    exit
}

function Write-TextUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content
    )
    $Directory = [IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines
    )
    Write-TextUtf8NoBom -Path $Path -Content (($Lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$OutFile
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
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
}

function Remove-ManagedHostsSectionFromText {
    param([Parameter(Mandatory = $true)] [string]$HostsText)
    $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
    return ([regex]::Replace($HostsText, $Pattern, "`r`n")).TrimEnd()
}

function Get-BlockDomains {
    if (-not [string]::IsNullOrWhiteSpace($BlockListPath)) {
        if (-not (Test-Path $BlockListPath)) { throw "Blocklist file not found: $BlockListPath" }
        Copy-Item -Path $BlockListPath -Destination $RawListPath -Force
    } elseif (-not [string]::IsNullOrWhiteSpace($BlockListUrl)) {
        if ([string]::IsNullOrWhiteSpace($BlockListSha256) -and -not $AllowUnverifiedBlockListUrl) {
            throw 'Remote blocklist requires -BlockListSha256. Use -AllowUnverifiedBlockListUrl only for temporary testing.'
        }
        Invoke-DownloadFile -Url $BlockListUrl -OutFile $RawListPath
        Assert-FileSha256 -Path $RawListPath -ExpectedSha256 $BlockListSha256
    } else {
        Write-LinesUtf8NoBom -Path $RawListPath -Lines ([string[]]($DefaultAiBlockDomains | Sort-Object -Unique | ForEach-Object { "0.0.0.0 $_" }))
    }

    $RawContent = Get-Content -Path $RawListPath -Raw
    $Domains = New-Object System.Collections.Generic.List[string]
    foreach ($Line in ($RawContent -split "`r`n|`n|`r")) {
        $Clean = ($Line -replace '#.*$', '').Trim().ToLowerInvariant()
        if (-not $Clean) { continue }
        foreach ($Part in ($Clean -split '\s+')) {
            if ($Part -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' -and $Part -notmatch '[/*\\]') {
                $Domains.Add($Part) | Out-Null
            }
        }
    }
    return @($Domains | Sort-Object -Unique)
}

function Copy-SelfToStablePath {
    if (-not $PSCommandPath) { return }
    New-Item -ItemType Directory -Force -Path $BlockDir | Out-Null
    $SourcePath = [IO.Path]::GetFullPath($PSCommandPath)
    $DestPath = [IO.Path]::GetFullPath($StableScriptPath)
    if ($SourcePath -ne $DestPath) {
        Copy-Item -Path $PSCommandPath -Destination $StableScriptPath -Force
    }
}

function Get-RestoreTime {
    if (-not [string]::IsNullOrWhiteSpace($Until)) {
        return [datetime]::Parse($Until)
    }
    if ($DurationHours -lt 1) { throw '-DurationHours must be at least 1.' }
    return (Get-Date).AddHours($DurationHours)
}

function Register-AutoRestore {
    if ($NoSchedule) {
        Write-Host 'Auto-restore schedule skipped by -NoSchedule.' -ForegroundColor Yellow
        return
    }

    Copy-SelfToStablePath
    $RestoreTime = Get-RestoreTime
    if ($RestoreTime -le (Get-Date).AddMinutes(1)) {
        throw 'Restore time must be at least 1 minute in the future.'
    }

    $Ps = Get-PreferredPowerShell
    $TaskCommand = "`"$Ps`" -NoProfile -ExecutionPolicy Bypass -File `"$StableScriptPath`" -Restore -Root `"$Root`""
    $DateText = $RestoreTime.ToString('MM/dd/yyyy')
    $TimeText = $RestoreTime.ToString('HH:mm')

    schtasks.exe /Create /TN $TaskName /SC ONCE /SD $DateText /ST $TimeText /TR $TaskCommand /RL HIGHEST /F | Out-Null
    Write-Host "Auto-restore scheduled: $RestoreTime" -ForegroundColor Green
    Write-Host "Task name: $TaskName"
}

function Unregister-AutoRestore {
    try { schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null } catch {}
}

function Apply-AiHostsBlock {
    Write-Section 'Apply AI hosts block'
    New-Item -ItemType Directory -Force -Path $BlockDir, $LogDir | Out-Null
    if (-not (Test-Path $HostsPath)) { throw "hosts file not found: $HostsPath" }

    if (-not (Test-Path $BackupPath)) {
        Copy-Item -Path $HostsPath -Destination $BackupPath -Force
        Write-Host "Backup created: $BackupPath" -ForegroundColor Green
    } else {
        Copy-Item -Path $HostsPath -Destination (Join-Path $BlockDir "hosts.before-ai-block.$TimeStamp.bak") -Force
    }

    $Domains = Get-BlockDomains
    if ($Domains.Count -eq 0) { throw 'No AI domains were parsed from the blocklist.' }
    Write-LinesUtf8NoBom -Path $ParsedListPath -Lines ([string[]]$Domains)

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $BaseHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    $BlockLines = New-Object System.Collections.Generic.List[string]
    $BlockLines.Add($BeginMarker) | Out-Null
    $BlockLines.Add("# Applied: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
    $BlockLines.Add("# Restore: powershell -ExecutionPolicy Bypass -File `"$StableScriptPath`" -Restore") | Out-Null
    foreach ($Domain in $Domains) {
        $BlockLines.Add("0.0.0.0 $Domain") | Out-Null
    }
    $BlockLines.Add($EndMarker) | Out-Null

    Write-TextUtf8NoBom -Path $HostsPath -Content ($BaseHosts + "`r`n" + ($BlockLines.ToArray() -join "`r`n") + "`r`n")
    ipconfig.exe /flushdns | Out-Null
    Register-AutoRestore
    Write-Host "AI hosts block applied. Domains: $($Domains.Count)" -ForegroundColor Green
}

function Restore-AiHostsBlock {
    Write-Section 'Restore AI hosts block'
    if (-not (Test-Path $HostsPath)) { throw "hosts file not found: $HostsPath" }

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $RestoredHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    Write-TextUtf8NoBom -Path $HostsPath -Content ($RestoredHosts + "`r`n")
    ipconfig.exe /flushdns | Out-Null
    Unregister-AutoRestore
    Write-Host 'AI hosts block removed.' -ForegroundColor Green
}

Ensure-Admin

try {
    if ($Restore) {
        Restore-AiHostsBlock
    } else {
        Apply-AiHostsBlock
    }
} catch {
    Write-Host ''
    Write-Host 'FATAL ERROR' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
