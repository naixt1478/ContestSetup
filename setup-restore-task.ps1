# setup-restore-task.ps1

Write-Section 'Setup Automated Restoration Task'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Automated Restoration Task"
Write-Progress -Activity $PA -Status "Creating cleanup script..." -PercentComplete 20

$RestoreScriptPath = Join-Path $Root 'restore-and-cleanup.ps1'

$RestoreScriptContent = @"
# restore-and-cleanup.ps1
# Automatically generated script to restore environment and delete ContestSetup folder.
`$ErrorActionPreference = 'Stop'

`$Root = '$Root'
`$ContestVSCodeRoot = Join-Path `$Root 'vscode-contest'
`$ManifestPath = Join-Path `$ContestVSCodeRoot 'shortcut-manifest.json'

Write-Host "Restoring VS Code Shortcuts..."
if (Test-Path -LiteralPath `$ManifestPath) {
    `$Manifest = Get-Content -LiteralPath `$ManifestPath -Raw | ConvertFrom-Json
    foreach (`$Item in `$Manifest) {
        try {
            if (`$Item.Existed -and `$Item.BackupPath -and (Test-Path -LiteralPath `$Item.BackupPath)) {
                Copy-Item -LiteralPath `$Item.BackupPath -Destination `$Item.ShortcutPath -Force
                Write-Host "Restored shortcut: `$(`$Item.ShortcutPath)"
            }
            elseif (Test-Path -LiteralPath `$Item.ShortcutPath) {
                Remove-Item -LiteralPath `$Item.ShortcutPath -Force
                Write-Host "Removed contest shortcut: `$(`$Item.ShortcutPath)"
            }
        } catch { Write-Warning "Failed to restore shortcut: `$(`$Item.ShortcutPath)" }
    }
}

Write-Host "Restoring PATH Environment Variable..."
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
            Write-Host "Restored User PATH."
        }
    }
}

Write-Host "Restoring AI Hosts Block (if applied)..."
`$AiScript = Join-Path `$Root 'ai-hosts-block.ps1'
if (Test-Path -LiteralPath `$AiScript) {
    & "powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "`$AiScript" -Restore
}

Write-Host "Initiating CPTools removal..."
`$TempScript = Join-Path `$env:TEMP 'remove-cptools.cmd'
Set-Content -Path `$TempScript -Value "@echo off`r`ntimeout /t 5 /nobreak >nul`r`nrmdir /s /q `"`$Root`"`r`ndel `"%~f0`""
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"`$TempScript`"" -WindowStyle Hidden
Write-Host "Cleanup script started. This window will close now."
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
Write-Progress -Activity $PA -Completed
