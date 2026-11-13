#requires -Version 5.1
# setup-restore-task.ps1
# ContestSetup v2.0 -- Automated Restoration & Exam Schedule Task Registration
# Default Exam Window: Monday, November 23, 2026, 19:00 ~ 20:30 (Auto-Restore: 2026-11-23T20:30:00 KST)

Write-Section 'Setup Automated Restoration Task'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Automated Restoration Task"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Staging cleanup script...' -PercentComplete 20

function Format-ScheduledTaskArg
{
  param([AllowNull()] [object]$Value)
  if (Get-Command Quote-ProcessArgument -ErrorAction SilentlyContinue)
  {
    return (Quote-ProcessArgument $Value)
  }
  if ($null -eq $Value) { return '""' }
  $Text = [string]$Value
  if ([string]::IsNullOrEmpty($Text)) { return '""' }
  if ($Text -notmatch '[\s"]') { return $Text }
  $Escaped = $Text -replace '(\\*)"', '$1$1\"'
  $Escaped = $Escaped -replace '(\\+)$', '$1$1'
  return '"' + $Escaped + '"'
}

function Normalize-DirectoryArgPath
{
  param([AllowNull()] [string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $Full = [IO.Path]::GetFullPath($PathValue.Trim())
  if ($Full -match '^[A-Za-z]:\\$') { return $Full }
  return $Full.TrimEnd('\', '/')
}

$ExamStartValue = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'ExamStart' -DefaultValue '2026-11-23T19:00:00' -EnvVar 'CONTEST_EXAM_START')
} elseif (Get-Variable -Name 'ExamStart' -ErrorAction SilentlyContinue) {
  [string]$ExamStart
} else {
  '2026-11-23T19:00:00'
}

$ExamEndValue = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'ExamEnd' -DefaultValue '2026-11-23T20:30:00' -EnvVar 'CONTEST_EXAM_END')
} elseif (Get-Variable -Name 'ExamEnd' -ErrorAction SilentlyContinue) {
  [string]$ExamEnd
} else {
  '2026-11-23T20:30:00'
}

$RestoreAtValue = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'RestoreAt' -DefaultValue '2026-11-23T20:30:00' -EnvVar 'CONTEST_RESTORE_AT')
} elseif (Get-Variable -Name 'RestoreAt' -ErrorAction SilentlyContinue) {
  [string]$RestoreAt
} else {
  '2026-11-23T20:30:00'
}

$MsysRootValue = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'MsysRoot' -DefaultValue "$env:SystemDrive\msys64" -EnvVar 'CONTEST_MSYS_ROOT')
} elseif (Get-Variable -Name 'MsysRoot' -ErrorAction SilentlyContinue) {
  [string]$MsysRoot
} else {
  "$env:SystemDrive\msys64"
}

$SkipRestoreTask = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [bool](Get-ContestVariableValue -Name 'NoRestoreTask' -DefaultValue $false -EnvVar 'CONTEST_NO_RESTORE_TASK')
} elseif (Get-Variable -Name 'NoRestoreTask' -ErrorAction SilentlyContinue) {
  [bool]$NoRestoreTask
} else {
  $false
}

$SkipRestoreShutdown = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [bool](Get-ContestVariableValue -Name 'NoRestoreShutdown' -DefaultValue $false -EnvVar 'CONTEST_NO_RESTORE_SHUTDOWN')
} elseif (Get-Variable -Name 'NoRestoreShutdown' -ErrorAction SilentlyContinue) {
  [bool]$NoRestoreShutdown
} else {
  $false
}

$DeferAiBlockValue = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [bool](Get-ContestVariableValue -Name 'DeferAiBlockUntilExamStart' -DefaultValue $false -EnvVar 'CONTEST_DEFER_AI_BLOCK')
} elseif (Get-Variable -Name 'DeferAiBlockUntilExamStart' -ErrorAction SilentlyContinue) {
  [bool]$DeferAiBlockUntilExamStart
} elseif ($env:CONTEST_DEFER_AI_BLOCK -match '^(1|true|yes)$') {
  $true
} else {
  $false
}

