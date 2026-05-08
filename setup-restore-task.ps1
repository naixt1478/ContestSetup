# setup-restore-task.ps1

Write-Section 'Setup Automated Restoration Task'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Automated Restoration Task"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Downloading cleanup script..." -PercentComplete 20

$RestoreScriptPath = Join-Path $Root 'restore-and-cleanup.ps1'

# Download the standalone script from the repository
$RestoreScriptUrl = "$RawBase/restore-and-cleanup.ps1"
$OldProgressPref = $ProgressPreference
try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $RestoreScriptUrl -OutFile $RestoreScriptPath -UseBasicParsing
} finally {
    $ProgressPreference = $OldProgressPref
}
if (-not (Test-Path $RestoreScriptPath)) { throw "Failed to download $RestoreScriptPath" }

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Registering Scheduled Task..." -PercentComplete 60

# Build the Task Scheduler action. We pass the parameters that are specific to this environment.
$TaskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$RestoreScriptPath`" -Root `"$Root`" -PythonDir `"$PythonDir`" -PythonVersion `"$PythonVersion`" -Shutdown"
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $TaskArgs
$Trigger = New-ScheduledTaskTrigger -Once -At '2026-05-09T17:10:00'
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest

$TaskName = 'ContestSetupRestoreAndCleanup'
$ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($ExistingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    Write-Host "Scheduled task '$TaskName' updated successfully." -ForegroundColor Green
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    Write-Host "Scheduled task '$TaskName' registered successfully." -ForegroundColor Green
}

Write-Host "Scheduled task 'ContestSetupRestoreAndCleanup' registered to run at 2026-05-09 17:10:00." -ForegroundColor Green
Write-Host "The restore window will be visible when the task runs." -ForegroundColor Yellow
Write-Host "Computer will automatically shut down after cleanup." -ForegroundColor Yellow
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
