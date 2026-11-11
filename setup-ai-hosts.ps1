# setup-ai-hosts.ps1
# ContestSetup v2.0 -- AI Hosts Block Integration Module (Local/Staged First)

Write-Section 'Setup AI Hosts Block'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] AI Hosts Block"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Preparing AI Hosts Block Script...' -PercentComplete 10

$RootClean = $Root
if (-not [string]::IsNullOrWhiteSpace($RootClean))
{
  $FullRoot = [IO.Path]::GetFullPath($RootClean.Trim())
  if ($FullRoot -notmatch '^[A-Za-z]:\\$')
  {
    $RootClean = $FullRoot.TrimEnd('\', '/')
  }
}

$AiScriptUrl = "$RawBase/ai-hosts-block.ps1"
$AiScriptPath = Join-Path $RootClean 'ai-hosts-block.ps1'
$AiBlockDir = Join-Path $RootClean 'ai-block'
$AiHostsHoldDir = Join-Path $RootClean 'ai-hosts-block'
$StableAiScriptPath = Join-Path $AiBlockDir 'ai-hosts-block.ps1'
$HoldAiScriptPath = Join-Path $AiHostsHoldDir 'ai-hosts-block.ps1'

New-Item -ItemType Directory -Force -Path $RootClean, $AiBlockDir, $AiHostsHoldDir | Out-Null

# Prefer local or staged copy before falling back to network download
$CandidateSources = @()
if ($PSScriptRoot) { $CandidateSources += (Join-Path $PSScriptRoot 'ai-hosts-block.ps1') }
if (Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue) { $CandidateSources += (Join-Path $ScriptStageDir 'ai-hosts-block.ps1') }

$CopiedFromLocal = $false
foreach ($Candidate in $CandidateSources)
{
  if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate))
  {
    foreach ($DestTarget in @($AiScriptPath, $StableAiScriptPath, $HoldAiScriptPath))
    {
      if ([IO.Path]::GetFullPath($Candidate) -ine [IO.Path]::GetFullPath($DestTarget))
      {
        Copy-Item -LiteralPath $Candidate -Destination $DestTarget -Force
      }
    }
    $CopiedFromLocal = $true
    Write-Host "Staged ai-hosts-block.ps1 from $Candidate" -ForegroundColor Green
    break
  }
}

if (-not $CopiedFromLocal)
{
  if (Get-Command Invoke-DownloadFile -ErrorAction SilentlyContinue)
  {
    Invoke-DownloadFile -Url $AiScriptUrl -OutFile $AiScriptPath
  }
  else
  {
    $OldProgressPref = $ProgressPreference
    try
    {
      $ProgressPreference = 'SilentlyContinue'
      $Params = @{ Uri = $AiScriptUrl; OutFile = $AiScriptPath; ErrorAction = 'Stop' }
      if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
      Invoke-WebRequest @Params
    }
    finally
    {
      $ProgressPreference = $OldProgressPref
    }
  }
  Copy-Item -LiteralPath $AiScriptPath -Destination $StableAiScriptPath -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $AiScriptPath -Destination $HoldAiScriptPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $AiScriptPath)) { throw "Failed to stage $AiScriptPath" }

$DeferAiBlock = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [bool](Get-ContestVariableValue -Name 'DeferAiBlockUntilExamStart' -DefaultValue $false -EnvVar 'CONTEST_DEFER_AI_BLOCK')
} elseif (Get-Variable -Name 'DeferAiBlockUntilExamStart' -ErrorAction SilentlyContinue) {
  [bool]$DeferAiBlockUntilExamStart
} elseif ($env:CONTEST_DEFER_AI_BLOCK -match '^(1|true|yes)$') {
  $true
} else {
  $false
}

$IsBeforeExamWindow = $false
if ($DeferAiBlock)
{
  if (Get-Command Test-ExamScheduleConfiguration -ErrorAction SilentlyContinue)
  {
    try
    {
      $SchedCheck = Test-ExamScheduleConfiguration
      $IsBeforeExamWindow = [bool]$SchedCheck.IsBeforeExamStart
    }
    catch {}
  }
  else
  {
    $ExamStartText = if (Get-Variable -Name 'ExamStart' -ErrorAction SilentlyContinue) { [string]$ExamStart } else { '2026-11-23T19:00:00' }
    $TrimmedStart = $ExamStartText.Trim()
    $IsoStart = if ($TrimmedStart -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$') { ($TrimmedStart -replace ' ', 'T') + '+09:00' } else { $TrimmedStart }
    try
    {
      $ParsedStartLocal = ([DateTimeOffset]::Parse($IsoStart, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
      $IsBeforeExamWindow = ((Get-Date) -lt $ParsedStartLocal)
    }
    catch {}
  }
}

$SkipRestoreTaskFlag = if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue) {
  [bool](Get-ContestVariableValue -Name 'NoRestoreTask' -DefaultValue $false -EnvVar 'CONTEST_NO_RESTORE_TASK')
} elseif (Get-Variable -Name 'NoRestoreTask' -ErrorAction SilentlyContinue) {
  [bool]$NoRestoreTask
} elseif ($env:CONTEST_NO_RESTORE_TASK -match '^(1|true|yes)$') {
  $true
} else {
  $false
}

if ($DeferAiBlock -and $IsBeforeExamWindow)
{
  if ($SkipRestoreTaskFlag)
  {
    Write-Host "Deferring immediate AI hosts block until exam start; ContestSetupExamStartEnforcement will still be registered at ExamStart despite -NoRestoreTask. Staged: $HoldAiScriptPath" -ForegroundColor Yellow
  }
  else
  {
    Write-Host "Deferring immediate AI hosts block until exam start (ContestSetupExamStartEnforcement). Staged: $HoldAiScriptPath" -ForegroundColor Yellow
  }
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
  return
}
elseif ($DeferAiBlock -and (-not $IsBeforeExamWindow))
{
  Write-Host 'Exam start time has already arrived; applying AI hosts block immediately instead of deferring.' -ForegroundColor Yellow
}

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Applying Blocklist...' -PercentComplete 50

$WinPsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$PowerShellExe = if (Test-Path -LiteralPath $WinPsExe) {
  $WinPsExe
} elseif (Get-Command Get-PreferredPowerShell -ErrorAction SilentlyContinue) {
  Get-PreferredPowerShell
} else {
  'powershell.exe'
}

$ForwardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HoldAiScriptPath, '-Apply', '-NoSchedule', '-Root', $RootClean)

& $PowerShellExe @ForwardArgs
if ($LASTEXITCODE -ne 0) { throw "AI Hosts block application failed. Exit code: $LASTEXITCODE" }

Write-Host 'AI hosts block applied for contest environment.' -ForegroundColor Green
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