$ExplicitTargetSid = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'TargetUserSid' -DefaultValue '' -EnvVar 'CONTEST_TARGET_USER_SID')
} elseif (Get-Variable -Name 'TargetUserSid' -ErrorAction SilentlyContinue) {
  [string]$TargetUserSid
} else {
  ''
}

$ExplicitTargetProfile = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [string](Get-ContestVariableValue -Name 'TargetUserProfile' -DefaultValue '' -EnvVar 'CONTEST_TARGET_USER_PROFILE')
} elseif (Get-Variable -Name 'TargetUserProfile' -ErrorAction SilentlyContinue) {
  [string]$TargetUserProfile
} else {
  ''
}

$ResolvedTargetSid = $ExplicitTargetSid
$ResolvedTargetProfile = $ExplicitTargetProfile
if (Get-Command Resolve-ContestTargetUser -ErrorAction SilentlyContinue)
{
  try
  {
    $TargetUserObj = Resolve-ContestTargetUser -ExplicitSid $ExplicitTargetSid -ExplicitProfile $ExplicitTargetProfile
    if ($null -ne $TargetUserObj)
    {
      if ($null -ne $TargetUserObj.PSObject.Properties['Sid'] -and -not [string]::IsNullOrWhiteSpace([string]$TargetUserObj.Sid) -and [string]$TargetUserObj.Sid -ne 'S-1-5-18')
      {
        $ResolvedTargetSid = [string]$TargetUserObj.Sid
      }
      if ($null -ne $TargetUserObj.PSObject.Properties['ProfilePath'] -and -not [string]::IsNullOrWhiteSpace([string]$TargetUserObj.ProfilePath))
      {
        $ResolvedTargetProfile = [string]$TargetUserObj.ProfilePath
      }
    }
  }
  catch {}
}

if ([string]::IsNullOrWhiteSpace($ResolvedTargetSid))
{
  try
  {
    $CurIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($CurIdentity -and $CurIdentity.User -and $CurIdentity.User.Value -ne 'S-1-5-18')
    {
      $ResolvedTargetSid = $CurIdentity.User.Value
      if ([string]::IsNullOrWhiteSpace($ResolvedTargetProfile)) { $ResolvedTargetProfile = $env:USERPROFILE }
    }
  }
  catch {}
}

$RootClean = Normalize-DirectoryArgPath -PathValue $Root
$MsysRootClean = Normalize-DirectoryArgPath -PathValue $MsysRootValue
$PythonDirClean = if (Get-Variable -Name 'PythonDir' -ErrorAction SilentlyContinue) { Normalize-DirectoryArgPath -PathValue ([string]$PythonDir) } else { '' }
$TargetProfileClean = Normalize-DirectoryArgPath -PathValue $ResolvedTargetProfile

if (Get-Command Update-ContestStateManifest -ErrorAction SilentlyContinue)
{
  try
  {
    $StateUpdates = @{ MsysRoot = $MsysRootClean }
    if (-not [string]::IsNullOrWhiteSpace($ResolvedTargetSid)) { $StateUpdates['TargetUserSid'] = $ResolvedTargetSid }
    if (-not [string]::IsNullOrWhiteSpace($TargetProfileClean)) { $StateUpdates['TargetUserProfile'] = $TargetProfileClean }
    Update-ContestStateManifest -Properties $StateUpdates
  }
  catch {}
}

$RestoreScriptPath = Join-Path $RootClean 'restore-and-cleanup.ps1'
New-Item -ItemType Directory -Force -Path $RootClean | Out-Null

