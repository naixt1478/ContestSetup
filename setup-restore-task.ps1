# setup-restore-task.ps1

Write-Section 'Setup Automated Restoration Task'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Automated Restoration Task"
Write-Progress -Activity $PA -Status "Creating cleanup script..." -PercentComplete 20

$RestoreScriptPath = Join-Path $Root 'restore-and-cleanup.ps1'

# We use a single-quoted here-string for the parts that don't need expansion from the current scope
# to avoid escaping nightmare, but we need $Root to be expanded.
# So we'll use a template approach.

$RestoreScriptContent = @"
# restore-and-cleanup.ps1
# Automatically generated script to restore environment and delete ContestSetup folder.
`$ErrorActionPreference = 'Continue'

`$Root = '$Root'
`$ContestVSCodeRoot = Join-Path `$Root 'vscode-contest'
`$ManifestPath = Join-Path `$ContestVSCodeRoot 'shortcut-manifest.json'
`$ProgressActivity = 'Contest Environment Restore & Cleanup'

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host 'Contest Environment Restore & Cleanup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# 1. Restore VS Code Shortcuts
Write-Progress -Activity `$ProgressActivity -Status '[1/5] Restoring VS Code Shortcuts...' -PercentComplete 10
Write-Host '[1/5] Restoring VS Code Shortcuts...' -ForegroundColor Yellow
if (Test-Path -LiteralPath `$ManifestPath) {
    `$Manifest = Get-Content -LiteralPath `$ManifestPath -Raw | ConvertFrom-Json
    foreach (`$Item in `$Manifest) {
        try {
            if (`$Item.Existed -and `$Item.BackupPath -and (Test-Path -LiteralPath `$Item.BackupPath)) {
                Copy-Item -LiteralPath `$Item.BackupPath -Destination `$Item.ShortcutPath -Force
                Write-Host "  Restored: `$(`$Item.ShortcutPath)" -ForegroundColor Green
            }
            elseif (Test-Path -LiteralPath `$Item.ShortcutPath) {
                Remove-Item -LiteralPath `$Item.ShortcutPath -Force
                Write-Host "  Removed: `$(`$Item.ShortcutPath)" -ForegroundColor Green
            }
        } catch { Write-Warning "  Failed: `$(`$Item.ShortcutPath)" }
    }
} else {
    Write-Host '  No shortcut manifest found. Skipping.' -ForegroundColor Gray
}

# 2. Restore PATH Environment Variable
Write-Progress -Activity `$ProgressActivity -Status '[2/5] Restoring PATH...' -PercentComplete 30
Write-Host '[2/5] Restoring PATH Environment Variable...' -ForegroundColor Yellow
`$BackupDir = Join-Path `$Root 'backup'
`$PathSnapshots = Get-ChildItem -Path `$BackupDir -Filter 'path-*' -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending
if (`$PathSnapshots) {
    `$LatestSnapshot = `$PathSnapshots[0].FullName
    `$SnapshotFile = Join-Path `$LatestSnapshot 'path-environment-before-cleanup.txt'
    if (Test-Path -LiteralPath `$SnapshotFile) {
        `$Lines = Get-Content -LiteralPath `$SnapshotFile
        if (`$Lines.Count -ge 2 -and `$Lines[0] -eq 'User PATH:') {
            `$UserPath = `$Lines[1]
            [Environment]::SetEnvironmentVariable('Path', `$UserPath, 'User')
            Write-Host '  User PATH restored.' -ForegroundColor Green
        }
    }
} else {
    Write-Host '  No PATH backup found. Skipping.' -ForegroundColor Gray
}

# 3. Restore AI Hosts Block
Write-Progress -Activity `$ProgressActivity -Status '[3/5] Restoring AI Hosts...' -PercentComplete 50
Write-Host '[3/5] Restoring AI Hosts Block...' -ForegroundColor Yellow
`$AiScript = Join-Path `$Root 'ai-hosts-block.ps1'
if (Test-Path -LiteralPath `$AiScript) {
    try {
        # Using Start-Process to avoid current session issues and for better error isolation
        `$Proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`$AiScript", "-Restore", "-Root", "`$Root") -Wait -PassThru -WindowStyle Hidden
        if (`$Proc.ExitCode -eq 0) {
            Write-Host '  AI hosts block removed.' -ForegroundColor Green
        } else {
            Write-Warning "  AI hosts block removal returned exit code `$(`$Proc.ExitCode)."
        }
    } catch {
        Write-Warning "  AI hosts restore failed: `$(`$_.Exception.Message)"
    }
} else {
    Write-Host '  No AI hosts script found. Skipping.' -ForegroundColor Gray
}

# 4. Remove CPTools folder
Write-Progress -Activity `$ProgressActivity -Status '[4/5] Removing CPTools folder...' -PercentComplete 70
Write-Host '[4/5] Removing CPTools folder...' -ForegroundColor Yellow
`$TempBat = Join-Path `$env:TEMP 'remove-cptools.cmd'
# Use double-double quotes for the batch file to handle spaces in $Root
`$BatLines = @(
    '@echo off',
    'timeout /t 5 /nobreak >nul',
    'rmdir /s /q "' + `$Root + '"',
    'del "%~f0"'
)
[IO.File]::WriteAllLines(`$TempBat, `$BatLines)

# Correct syntax for Start-Process with ArgumentList as an array to avoid quote hell
Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", `$TempBat) -WindowStyle Hidden
Write-Host '  Cleanup scheduled. CPTools will be removed in 5 seconds.' -ForegroundColor Green

# 5. Shutdown computer
Write-Progress -Activity `$ProgressActivity -Status '[5/5] Shutting down computer...' -PercentComplete 90
Write-Host '[5/5] Shutting down computer in 30 seconds...' -ForegroundColor Yellow
Write-Host ''
Write-Host 'All contest environment cleanup completed!' -ForegroundColor Green
Write-Host 'Computer will shut down in 30 seconds. Close this window to cancel.' -ForegroundColor Red
Write-Progress -Activity `$ProgressActivity -Completed
Start-Sleep -Seconds 30
Stop-Computer -Force
"@

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
