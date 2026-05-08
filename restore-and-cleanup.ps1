# restore-and-cleanup.ps1
# Standalone script to restore the contest environment.
[CmdletBinding()]
param(
    [string]$Root = "$env:SystemDrive\CPTools",
    [string]$MsysRoot = '',
    [string]$PythonDir = '',
    [string]$PythonVersion = '3.10.11',
    [switch]$Shutdown
)

$ErrorActionPreference = 'Continue'

# Disable QuickEdit mode to prevent accidental script pausing when clicking the console
try {
    $QuickEditCode = @"
    using System;
    using System.Runtime.InteropServices;
    public class ConsoleConfig {
        const int STD_INPUT_HANDLE = -10;
        const uint ENABLE_QUICK_EDIT = 0x0040;
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll")]
        static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll")]
        static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
        public static void DisableQuickEdit() {
            IntPtr consoleHandle = GetStdHandle(STD_INPUT_HANDLE);
            uint consoleMode;
            if (GetConsoleMode(consoleHandle, out consoleMode)) {
                consoleMode &= ~ENABLE_QUICK_EDIT;
                SetConsoleMode(consoleHandle, consoleMode);
            }
        }
    }
"@
    Add-Type -TypeDefinition $QuickEditCode -Language CSharp -ErrorAction SilentlyContinue
    [ConsoleConfig]::DisableQuickEdit()
} catch {}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-SafeRemovalPath {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "FATAL: $Name is empty. Aborting cleanup."
    }

    $Trimmed = $Path.Trim()
    if (-not [System.IO.Path]::IsPathRooted($Trimmed)) {
        throw "FATAL: $Name must be an absolute path. Aborting cleanup. Value: $Path"
    }
    if ($Trimmed -match '^[A-Za-z]:[\\/]*$') {
        throw "FATAL: $Name points to a drive root. Aborting cleanup. Value: $Path"
    }

    $Normalized = Get-NormalizedFullPath -Path $Trimmed
    $CriticalPaths = @(
        (Get-NormalizedFullPath -Path ([System.IO.Path]::GetPathRoot($Normalized))),
        (Get-NormalizedFullPath -Path $env:SystemRoot),
        (Get-NormalizedFullPath -Path $env:USERPROFILE),
        (Get-NormalizedFullPath -Path $env:ProgramData)
    )
    if ($env:ProgramFiles) { $CriticalPaths += (Get-NormalizedFullPath -Path $env:ProgramFiles) }
    if (${env:ProgramFiles(x86)}) { $CriticalPaths += (Get-NormalizedFullPath -Path ${env:ProgramFiles(x86)}) }

    if ($CriticalPaths -contains $Normalized) {
        throw "FATAL: Safe-guard triggered. $Name ($Path) is a critical system path. Aborting cleanup."
    }

    return $Normalized
}