# Prefer local or staged restore-and-cleanup.ps1 before falling back to network download
$CandidateRestoreSources = @()
if ($PSScriptRoot) { $CandidateRestoreSources += (Join-Path $PSScriptRoot 'restore-and-cleanup.ps1') }
if (Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue) { $CandidateRestoreSources += (Join-Path $ScriptStageDir 'restore-and-cleanup.ps1') }

$StagedRestoreFromLocal = $false
foreach ($Candidate in $CandidateRestoreSources)
{
  if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate))
  {
    if ([IO.Path]::GetFullPath($Candidate) -ine [IO.Path]::GetFullPath($RestoreScriptPath))
    {
      Copy-Item -LiteralPath $Candidate -Destination $RestoreScriptPath -Force
    }
    $StagedRestoreFromLocal = $true
    Write-Host "Staged restore-and-cleanup.ps1 from $Candidate" -ForegroundColor Green
    break
  }
}

if (-not $StagedRestoreFromLocal)
{
  $RestoreScriptUrl = "$RawBase/restore-and-cleanup.ps1"
  if (Get-Command Invoke-DownloadFile -ErrorAction SilentlyContinue)
  {
    Invoke-DownloadFile -Url $RestoreScriptUrl -OutFile $RestoreScriptPath
  }
  else
  {
    $OldProgressPref = $ProgressPreference
    try
    {
      $ProgressPreference = 'SilentlyContinue'
      $Params = @{ Uri = $RestoreScriptUrl; OutFile = $RestoreScriptPath; ErrorAction = 'Stop' }
      if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
      Invoke-WebRequest @Params
    }
    finally
    {
      $ProgressPreference = $OldProgressPref
    }
  }
}

if (-not (Test-Path -LiteralPath $RestoreScriptPath)) { throw "Failed to stage $RestoreScriptPath" }

# Stage shared library modules alongside restore-and-cleanup.ps1 so Scheduled Task execution is self-contained
$RootLibDir = Join-Path $RootClean 'lib'
New-Item -ItemType Directory -Force -Path $RootLibDir | Out-Null
foreach ($LibMod in @('core-primitives.ps1', 'browser-policies.ps1'))
{
  $LibCandidates = @()
  if ($PSScriptRoot) { $LibCandidates += (Join-Path (Join-Path $PSScriptRoot 'lib') $LibMod) }
  if (Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue) { $LibCandidates += (Join-Path (Join-Path $ScriptStageDir 'lib') $LibMod) }
  if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_LIB_DIR)) { $LibCandidates += (Join-Path $env:CONTEST_LIB_DIR $LibMod) }
  $FoundLib = $LibCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  $DestLibFile = Join-Path $RootLibDir $LibMod
  if (-not [string]::IsNullOrWhiteSpace($FoundLib))
  {
    if ([IO.Path]::GetFullPath($FoundLib) -ine [IO.Path]::GetFullPath($DestLibFile))
    {
      Copy-Item -LiteralPath $FoundLib -Destination $DestLibFile -Force
    }
  }
  elseif (-not (Test-Path -LiteralPath $DestLibFile))
  {
    $LibUrl = "$RawBase/lib/$LibMod"
    if (Get-Command Invoke-DownloadFile -ErrorAction SilentlyContinue)
    {
      Invoke-DownloadFile -Url $LibUrl -OutFile $DestLibFile
    }
  }
}

$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

if ($SkipRestoreTask -and (-not $DeferAiBlockValue))
{
  Write-Warning 'Automatic 20:30 cleanup/unblock Scheduled Task is disabled by -NoRestoreTask. You MUST run ".\install-env.ps1 -Mode Restore" manually after the exam to remove AI hosts/browser policies and restore PATH/shortcuts.'
  Write-Host 'Automatic restoration Scheduled Task registration skipped by -NoRestoreTask.' -ForegroundColor Yellow
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
  return
}

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Validating Exam Schedule & Registering Scheduled Task...' -PercentComplete 60

