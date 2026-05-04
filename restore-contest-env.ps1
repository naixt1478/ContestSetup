#requires -Version 5.1
# Restore script for the contest environment installer.
#
# Restores the latest backups created under C:\CPTools\backup and removes
# paths/configuration managed by setup-contest-env.ps1.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\restore-contest-env.ps1
#   powershell -ExecutionPolicy Bypass -File .\restore-contest-env.ps1 -WhatIf
#   powershell -ExecutionPolicy Bypass -File .\restore-contest-env.ps1 -SkipVSCode -SkipMSYS2

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

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $Root 'backup'
$RestoreBackupRoot = Join-Path $BackupDir "restore-current-$TimeStamp"
$ToolBin = Join-Path $Root 'bin'
$PathBin = Join-Path $Root 'path'
$UcrtBin = Join-Path $MsysRoot 'ucrt64\bin'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsBackupPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.bak'
$BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
$EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
$AiTaskName = 'ContestSetupRestoreAiHostsBlock'

$VersionParts = $PythonVersion -split '\.'
if ($VersionParts.Count -lt 2) { throw "Invalid PythonVersion: $PythonVersion" }
$PythonDir = Join-Path $Root ("Python{0}{1}" -f $VersionParts[0], $VersionParts[1])

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
    foreach ($Name in @('SkipVSCode', 'SkipMSYS2', 'SkipPython', 'SkipPath', 'SkipHosts', 'NoPause')) {
        if (Get-Variable -Name $Name -ValueOnly) { $Args += "-$Name" }
    }
    foreach ($Pair in @{ Root = $Root; MsysRoot = $MsysRoot; PythonVersion = $PythonVersion }.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Pair.Value)) {
            $Args += "-$($Pair.Key)"
            $Args += [string]$Pair.Value
        }
    }
    if ($WhatIfPreference) { $Args += '-WhatIf' }

    $ArgumentString = ($Args | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $ArgumentString -Verb RunAs -Wait
    exit
}