function Test-PathInside {
    param([Parameter(Mandatory = $true)] [string]$ChildPath, [Parameter(Mandatory = $true)] [string]$ParentPath)
    $Child = Get-NormalizedFullPath -Path $ChildPath
    $Parent = Get-NormalizedFullPath -Path $ParentPath
    $ParentPrefix = $Parent + '\'
    return ($Child -ieq $Parent) -or $Child.StartsWith($ParentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Stop-ProcessesUnderPath {
    param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [string[]]$ProcessNames)
    foreach ($ProcName in $ProcessNames) {
        Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.Path -and (Test-PathInside -ChildPath $_.Path -ParentPath $Path)
            } catch { $false }
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Critical Safety Check: Prevent deletion of system drives or critical folders
$Root = Assert-SafeRemovalPath -Path $Root -Name 'Root'
if ([string]::IsNullOrWhiteSpace($MsysRoot)) { $MsysRoot = Join-Path $Root 'msys64' }
$MsysRoot = Assert-SafeRemovalPath -Path $MsysRoot -Name 'MsysRoot'

# Auto-discover PythonDir if not provided
if (-not $PythonDir) {
    $PyDirs = Get-ChildItem -Path $Root -Filter "Python3*" -Directory -ErrorAction SilentlyContinue
    if ($PyDirs) {
        $PythonDir = $PyDirs[0].FullName
        if ($PyDirs[0].Name -match "Python(\d)(\d+)") {
            $PythonVersion = "$($matches[1]).$($matches[2])"
        }
    } else {
        # Fallback to default
        $PythonDir = Join-Path $Root "Python310"
    }
}

$ContestVSCodeRoot = Join-Path $Root 'vscode-contest'
$ManifestPath = Join-Path $ContestVSCodeRoot 'shortcut-manifest.json'
$ProgressActivity = 'Contest Environment Restore & Cleanup'

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Contest Environment Restore & Cleanup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ── Step 1/7: Restore VS Code Shortcuts ──
Write-Progress -Activity $ProgressActivity -Status '[1/7] Restoring VS Code Shortcuts...' -PercentComplete 5
Write-Host '[1/7] Restoring VS Code Shortcuts...' -ForegroundColor Yellow
if (Test-Path -LiteralPath $ManifestPath) {
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    foreach ($Item in $Manifest) {
        try {
            if ($Item.Existed -and $Item.BackupPath -and (Test-Path -LiteralPath $Item.BackupPath)) {
                Copy-Item -LiteralPath $Item.BackupPath -Destination $Item.ShortcutPath -Force
                Write-Host "  Restored: $($Item.ShortcutPath)" -ForegroundColor Green
            }
            elseif (Test-Path -LiteralPath $Item.ShortcutPath) {
                Remove-Item -LiteralPath $Item.ShortcutPath -Force
                Write-Host "  Removed: $($Item.ShortcutPath)" -ForegroundColor Green
            }
        } catch { Write-Warning "  Failed: $($Item.ShortcutPath)" }
    }
} else {
    Write-Host '  No shortcut manifest found. Skipping.' -ForegroundColor Gray
}

# ── Step 2/7: Restore PATH Environment Variable ──
Write-Progress -Activity $ProgressActivity -Status '[2/7] Restoring PATH...' -PercentComplete 20
Write-Host '[2/7] Restoring PATH Environment Variable...' -ForegroundColor Yellow
$BackupDir = Join-Path $Root 'backup'
$PathSnapshots = Get-ChildItem -Path $BackupDir -Filter 'path-*' -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending
if ($PathSnapshots) {
    $LatestSnapshot = $PathSnapshots[0].FullName
    $SnapshotFile = Join-Path $LatestSnapshot 'path-environment-before-cleanup.txt'
    if (Test-Path -LiteralPath $SnapshotFile) {
        $Lines = Get-Content -LiteralPath $SnapshotFile
        if ($Lines.Count -ge 2 -and $Lines[0] -eq 'User PATH:') {
            $UserPath = $Lines[1]
            [Environment]::SetEnvironmentVariable('Path', $UserPath, 'User')
            Write-Host '  User PATH restored.' -ForegroundColor Green
        }
    }
} else {
    Write-Host '  No PATH backup found. Skipping.' -ForegroundColor Gray
}

# ── Step 3/7: Restore AI Hosts Block ──
Write-Progress -Activity $ProgressActivity -Status '[3/7] Restoring AI Hosts...' -PercentComplete 35
Write-Host '[3/7] Restoring AI Hosts Block...' -ForegroundColor Yellow
$AiScript = Join-Path $Root 'ai-hosts-block.ps1'
if (Test-Path -LiteralPath $AiScript) {
    try {
        $Proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$AiScript`" -Restore -Root `"$Root`"" `
            -Wait -PassThru -WindowStyle Hidden
        if ($Proc.ExitCode -eq 0) {
            Write-Host '  AI hosts block removed.' -ForegroundColor Green
        } else {
            Write-Warning "  AI hosts block removal returned exit code $($Proc.ExitCode)."
        }
    } catch {
        Write-Warning "  AI hosts restore failed: $($_.Exception.Message)"
    }
} else {
    Write-Host '  No AI hosts script found. Skipping.' -ForegroundColor Gray
}

# ── Step 4/7: Uninstall Python ──
Write-Progress -Activity $ProgressActivity -Status '[4/7] Uninstalling Python...' -PercentComplete 50
Write-Host '[4/7] Uninstalling Python...' -ForegroundColor Yellow

# Method 1: Try the cached MSI/EXE uninstaller via Windows Registry
$PythonUninstalled = $false
$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($KeyPath in $UninstallKeys) {
    $Entries = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue |
        Where-Object {
            $DisplayName = [string]($_.PSObject.Properties['DisplayName'].Value)
            $InstallLocation = [string]($_.PSObject.Properties['InstallLocation'].Value)
            (-not [string]::IsNullOrWhiteSpace($DisplayName)) -and (
                $DisplayName -like "Python $PythonVersion*" -or
                ($DisplayName -like 'Python 3.10*' -and $InstallLocation -like "$PythonDir*")
            )
        }
    foreach ($Entry in $Entries) {
        $DisplayName = [string]$Entry.PSObject.Properties['DisplayName'].Value
        $UninstallString = [string]$Entry.PSObject.Properties['UninstallString'].Value
        if ($UninstallString) {
            Write-Host "  Found uninstaller: $DisplayName" -ForegroundColor Cyan
            try {
                if ($UninstallString -match 'MsiExec') {
                    $ProductCode = ($UninstallString -replace '.*(\{[0-9A-Fa-f-]+\}).*', '$1')
                    Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $ProductCode /quiet /norestart" -Wait -PassThru | Out-Null
                } else {
                    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$UninstallString`" /quiet" -Wait -PassThru | Out-Null
                }
                $PythonUninstalled = $true
            } catch {
                Write-Warning "  Registry uninstall failed: $($_.Exception.Message)"
            }
        }
    }
}

# Method 2: Use the installer EXE in downloads folder with /uninstall
if (-not $PythonUninstalled) {
    $InstallerPath = Join-Path $Root "downloads\python-$PythonVersion-amd64.exe"
    if (Test-Path -LiteralPath $InstallerPath) {
        Write-Host "  Using cached installer to uninstall: $InstallerPath" -ForegroundColor Cyan
        try {
            $Proc = Start-Process -FilePath $InstallerPath -ArgumentList '/uninstall /quiet' -Wait -PassThru
            if ($Proc.ExitCode -eq 0) { $PythonUninstalled = $true }
        } catch {
            Write-Warning "  Installer uninstall failed: $($_.Exception.Message)"
        }
    }
}

# Method 3: Brute force remove the directory
if (-not $PythonUninstalled -and (Test-Path -LiteralPath $PythonDir)) {
    Write-Host "  Removing Python directory directly: $PythonDir" -ForegroundColor Cyan
    try {
        Remove-Item -LiteralPath $PythonDir -Recurse -Force -ErrorAction Stop
        $PythonUninstalled = $true
        Write-Host '  Python directory removed.' -ForegroundColor Green
    } catch {
        Write-Warning "  Directory removal failed: $($_.Exception.Message)"
    }
}

if ($PythonUninstalled) {
    Write-Host '  Python uninstalled successfully.' -ForegroundColor Green
} else {
    Write-Host '  Python was not found or already uninstalled.' -ForegroundColor Gray
}

# ── Step 5/7: Remove managed MSYS2 ──
Write-Progress -Activity $ProgressActivity -Status '[5/7] Removing managed MSYS2...' -PercentComplete 62
Write-Host '[5/7] Removing managed MSYS2...' -ForegroundColor Yellow

$MsysMarkerPath = Join-Path $MsysRoot '.contestsetup-managed'
if (Test-Path -LiteralPath $MsysMarkerPath) {
    $MsysInstallMethod = ''
    try {
        $MsysMarker = Get-Content -LiteralPath $MsysMarkerPath -Raw | ConvertFrom-Json
        $MsysInstallMethod = [string]$MsysMarker.InstallMethod
    } catch {}

    Stop-ProcessesUnderPath -Path $MsysRoot -ProcessNames @('bash', 'sh', 'pacman', 'g++', 'gcc', 'gdb', 'make', 'mingw32-make')

    if ($MsysInstallMethod -eq 'winget' -and (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
        try {
            Start-Process -FilePath 'winget.exe' -ArgumentList @('uninstall', '--id', 'MSYS2.MSYS2', '--exact', '--silent') -Wait -PassThru -WindowStyle Hidden | Out-Null
        } catch {
            Write-Warning "  winget MSYS2 uninstall failed: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $MsysRoot) {
        try {
            Remove-Item -LiteralPath $MsysRoot -Recurse -Force -ErrorAction Stop
            Write-Host "  Managed MSYS2 folder removed: $MsysRoot" -ForegroundColor Green
        } catch {
            Write-Warning "  Managed MSYS2 removal failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host '  Managed MSYS2 folder was already removed.' -ForegroundColor Gray
    }
} elseif (Test-Path -LiteralPath $MsysRoot) {
    if (Test-PathInside -ChildPath $MsysRoot -ParentPath $Root) {
        Write-Host '  MSYS2 is inside the contest root and will be removed with CPTools.' -ForegroundColor Gray
    } else {
        Write-Host '  MSYS2 marker not found. Skipping external MSYS2 removal to avoid deleting a user installation.' -ForegroundColor Gray
    }
} else {
    Write-Host '  MSYS2 was not found or already removed.' -ForegroundColor Gray
}

# ── Step 6/7: Kill processes & Remove CPTools folder ──
Write-Progress -Activity $ProgressActivity -Status '[6/7] Removing CPTools folder...' -PercentComplete 75
Write-Host '[6/7] Removing CPTools folder...' -ForegroundColor Yellow

# Kill any VS Code or related processes that might lock files
Stop-ProcessesUnderPath -Path $Root -ProcessNames @('Code', 'Code - Insiders', 'node', 'python', 'python3', 'g++', 'gcc', 'gdb', 'bash', 'sh')
Start-Sleep -Seconds 2

# First, try a direct PowerShell removal (works if no file locks)
$DirectRemoveOk = $false
if (Test-Path -LiteralPath $Root) {
    try {
        # Change working directory away from CPTools so we don't lock it
        Set-Location -LiteralPath $env:TEMP

        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
        $DirectRemoveOk = $true
        Write-Host "  CPTools folder removed: $Root" -ForegroundColor Green
    } catch {
        Write-Host "  Direct removal failed (file lock likely). Using deferred batch cleanup..." -ForegroundColor Yellow
    }
}

# Fallback: spawn a detached cmd.exe batch file that retries rmdir
if (-not $DirectRemoveOk -and (Test-Path -LiteralPath $Root)) {
    $TempBat = Join-Path $env:TEMP 'remove-cptools.cmd'
    $BatContent = @"
@echo off
cd /d "%TEMP%"
timeout /t 5 /nobreak >nul
rmdir /s /q "$Root"
if exist "$Root" (
    timeout /t 5 /nobreak >nul
    rmdir /s /q "$Root"
)
del "%~f0"
"@
    [IO.File]::WriteAllText($TempBat, $BatContent, [System.Text.Encoding]::ASCII)
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$TempBat`"" -WindowStyle Hidden
    Write-Host '  Deferred cleanup scheduled. CPTools will be removed shortly.' -ForegroundColor Green
}

# ── Step 7/7: Shutdown computer ──
Write-Progress -Activity $ProgressActivity -Status '[7/7] Finalizing...' -PercentComplete 90
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  All contest environment cleanup completed!' -ForegroundColor Green
Write-Progress -Activity $ProgressActivity -Completed

if (-not $Shutdown) {
    Write-Host '  Shutdown was NOT requested. Exiting.' -ForegroundColor Yellow
} else {
    Write-Host '  Computer will shut down in 30 seconds.' -ForegroundColor Red
    Write-Host '  Close this window to CANCEL shutdown.' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Cyan
    Start-Sleep -Seconds 30
    Stop-Computer -Force
}