function ConvertTo-KstScheduleDtoFallback
{
  param([Parameter(Mandatory = $true)] [string]$TimestampText)
  $Trimmed = $TimestampText.Trim()
  if ($Trimmed -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$')
  {
    $WithKst = ($Trimmed -replace ' ', 'T') + '+09:00'
    return [DateTimeOffset]::Parse($WithKst, [System.Globalization.CultureInfo]::InvariantCulture)
  }
  return [DateTimeOffset]::Parse($Trimmed, [System.Globalization.CultureInfo]::InvariantCulture)
}

$ScheduleInfo = if (Get-Command Test-ExamScheduleConfiguration -ErrorAction SilentlyContinue) {
  Test-ExamScheduleConfiguration -StartText $ExamStartValue -EndText $ExamEndValue -RestoreText $RestoreAtValue
} else {
  $StartDto = ConvertTo-KstScheduleDtoFallback -TimestampText $ExamStartValue
  $EndDto = ConvertTo-KstScheduleDtoFallback -TimestampText $ExamEndValue
  $RestoreDto = ConvertTo-KstScheduleDtoFallback -TimestampText $RestoreAtValue
  $ParsedStart = $StartDto.LocalDateTime
  $ParsedEnd = $EndDto.LocalDateTime
  $ParsedRestore = $RestoreDto.LocalDateTime
  $IsKstTz = $true
  try { $IsKstTz = ((Get-TimeZone).BaseUtcOffset -eq [TimeSpan]::FromHours(9)) } catch {}
  if (-not $IsKstTz)
  {
    Write-Warning 'System timezone is not Korea Standard Time (UTC+09:00). Timestamps normalized to KST (+09:00).'
  }
  [pscustomobject]@{
    ExamStart         = $ParsedStart
    ExamEnd           = $ParsedEnd
    RestoreAt         = $ParsedRestore
    ExamStartDto      = $StartDto
    ExamEndDto        = $EndDto
    RestoreAtDto      = $RestoreDto
    ExamStartIso      = $StartDto.ToString('o')
    ExamEndIso        = $EndDto.ToString('o')
    RestoreAtIso      = $RestoreDto.ToString('o')
    DayOfWeek         = $StartDto.DayOfWeek.ToString()
    IsKst             = $IsKstTz
    IsKstZone         = $IsKstTz
    IsMonday          = ($StartDto.DayOfWeek -eq [System.DayOfWeek]::Monday)
    IsPastRestoreTime = ((Get-Date) -ge $ParsedRestore)
    IsBeforeExamStart = ((Get-Date) -lt $ParsedStart)
  }
}

$ExamEndIso = if ($null -ne $ScheduleInfo.PSObject.Properties['ExamEndIso'] -and -not [string]::IsNullOrWhiteSpace([string]$ScheduleInfo.ExamEndIso)) {
  [string]$ScheduleInfo.ExamEndIso
} elseif ($null -ne $ScheduleInfo.PSObject.Properties['ExamEndDto'] -and $null -ne $ScheduleInfo.ExamEndDto) {
  $ScheduleInfo.ExamEndDto.ToString('o')
} else {
  (New-Object System.DateTimeOffset($ScheduleInfo.ExamEnd)).ToString('o')
}

$PsExecutable = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
if ([string]::IsNullOrWhiteSpace($PsExecutable) -or (-not (Test-Path -LiteralPath $PsExecutable)))
{
  if (Get-Command Get-PreferredPowerShell -ErrorAction SilentlyContinue)
  {
    $CandidatePs = Get-PreferredPowerShell
    $PsExecutable = if ($CandidatePs -and ($CandidatePs -notmatch '\\WindowsApps\\')) { $CandidatePs } else { 'powershell.exe' }
  }
  else
  {
    $PsExecutable = 'powershell.exe'
  }
}

$CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentUser = $CurrentIdentity.Name
$CurrentSid = if ($CurrentIdentity -and $CurrentIdentity.User) { $CurrentIdentity.User.Value } else { '' }

$Settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -WakeToRun `
  -ExecutionTimeLimit (New-TimeSpan -Hours 1)

function Register-ContestScheduledTaskWithFallback
{
  param(
    [Parameter(Mandatory = $true)] [string]$TaskName,
    [Parameter(Mandatory = $true)] [object]$Action,
    [Parameter(Mandatory = $true)] [object]$Trigger,
    [Parameter(Mandatory = $true)] [object]$Settings
  )
  try
  {
    $SystemPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $SystemPrincipal -Settings $Settings -Force | Out-Null
    return 'SYSTEM (S-1-5-18)'
  }
  catch
  {
    if ($CurrentSid -ne 'S-1-5-18' -and -not [string]::IsNullOrWhiteSpace($CurrentUser))
    {
      Write-Warning "SYSTEM ServiceAccount registration failed for '$TaskName' ($($_.Exception.Message)); falling back to interactive user '$CurrentUser'."
      $InteractivePrincipal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
      Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $InteractivePrincipal -Settings $Settings -Force | Out-Null
      return $CurrentUser
    }
    throw
  }
}

# Pre-exam enforcement task at ExamStart (2026-11-23T19:00:00) if installed ahead of exam start (mandatory when -DeferAiBlockUntilExamStart is active)
$StartTaskName = 'ContestSetupExamStartEnforcement'
$AiHostsCandidatesForStart = @(
  (Join-Path (Join-Path $RootClean 'ai-hosts-block') 'ai-hosts-block.ps1'),
  (Join-Path (Join-Path $RootClean 'ai-block') 'ai-hosts-block.ps1'),
  (Join-Path $RootClean 'ai-hosts-block.ps1')
)
$AiHostsScriptForStart = $AiHostsCandidatesForStart | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($ScheduleInfo.IsBeforeExamStart)
{
  if (-not $AiHostsScriptForStart)
  {
    if ($DeferAiBlockValue)
    {
      throw "Cannot register mandatory deferred AI enforcement task '$StartTaskName': staged ai-hosts-block.ps1 was not found under '$RootClean'."
    }
  }
  else
  {
    try
    {
      $StartArgParts = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $AiHostsScriptForStart,
        '-Apply',
        '-NoSchedule',
        '-NotAfter', $ExamEndIso,
        '-Root', $RootClean
      )
      $StartTaskArgs = ($StartArgParts | ForEach-Object { Format-ScheduledTaskArg $_ }) -join ' '
      $StartAction = New-ScheduledTaskAction -Execute $PsExecutable -Argument $StartTaskArgs
      $StartTrigger = New-ScheduledTaskTrigger -Once -At $ScheduleInfo.ExamStart
      $StartTrigger.EndBoundary = $ScheduleInfo.ExamEnd.ToString('yyyy-MM-ddTHH:mm:ss', $InvariantCulture)
      $StartPrincipalUsed = Register-ContestScheduledTaskWithFallback -TaskName $StartTaskName -Action $StartAction -Trigger $StartTrigger -Settings $Settings
      $StartDayLabel = if ($null -ne $ScheduleInfo.PSObject.Properties['DayOfWeek']) { [string]$ScheduleInfo.DayOfWeek } else { $ScheduleInfo.ExamStart.DayOfWeek.ToString() }
      Write-Host ("Scheduled exam-start enforcement task '{0}' for {1} ({2}, expires at {3}, principal: {4})." -f $StartTaskName, $ScheduleInfo.ExamStart.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture), $StartDayLabel, $ScheduleInfo.ExamEnd.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture), $StartPrincipalUsed) -ForegroundColor Green
    }
    catch
    {
      if ($DeferAiBlockValue)
      {
        throw "Failed to register mandatory exam-start AI enforcement task '$StartTaskName' required by -DeferAiBlockUntilExamStart: $($_.Exception.Message). Re-run without -DeferAiBlockUntilExamStart to apply the AI hosts block immediately."
      }
      Write-Warning "Could not register optional exam-start enforcement task: $($_.Exception.Message)"
    }
  }
}

if ($SkipRestoreTask)
{
  Write-Warning 'Automatic 20:30 cleanup/unblock Scheduled Task is disabled by -NoRestoreTask. You MUST run ".\install-env.ps1 -Mode Restore" manually after the exam to remove AI hosts/browser policies and restore PATH/shortcuts.'
  Write-Host 'Automatic restoration Scheduled Task registration skipped by -NoRestoreTask.' -ForegroundColor Yellow
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
  return
}

# Primary post-exam restoration task at RestoreAt (default: 2026-11-23T20:30:00)
$TaskName = 'ContestSetupRestoreAndCleanup'
$EffectiveTriggerTime = $ScheduleInfo.RestoreAt
$IncludeShutdownFlag = (-not $SkipRestoreShutdown)

if ($ScheduleInfo.IsPastRestoreTime)
{
  # Past-date safeguard: never register an expired -StartWhenAvailable -Shutdown task that could immediately shut down the PC
  $EffectiveTriggerTime = (Get-Date).AddHours(2)
  $IncludeShutdownFlag = $false
  Write-Warning ("Configured RestoreAt ({0}) is in the past relative to current system time ({1}). Scheduling fallback restore at {2} WITHOUT forced shutdown." -f $ScheduleInfo.RestoreAt.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture), ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture)), $EffectiveTriggerTime.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture))
}

$ScheduledRestoreIso = (New-Object System.DateTimeOffset($EffectiveTriggerTime)).ToString('o')
$RestoreArgParts = @(
  '-NoProfile',
  '-ExecutionPolicy', 'Bypass',
  '-File', $RestoreScriptPath,
  '-Root', $RootClean,
  '-MsysRoot', $MsysRootClean,
  '-PythonVersion', [string]$PythonVersion,
  '-ScheduledRestoreAt', $ScheduledRestoreIso,
  '-NoPause'
)
if (-not [string]::IsNullOrWhiteSpace($PythonDirClean))
{
  $RestoreArgParts += @('-PythonDir', $PythonDirClean)
}
if (-not [string]::IsNullOrWhiteSpace($ResolvedTargetSid))
{
  $RestoreArgParts += @('-TargetUserSid', $ResolvedTargetSid)
}
if (-not [string]::IsNullOrWhiteSpace($TargetProfileClean))
{
  $RestoreArgParts += @('-TargetUserProfile', $TargetProfileClean)
}
if ($IncludeShutdownFlag)
{
  $RestoreArgParts += '-Shutdown'
}

$TaskArgs = ($RestoreArgParts | ForEach-Object { Format-ScheduledTaskArg $_ }) -join ' '
$Action = New-ScheduledTaskAction -Execute $PsExecutable -Argument $TaskArgs
$Trigger = New-ScheduledTaskTrigger -Once -At $EffectiveTriggerTime

$ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($ExistingTask)
{
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  $PrincipalUsed = Register-ContestScheduledTaskWithFallback -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings
  Write-Host "Scheduled task '$TaskName' updated successfully (principal: $PrincipalUsed)." -ForegroundColor Green
}
else
{
  $PrincipalUsed = Register-ContestScheduledTaskWithFallback -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings
  Write-Host "Scheduled task '$TaskName' registered successfully (principal: $PrincipalUsed)." -ForegroundColor Green
}

Write-Host ("Scheduled task '{0}' registered to run at {1} ({2})." -f $TaskName, $EffectiveTriggerTime.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture), $EffectiveTriggerTime.DayOfWeek) -ForegroundColor Green
if ($IncludeShutdownFlag)
{
  Write-Host 'Computer will automatically shut down after cleanup (suppressed if run >25 minutes late after reboot).' -ForegroundColor Yellow
}
else
{
  Write-Host 'Automatic post-cleanup shutdown is disabled for this task.' -ForegroundColor Yellow
}
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