function Stop-VSCodeProcesses {
    foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium')) {
        try { Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-LatestBackupRoot {
    param([Parameter(Mandatory = $true)] [string]$Prefix)
    if (-not (Test-Path $BackupDir)) { return $null }
    return Get-ChildItem -Path $BackupDir -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-BackupChildByLeaf {
    param(
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [Parameter(Mandatory = $true)] [string]$Leaf
    )
    $SafeLeaf = $Leaf -replace '[\\/:*?"<>|]', '_'
    return Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$SafeLeaf-*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-BackupSourceFromManifest {
    param(
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $ManifestPath = Join-Path $BackupRoot 'backup-manifest.tsv'
    if (-not (Test-Path $ManifestPath)) { return $null }

    $DestinationNorm = Normalize-PathForCompare $Destination
    $Entries = Get-Content -Path $ManifestPath -ErrorAction SilentlyContinue
    foreach ($Entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($Entry)) { continue }
        $Parts = $Entry -split "`t", 2
        if ($Parts.Count -ne 2) { continue }

        $Source = $Parts[0]
        $OriginalDestination = $Parts[1]
        if ((Normalize-PathForCompare $OriginalDestination) -eq $DestinationNorm -and (Test-Path $Source)) {
            return (Get-Item -Path $Source)
        }
    }

    return $null
}

function Get-VSCodeCodeBackupForDestination {
    param(
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $Candidates = @(Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Code-*' } |
        Sort-Object LastWriteTime -Descending)
    if ($Candidates.Count -eq 0) { return $null }

    $DestinationNorm = (Normalize-PathForCompare $Destination)
    $AppDataCodeNorm = Normalize-PathForCompare (Join-Path $env:APPDATA 'Code')
    if ($DestinationNorm -eq $AppDataCodeNorm) {
        $UserDataCandidate = $Candidates | Where-Object { Test-Path (Join-Path $_.FullName 'User') } | Select-Object -First 1
        if ($UserDataCandidate) { return $UserDataCandidate }
    } else {
        $LocalDataCandidate = $Candidates | Where-Object { -not (Test-Path (Join-Path $_.FullName 'User')) } | Select-Object -First 1
        if ($LocalDataCandidate) { return $LocalDataCandidate }
    }

    return ($Candidates | Select-Object -First 1)
}

function Backup-CurrentPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    if (-not (Test-Path $Path)) { return }
    $Leaf = Split-Path -Path $Path -Leaf
    $Dest = Join-Path $RestoreBackupRoot ($Leaf -replace '[\\/:*?"<>|]', '_')
    if ($PSCmdlet.ShouldProcess($Path, "backup current path to $Dest")) {
        New-Item -ItemType Directory -Force -Path $RestoreBackupRoot | Out-Null
        Copy-Item -Path $Path -Destination $Dest -Recurse -Force
        Write-Host "Current path backed up: $Dest" -ForegroundColor Green
    }
}

function Restore-PathFromBackup {
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Backup-CurrentPath -Path $Destination
    if (Test-Path $Destination) {
        if ($PSCmdlet.ShouldProcess($Destination, 'remove current path before restore')) {
            Remove-Item -Path $Destination -Recurse -Force
        }
    }
    $Parent = Split-Path -Path $Destination -Parent
    if ($PSCmdlet.ShouldProcess($Destination, "restore from $Source")) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
        Copy-Item -Path $Source -Destination $Destination -Recurse -Force
        Write-Host "Restored: $Destination" -ForegroundColor Green
    }
}

function Restore-VSCode {
    Write-Section 'Restore VS Code'
    Stop-VSCodeProcesses
    $BackupRoot = Get-LatestBackupRoot -Prefix 'vscode-'
    if (-not $BackupRoot) {
        Write-Warning 'No VS Code backup folder found.'
        return
    }

    $Targets = @(
        @{ Leaf = 'Code'; Destination = (Join-Path $env:APPDATA 'Code') },
        @{ Leaf = 'Code'; Destination = (Join-Path $env:LOCALAPPDATA 'Code') },
        @{ Leaf = '.vscode'; Destination = (Join-Path $env:USERPROFILE '.vscode') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path $env:ProgramFiles 'Microsoft VS Code') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code') }
    )

    foreach ($Target in $Targets) {
        $Source = Get-BackupSourceFromManifest -BackupRoot $BackupRoot.FullName -Destination $Target.Destination
        if (-not $Source) {
            if ($Target.Leaf -eq 'Code') {
                $Source = Get-VSCodeCodeBackupForDestination -BackupRoot $BackupRoot.FullName -Destination $Target.Destination
            } else {
                $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf $Target.Leaf
            }
        }
        if ($Source) {
            Restore-PathFromBackup -Source $Source.FullName -Destination $Target.Destination
        }
    }
}

function Restore-MSYS2 {
    Write-Section 'Restore MSYS2'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'msys2-'
    if (-not $BackupRoot) {
        Write-Warning 'No MSYS2 backup folder found.'
        return
    }
    $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf (Split-Path $MsysRoot -Leaf)
    if (-not $Source) {
        Write-Warning "No MSYS2 folder backup found under: $($BackupRoot.FullName)"
        return
    }
    Restore-PathFromBackup -Source $Source.FullName -Destination $MsysRoot
}

function Restore-Python {
    Write-Section 'Restore managed Python'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'python-'
    if (-not $BackupRoot) {
        Write-Warning 'No Python backup folder found.'
        return
    }
    $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf (Split-Path $PythonDir -Leaf)
    if (-not $Source) {
        Write-Warning "No Python folder backup found under: $($BackupRoot.FullName)"
        return
    }
    Restore-PathFromBackup -Source $Source.FullName -Destination $PythonDir
}

function Remove-ManagedHostsSectionFromText {
    param([Parameter(Mandatory = $true)] [string]$HostsText)
    $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
    return ([regex]::Replace($HostsText, $Pattern, "`r`n")).TrimEnd()
}

function Restore-Hosts {
    Write-Section 'Restore hosts'
    if (-not (Test-Path $HostsPath)) {
        Write-Warning "hosts file not found: $HostsPath"
        return
    }

    Backup-CurrentPath -Path $HostsPath
    if (Test-Path $HostsBackupPath) {
        Write-Host "Full hosts backup kept untouched: $HostsBackupPath" -ForegroundColor Yellow
    }

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $NewHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    if ($PSCmdlet.ShouldProcess($HostsPath, 'remove managed AI hosts section')) {
        $Encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($HostsPath, ($NewHosts + "`r`n"), $Encoding)
        ipconfig.exe /flushdns | Out-Null
        Write-Host 'Managed AI hosts section removed.' -ForegroundColor Green
    }

    try {
        if ($PSCmdlet.ShouldProcess($AiTaskName, 'delete scheduled AI hosts restore task')) {
            schtasks.exe /Delete /TN $AiTaskName /F | Out-Null
        }
    } catch {}
}

function Restore-PathEnvironment {
    Write-Section 'Restore PATH'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'path-'
    if (-not $BackupRoot) {
        Write-Warning 'No PATH backup folder found. Removing known contest paths instead.'
        Remove-KnownContestPathEntries
        return
    }

    $Snapshot = Join-Path $BackupRoot.FullName 'path-environment-before-cleanup.txt'
    if (-not (Test-Path $Snapshot)) {
        Write-Warning "PATH snapshot not found: $Snapshot"
        Remove-KnownContestPathEntries
        return
    }

    $Lines = Get-Content -Path $Snapshot
    $UserPathIndex = [Array]::IndexOf($Lines, 'User PATH:')
    if ($UserPathIndex -ge 0 -and $Lines.Count -gt ($UserPathIndex + 1)) {
        $OriginalUserPath = $Lines[$UserPathIndex + 1]
        if ($PSCmdlet.ShouldProcess('User PATH', 'restore from snapshot')) {
            [Environment]::SetEnvironmentVariable('Path', $OriginalUserPath, 'User')
            $env:Path = $OriginalUserPath
            Write-Host 'User PATH restored from snapshot.' -ForegroundColor Green
        }
    } else {
        Remove-KnownContestPathEntries
    }
}

function Normalize-PathForCompare {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Remove-KnownContestPathEntries {
    $Known = @(
        $ToolBin,
        $PathBin,
        $UcrtBin,
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')
    ) | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ }

    $Current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($Current)) { return }
    $Parts = $Current.Split(';') | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and ($Known -notcontains (Normalize-PathForCompare $_))
    }
    if ($PSCmdlet.ShouldProcess('User PATH', 'remove known contest paths')) {
        [Environment]::SetEnvironmentVariable('Path', ($Parts -join ';'), 'User')
        $env:Path = ($Parts -join ';')
        Write-Host 'Known contest PATH entries removed.' -ForegroundColor Green
    }
}

function Pause-BeforeExit {
    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}

Ensure-Admin

try {
    if (-not $SkipHosts) { Restore-Hosts }
    if (-not $SkipVSCode) { Restore-VSCode }
    if (-not $SkipMSYS2) { Restore-MSYS2 }
    if (-not $SkipPython) { Restore-Python }
    if (-not $SkipPath) { Restore-PathEnvironment }

    Write-Section 'Done'
    Write-Host 'Contest environment restore completed.' -ForegroundColor Green
    Write-Host "Current-state backup folder: $RestoreBackupRoot"
    Write-Host 'Restart PowerShell and VS Code to reload PATH.' -ForegroundColor Yellow
} catch {
    Write-Host ''
    Write-Host 'FATAL ERROR' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    Pause-BeforeExit
}
