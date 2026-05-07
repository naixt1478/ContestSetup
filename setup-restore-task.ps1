# setup-restore-task.ps1

Write-Section 'Setup Automated Restoration Task'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Automated Restoration Task"
Write-Progress -Activity $PA -Status "Creating cleanup script..." -PercentComplete 20

$RestoreScriptPath = Join-Path $Root 'restore-and-cleanup.ps1'

# Build the Python uninstaller path that will be embedded into the generated script.
# Python was installed via the official installer to $PythonDir, so we can uninstall it
# silently using the same installer or via the cached uninstall info.
$PythonDirEscaped = $PythonDir -replace "'", "''"
$PythonVersionEscaped = $PythonVersion -replace "'", "''"

$RestoreScriptContent = @'
# restore-and-cleanup.ps1
# Automatically generated script to restore the contest environment.
$ErrorActionPreference = 'Continue'

'@ + @"

`$Root = '$Root'
`$PythonDir = '$PythonDirEscaped'
`$PythonVersion = '$PythonVersionEscaped'

"@ + @'

$ContestVSCodeRoot = Join-Path $Root 'vscode-contest'
$ManifestPath = Join-Path $ContestVSCodeRoot 'shortcut-manifest.json'
$ProgressActivity = 'Contest Environment Restore & Cleanup'

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Contest Environment Restore & Cleanup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ── Step 1/6: Restore VS Code Shortcuts ──
Write-Progress -Activity $ProgressActivity -Status '[1/6] Restoring VS Code Shortcuts...' -PercentComplete 5
Write-Host '[1/6] Restoring VS Code Shortcuts...' -ForegroundColor Yellow
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

# ── Step 2/6: Restore PATH Environment Variable ──
Write-Progress -Activity $ProgressActivity -Status '[2/6] Restoring PATH...' -PercentComplete 20
Write-Host '[2/6] Restoring PATH Environment Variable...' -ForegroundColor Yellow
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

# ── Step 3/6: Restore AI Hosts Block ──
Write-Progress -Activity $ProgressActivity -Status '[3/6] Restoring AI Hosts...' -PercentComplete 35
Write-Host '[3/6] Restoring AI Hosts Block...' -ForegroundColor Yellow
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

# ── Step 4/6: Uninstall Python ──
Write-Progress -Activity $ProgressActivity -Status '[4/6] Uninstalling Python...' -PercentComplete 50
Write-Host '[4/6] Uninstalling Python...' -ForegroundColor Yellow

# Method 1: Try the cached MSI/EXE uninstaller via Windows Registry
$PythonUninstalled = $false
$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($KeyPath in $UninstallKeys) {
    $Entries = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "Python $PythonVersion*" -or ($_.DisplayName -like 'Python 3.10*' -and $_.InstallLocation -like "$PythonDir*") }
    foreach ($Entry in $Entries) {
        $UninstallString = $Entry.UninstallString
        if ($UninstallString) {
            Write-Host "  Found uninstaller: $($Entry.DisplayName)" -ForegroundColor Cyan
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
    } catch {
        Write-Warning "  Could not remove Python directory: $($_.Exception.Message)"
    }
}

if ($PythonUninstalled) {
    Write-Host '  Python uninstalled.' -ForegroundColor Green
} else {
    Write-Host '  Python was not found or already uninstalled.' -ForegroundColor Gray
}

# ── Step 5/6: Kill processes & Remove CPTools folder ──
Write-Progress -Activity $ProgressActivity -Status '[5/6] Removing CPTools folder...' -PercentComplete 70
Write-Host '[5/6] Removing CPTools folder...' -ForegroundColor Yellow

# Kill any VS Code or related processes that might lock files
foreach ($ProcName in @('Code', 'Code - Insiders', 'node', 'python', 'python3', 'g++', 'gcc', 'gdb')) {
    Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -like "$Root*" } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}
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

# ── Step 6/6: Shutdown computer ──
Write-Progress -Activity $ProgressActivity -Status '[6/6] Shutting down computer...' -PercentComplete 90
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  All contest environment cleanup completed!' -ForegroundColor Green
Write-Host '  Computer will shut down in 30 seconds.' -ForegroundColor Red
Write-Host '  Close this window to CANCEL shutdown.' -ForegroundColor Red
Write-Host '============================================================' -ForegroundColor Cyan
Write-Progress -Activity $ProgressActivity -Completed
Start-Sleep -Seconds 30
Stop-Computer -Force
'@

Write-TextUtf8NoBom -Path $RestoreScriptPath -Content $RestoreScriptContent

Write-Progress -Activity $PA -Status "Registering Scheduled Task..." -PercentComplete 60
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RestoreScriptPath`""
$Trigger = New-ScheduledTaskTrigger -Once -At '2026-05-09T17:10:00'
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

Write-Host "Scheduled task 'ContestSetupRestoreAndCleanup' registered to run at 2026-05-09 17:10:00." -ForegroundColor Green
Write-Host "The restore window will be visible when the task runs." -ForegroundColor Yellow
Write-Host "Computer will automatically shut down after cleanup." -ForegroundColor Yellow
Write-Progress -Activity $PA -Completed
