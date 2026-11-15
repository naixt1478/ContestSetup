#requires -Version 5.1
# tests/windows_lifecycle_e2e.ps1
# End-to-End Windows Full-Lifecycle Setup & Post-Contest Restoration Verification Harness
# Designed for ephemeral CI runners (windows-latest). Guarded by -AllowDestructiveSystemChanges.

[CmdletBinding()]
param(
  [switch]$AllowDestructiveSystemChanges
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Write-CiGroup {
  param([Parameter(Mandatory = $true)] [string]$Title)
  Write-Host "::group::$Title"
  Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-CiEndGroup {
  Write-Host '::endgroup::'
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)] [bool]$Condition,
    [Parameter(Mandatory = $true)] [string]$Message
  )
  if (-not $Condition) {
    throw "ASSERTION FAILED: $Message"
  }
}

function Test-IsAdministrator {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Ps51Executable {
  if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    $cand = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $cand) { return $cand }
  }
  return 'powershell.exe'
}

function Invoke-Ps51Script {
  param(
    [Parameter(Mandatory = $true)] [string]$ScriptPath,
    [string[]]$Arguments = @(),
    [switch]$AllowNonZeroExit
  )
  $ps51 = Get-Ps51Executable
  $argDisplay = ($Arguments -join ' ')
  Write-Host ("[PS5.1 EXEC] {0} {1}" -f $ScriptPath, $argDisplay) -ForegroundColor Gray
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $exitCode = 1
  $global:LASTEXITCODE = 0
  try {
    & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 | ForEach-Object {
      Write-Host ([string]$_)
    }
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if ((-not $AllowNonZeroExit) -and ($exitCode -ne 0)) {
    throw "Script '$ScriptPath' failed with exit code $exitCode (args: $argDisplay)"
  }
  return $exitCode
}

function Read-Utf8TextSafe {
  param([Parameter(Mandatory = $true)] [string]$Path)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  return [System.IO.File]::ReadAllText($Path, $utf8NoBom)
}

function Write-Utf8NoBomText {
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$Content
  )
  $parent = Split-Path -Path $Path -Parent
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-RegistryPathRaw {
  param([Parameter(Mandatory = $true)] [ValidateSet('User', 'Machine')] [string]$Scope)
  if ($Scope -eq 'Machine') {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
  } else {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
  }
  if ($null -eq $key) { return [pscustomobject]@{ Exists = $false; Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString } }
  try {
    $names = @($key.GetValueNames())
    $matchName = $names | Where-Object { $_ -ieq 'Path' } | Select-Object -First 1
    if ($null -eq $matchName) {
      return [pscustomobject]@{ Exists = $false; Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    $val = [string]$key.GetValue($matchName, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $key.GetValueKind($matchName)
    return [pscustomobject]@{ Exists = $true; Value = $val; Kind = $kind }
  } finally {
    $key.Close()
  }
}

function Set-RegistryPathExpand {
  param(
    [Parameter(Mandatory = $true)] [ValidateSet('User', 'Machine')] [string]$Scope,
    [Parameter(Mandatory = $true)] [string]$PathValue
  )
  if ($Scope -eq 'Machine') {
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
  } else {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  }
  try {
    $key.SetValue('Path', $PathValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
  } finally {
    $key.Close()
  }
}

function Wait-ScheduledTaskCompletion {
  param(
    [Parameter(Mandatory = $true)] [string]$TaskName,
    [int]$TimeoutSeconds = 120
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Start-Sleep -Seconds 2
  while ((Get-Date) -lt $deadline) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) {
      throw "Scheduled task '$TaskName' disappeared while waiting for completion."
    }
    if ($t.State -ne 'Running') {
      $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
      if ($null -ne $info -and $info.LastRunTime -gt [datetime]'2000-01-01') {
        return $info
      }
    }
    Start-Sleep -Seconds 2
  }
  throw "Timed out waiting for scheduled task '$TaskName' to finish within $TimeoutSeconds seconds."
}

function Wait-ContestRestoreAndCleanupComplete {
  param(
    [Parameter(Mandatory = $true)] [string]$ContestRoot,
    [int]$TimeoutSeconds = 240
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Start-Sleep -Seconds 2
  while ((Get-Date) -lt $deadline) {
    $taskStillExists = ($null -ne (Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction SilentlyContinue))
    $rootStillExists = (Test-Path -LiteralPath $ContestRoot)
    $activeRestoreProcs = @(
      Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $null -ne $_.CommandLine -and
        $_.CommandLine -match 'restore-and-cleanup\.ps1|contest-restore-runner\.ps1|remove-cptools\.cmd|ai-hosts-block\.ps1'
      }
    )
    if ((-not $taskStillExists) -and (-not $rootStillExists) -and ($activeRestoreProcs.Count -eq 0)) {
      Start-Sleep -Seconds 2
      $taskRecheck = ($null -ne (Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction SilentlyContinue))
      $rootRecheck = (Test-Path -LiteralPath $ContestRoot)
      if ((-not $taskRecheck) -and (-not $rootRecheck)) {
        return
      }
    }
    Start-Sleep -Seconds 2
  }
  throw "Timed out waiting for SYSTEM ContestSetupRestoreAndCleanup to finish and remove '$ContestRoot' within $TimeoutSeconds seconds."
}

function Get-WorkspaceBackupDirectories {
  param([string]$ProfilePath = $env:USERPROFILE)
  $searchBases = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    $searchBases.Add((Join-Path $ProfilePath 'AppData\Local\ContestSetup-Backups')) | Out-Null
    $searchBases.Add((Join-Path $ProfilePath 'AppData\Local\Temp')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $searchBases.Add((Join-Path $env:LOCALAPPDATA 'ContestSetup-Backups')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    $searchBases.Add((Join-Path $env:ProgramData 'ContestSetup-Backups')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
    $searchBases.Add($env:TEMP) | Out-Null
  }
  $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  foreach ($base in @($searchBases.ToArray() | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($base) -or -not (Test-Path -LiteralPath $base)) { continue }
    foreach ($dir in @(Get-ChildItem -LiteralPath $base -Filter 'ContestSetup-Workspace-Backup-*' -Directory -ErrorAction SilentlyContinue)) {
      $found.Add($dir) | Out-Null
    }
  }
  return @($found.ToArray() | Sort-Object CreationTime -Descending)
}

function Dump-ContestDiagnostics {
  param([string]$ContestRoot)
  Write-Host '================ DIAGNOSTIC DUMP ================' -ForegroundColor Red
  try {
    Write-Host '--- Scheduled Tasks ---'
    foreach ($tn in @('ContestSetupRestoreAndCleanup', 'ContestSetupExamStartEnforcement', 'ContestSetupRestoreAiHostsBlock')) {
      $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
      if ($null -ne $t) {
        $info = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
        Write-Host ("Task {0}: State={1} LastResult={2} LastRun={3}" -f $tn, $t.State, $(if ($info) { $info.LastTaskResult } else { 'n/a' }), $(if ($info) { $info.LastRunTime } else { 'n/a' }))
      } else {
        Write-Host "Task ${tn}: NOT REGISTERED"
      }
    }
  } catch {}
  try {
    Write-Host '--- ContestRoot Tree & Manifest ---'
    if (Test-Path -LiteralPath $ContestRoot) {
      Get-ChildItem -LiteralPath $ContestRoot -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  {0} ({1})" -f $_.FullName, $(if ($_.PSIsContainer) { 'DIR' } else { "$($_.Length)B" }))
      }
      $manifestPath = Join-Path $ContestRoot 'state\install-manifest.json'
      if (Test-Path -LiteralPath $manifestPath) {
        Write-Host "MANIFEST: $manifestPath"
        Get-Content -LiteralPath $manifestPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
      }
    } else {
      Write-Host "ContestRoot does not exist: $ContestRoot"
    }
  } catch {}
  try {
    Write-Host '--- ContestSetup Logs & Error Files ---'
    $contestLogRoots = @(
      (Join-Path $ContestRoot 'logs'),
      (Join-Path $env:TEMP 'ContestSetup-Logs'),
      (Join-Path $env:SystemRoot 'Temp\ContestSetup-Logs')
    )
    foreach ($clr in ($contestLogRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
      foreach ($clf in @(Get-ChildItem -Path $clr -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8)) {
        Write-Host "CONTEST LOG: $($clf.FullName)"
        Get-Content -LiteralPath $clf.FullName -Tail 120 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
      }
    }
    Write-Host '--- Temp .log Files Tail ---'
    $tempRoots = @(
      $env:TEMP,
      (Join-Path $env:SystemRoot 'Temp')
    )
    foreach ($lr in ($tempRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
      foreach ($lf in @(Get-ChildItem -Path $lr -Filter '*.log' -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        Write-Host "LOG FILE: $($lf.FullName)"
        Get-Content -LiteralPath $lf.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
      }
    }
  } catch {}
  Write-Host '=================================================' -ForegroundColor Red
}

# --- Main Guard ---
Assert-True $AllowDestructiveSystemChanges 'Refusing to run without -AllowDestructiveSystemChanges (this harness modifies hosts, HKLM policies, PATH, Scheduled Tasks, and C:\CPTools).'
Assert-True (Test-IsAdministrator) 'Windows lifecycle E2E harness must run in an elevated Administrator shell.'

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$InstallEnvPs1 = Join-Path $RepoRoot 'install-env.ps1'
$InstallAiHostsPs1 = Join-Path $RepoRoot 'install-ai-hosts.ps1'
Assert-True (Test-Path -LiteralPath $InstallEnvPs1) "Missing install-env.ps1 at $InstallEnvPs1"
Assert-True (Test-Path -LiteralPath $InstallAiHostsPs1) "Missing install-ai-hosts.ps1 at $InstallAiHostsPs1"

$ContestRoot = "$env:SystemDrive\CPTools"
$CacheBundleDir = "$env:SystemDrive\ContestCacheCi"
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$DesktopDir = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
  $DesktopDir = Join-Path $env:USERPROFILE 'Desktop'
}
$DesktopShortcutPath = Join-Path $DesktopDir 'Visual Studio Code.lnk'
$PersonalVsCodeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
$PersonalVsCodeExtPkg = Join-Path $env:USERPROFILE '.vscode\extensions\personal.keep-me-1.0.0\package.json'
$ChromePolicyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$WhalePolicyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'
$JudgeHostLine = '127.0.0.1 judge.contest-ci.local'

try {
  # ==========================================================================
  # PHASE 1: Baseline Seeding (User/Machine PATH, hosts, .lnk, HKLM, Personal)
  # ==========================================================================
  Write-CiGroup 'Phase 1: Seed realistic student PC baseline (PATH, hosts, shortcut, HKLM, personal VS Code)'

  New-Item -ItemType Directory -Force -Path $DesktopDir | Out-Null
  foreach ($tn in @('ContestSetupRestoreAndCleanup', 'ContestSetupExamStartEnforcement', 'ContestSetupRestoreAiHostsBlock')) {
    try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  }
  foreach ($cleanDir in @($ContestRoot, $CacheBundleDir)) {
    if (Test-Path -LiteralPath $cleanDir) {
      Remove-Item -LiteralPath $cleanDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  foreach ($oldBak in @(Get-WorkspaceBackupDirectories)) {
    Remove-Item -LiteralPath $oldBak.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Seed User PATH (with unexpanded %SystemRoot% + C:\PreExistingUserTool) and Machine PATH (with C:\PreExistingMachineTool)
  $origUserRaw = Get-RegistryPathRaw -Scope 'User'
  $userParts = New-Object System.Collections.Generic.List[string]
  $userParts.Add('%SystemRoot%\System32') | Out-Null
  $userParts.Add('C:\PreExistingUserTool') | Out-Null
  foreach ($part in ($origUserRaw.Value -split ';')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $trimmed = $part.Trim()
    if ($trimmed -ieq '%SystemRoot%\System32' -or $trimmed -ieq 'C:\PreExistingUserTool' -or $trimmed -like 'C:\CPTools*') { continue }
    $userParts.Add($trimmed) | Out-Null
  }
  Set-RegistryPathExpand -Scope 'User' -PathValue ($userParts -join ';')

  $origMachineRaw = Get-RegistryPathRaw -Scope 'Machine'
  $machineParts = New-Object System.Collections.Generic.List[string]
  foreach ($part in ($origMachineRaw.Value -split ';')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $trimmed = $part.Trim()
    if ($trimmed -ieq 'C:\PreExistingMachineTool' -or $trimmed -like 'C:\CPTools*') { continue }
    $machineParts.Add($trimmed) | Out-Null
  }
  $machineParts.Add('C:\PreExistingMachineTool') | Out-Null
  Set-RegistryPathExpand -Scope 'Machine' -PathValue ($machineParts -join ';')

  # Seed custom judge entry in hosts file
  $rawHosts = if (Test-Path -LiteralPath $HostsPath) { Read-Utf8TextSafe -Path $HostsPath } else { "127.0.0.1 localhost`r`n" }
  if ($rawHosts -notmatch [regex]::Escape($JudgeHostLine)) {
    $rawHosts = $rawHosts.TrimEnd("`r", "`n") + "`r`n" + $JudgeHostLine + "`r`n"
    Write-Utf8NoBomText -Path $HostsPath -Content $rawHosts
  }

  # Seed pre-contest Visual Studio Code.lnk on Desktop
  $wsh = New-Object -ComObject WScript.Shell
  try {
    $sc = $wsh.CreateShortcut($DesktopShortcutPath)
    $sc.TargetPath = (Join-Path $env:WINDIR 'System32\notepad.exe')
    $sc.Arguments = '--pre-contest-user'
    $sc.WorkingDirectory = $DesktopDir
    $sc.Description = 'Pre-Contest User VS Code'
    $sc.Save()
  } finally {
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) } catch {}
  }

  # Seed one existing HKLM browser policy value (Chrome='automatic') and ensure one does not exist yet (Whale)
  New-Item -Path $ChromePolicyPath -Force | Out-Null
  Set-ItemProperty -LiteralPath $ChromePolicyPath -Name 'DnsOverHttpsMode' -Value 'automatic' -Type String
  if (Test-Path -LiteralPath $WhalePolicyPath) {
    Remove-Item -LiteralPath $WhalePolicyPath -Recurse -Force
  }

  # Seed personal VS Code user settings and personal extension (must never be touched)
  Write-Utf8NoBomText -Path $PersonalVsCodeSettings -Content '{"editor.tabSize": 2, "contestCiSentinel": "keep"}'
  Write-Utf8NoBomText -Path $PersonalVsCodeExtPkg -Content '{"name": "keep-me", "version": "1.0.0"}'

  Write-Host 'Baseline seeded successfully.' -ForegroundColor Green
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 2: Non-Destructive -Mode DryRun in UTC + Switch Timezone to KST
  # ==========================================================================
  Write-CiGroup 'Phase 2: Non-destructive DryRun in UTC timezone, then switch runner to KST (+09:00)'

  $nowKst = [System.DateTimeOffset]::UtcNow.ToOffset([System.TimeSpan]::FromHours(9))
  $dryStart = $nowKst.AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
  $dryEnd = $nowKst.AddMinutes(120).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'DryRun',
    '-ExamStart', $dryStart,
    '-ExamEnd', $dryEnd,
    '-RestoreAt', $dryEnd,
    '-NoPause'
  ))
  Assert-True (-not (Test-Path -LiteralPath $ContestRoot)) "DryRun unexpectedly created $ContestRoot"
  $hostsAfterDry = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsAfterDry -notmatch 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'DryRun unexpectedly modified hosts'

  Write-Host 'Switching Windows runner timezone to Korea Standard Time (UTC+09:00)...'
  & tzutil.exe /s 'Korea Standard Time'
  Assert-True ($LASTEXITCODE -eq 0) "tzutil.exe failed with exit code $LASTEXITCODE"
  [System.TimeZoneInfo]::ClearCachedData()
  $tzId = (Get-TimeZone).Id
  Write-Host "Current TimeZone: $tzId"
  Assert-True ($tzId -eq 'Korea Standard Time') "Expected Korea Standard Time, got $tzId"
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 3: Cold Install (-DeferAiBlockUntilExamStart) + Status + Exam-Start Task Trigger
  # ==========================================================================
  Write-CiGroup 'Phase 3: Cold Install (-DeferAiBlockUntilExamStart) -> Status -> Trigger ExamStart Task'

  $examStart = (Get-Date).AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
  $examEnd = (Get-Date).AddMinutes(120).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'Install',
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-DeferAiBlockUntilExamStart',
    '-NoPause'
  ))

  $hostsDeferred = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsDeferred -notmatch 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'Deferred install blocked hosts prematurely'

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'Status',
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-DeferAiBlockUntilExamStart',
    '-NoPause'
  ))

  $startTask = Get-ScheduledTask -TaskName 'ContestSetupExamStartEnforcement' -ErrorAction SilentlyContinue
  $restoreTask = Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction SilentlyContinue
  Assert-True ($null -ne $startTask) 'ContestSetupExamStartEnforcement task was not registered'
  Assert-True ($null -ne $restoreTask) 'ContestSetupRestoreAndCleanup task was not registered'
  Assert-True ($restoreTask.Principal.UserId -match 'S-1-5-18|SYSTEM') "Expected SYSTEM principal for restore task, got $($restoreTask.Principal.UserId)"
  $restoreArgsText = [string]$restoreTask.Actions[0].Arguments
  Assert-True ($restoreArgsText -match '(?i)-Shutdown') "Expected default -Shutdown in restore task args: $restoreArgsText"
  Assert-True ($restoreArgsText -match '(?i)-TargetUserSid') "Expected -TargetUserSid in restore task args: $restoreArgsText"

  Write-Host 'Triggering ContestSetupExamStartEnforcement manually...' -ForegroundColor Yellow
  Start-ScheduledTask -TaskName 'ContestSetupExamStartEnforcement'
  $startInfo = Wait-ScheduledTaskCompletion -TaskName 'ContestSetupExamStartEnforcement' -TimeoutSeconds 120
  Assert-True ($startInfo.LastTaskResult -eq 0) "ContestSetupExamStartEnforcement returned LastTaskResult=$($startInfo.LastTaskResult)"

  $hostsBlocked = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsBlocked -match 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'ExamStart task did not apply AI hosts block'
  Assert-True ($hostsBlocked -match '(?m)^0\.0\.0\.0\s+chatgpt\.com\s*$') 'Missing IPv4 chatgpt.com block rule'
  Assert-True ($hostsBlocked -match '(?m)^::\s+chatgpt\.com\s*$') 'Missing IPv6 chatgpt.com block rule'
  Assert-True ($hostsBlocked -match '(?m)^0\.0\.0\.0\s+wrtn\.ai\s*$') 'Missing KR AI wrtn.ai block rule'
  Assert-True ($hostsBlocked -match [regex]::Escape($JudgeHostLine)) 'Custom judge host entry was lost during hosts block'

  $chromeDoh = (Get-ItemProperty -LiteralPath $ChromePolicyPath -Name 'DnsOverHttpsMode' -ErrorAction Stop).DnsOverHttpsMode
  $whaleDoh = (Get-ItemProperty -LiteralPath $WhalePolicyPath -Name 'DnsOverHttpsMode' -ErrorAction Stop).DnsOverHttpsMode
  Assert-True ($chromeDoh -eq 'off') "Expected Chrome DnsOverHttpsMode='off', got '$chromeDoh'"
  Assert-True ($whaleDoh -eq 'off') "Expected Naver Whale DnsOverHttpsMode='off', got '$whaleDoh'"
  Assert-True (Test-Path -LiteralPath (Join-Path $ContestRoot 'ai-block\browser-policies.bak.json')) 'Missing browser-policies.bak.json'
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 4: Warm Re-Run Idempotency (-NoRestoreShutdown) + Verify Gate
  # ==========================================================================
  Write-CiGroup 'Phase 4: Warm Install Idempotency (-NoRestoreShutdown) + Strict Verify Gate'

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'Install',
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-NoRestoreShutdown',
    '-NoPause'
  ))

  $restoreTaskNoShut = Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction Stop
  $restoreArgsNoShut = [string]$restoreTaskNoShut.Actions[0].Arguments
  Assert-True ($restoreArgsNoShut -notmatch '(?i)(?:^|\s)-Shutdown(?:\s|$)') "Expected -Shutdown omitted after -NoRestoreShutdown re-run: $restoreArgsNoShut"

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'Verify',
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-NoPause'
  ))
  Write-Host 'Strict -Mode Verify passed.' -ForegroundColor Green
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 5: Student Contest Session Simulation + ExportCache
  # ==========================================================================
  Write-CiGroup 'Phase 5: Student Contest Experience (Shortcuts, VS Code Lockdown, C++20/Python3) + ExportCache'

  $wshCheck = New-Object -ComObject WScript.Shell
  try {
    $contestSc = $wshCheck.CreateShortcut($DesktopShortcutPath)
    Assert-True ($contestSc.TargetPath -ieq (Join-Path $ContestRoot 'vscode\Code.exe')) "Shortcut TargetPath mismatch: $($contestSc.TargetPath)"
    Assert-True ($contestSc.Arguments -match '--locale\s+ko') "Shortcut missing --locale ko: $($contestSc.Arguments)"
    Assert-True ($contestSc.Arguments -match '--user-data-dir') "Shortcut missing --user-data-dir: $($contestSc.Arguments)"
    Assert-True ($contestSc.Arguments -match '--extensions-dir') "Shortcut missing --extensions-dir: $($contestSc.Arguments)"
  } finally {
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wshCheck) } catch {}
  }

  $extRoot = Join-Path $ContestRoot 'vscode-contest\extensions'
  $extNames = @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction Stop | ForEach-Object { $_.Name.ToLowerInvariant() })
  foreach ($reqPrefix in @('ms-ceintl.vscode-language-pack-ko-', 'ms-vscode.cpptools-', 'ms-python.python-', 'ms-python.debugpy-')) {
    $matchedExt = @($extNames | Where-Object { $_.StartsWith($reqPrefix) })
    Assert-True ($matchedExt.Count -ge 1) "Missing required VS Code extension matching '$reqPrefix' in $extRoot"
  }

  $wsDir = Join-Path $ContestRoot 'contest'
  foreach ($cfg in @('tasks.json', 'launch.json', 'c_cpp_properties.json')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $wsDir ".vscode\$cfg")) "Missing workspace config .vscode\$cfg"
  }

  # Create realistic student contest solutions + ignored binary
  $cpp20Src = Join-Path $wsDir 'sol_cpp20.cpp'
  $cpp20Exe = Join-Path $wsDir 'sol_cpp20.exe'
  $pySubDir = Join-Path $wsDir 'sub'
  $py310Src = Join-Path $pySubDir 'sol_py310.py'
  $ignoredBin = Join-Path $wsDir 'ignored_binary.exe'

  Write-Utf8NoBomText -Path $cpp20Src -Content @"
#include <iostream>
#include <numeric>
#include <string_view>
int main() {
    std::string_view sv = "contest20";
    int g = sv.starts_with("contest") ? std::gcd(84, 126) : 0;
    std::cout << "CONTEST_CPP20_OK:" << g << std::endl;
    return 0;
}
"@
  Write-Utf8NoBomText -Path $py310Src -Content @"
import sys
cmd = ("check", 310)
match cmd:
    case ("check", ver):
        print(f"CONTEST_PY310_OK:{sys.version_info.major}.{sys.version_info.minor}:{ver}")
"@
  Write-Utf8NoBomText -Path $ignoredBin -Content 'DUMMY_EXE_DO_NOT_BACKUP'

  # Verify student child PowerShell session reading fresh Registry PATH compiles C++20 & runs Python 3.10
  $studentProbe = @'
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($cmdName in @('g++14', 'g++17', 'g++20', 'g++', 'gcc', 'gdb', 'python', 'python3', 'cat', 'code')) {
  $resolved = Get-Command $cmdName -ErrorAction Stop | Select-Object -First 1
  Write-Host ("CMD {0} -> {1}" -f $cmdName, $resolved.Source)
}
$pySrc = (Get-Command python3 -ErrorAction Stop | Select-Object -First 1).Source
if ($pySrc -notlike 'C:\CPTools*') { throw "python3 resolved outside C:\CPTools: $pySrc" }
& g++20 $env:CS_CPP_SRC -o $env:CS_CPP_EXE
if ($LASTEXITCODE -ne 0) { throw "g++20 compile failed ($LASTEXITCODE)" }
$cppOut = & $env:CS_CPP_EXE
if ($LASTEXITCODE -ne 0 -or ($cppOut -join '') -notmatch 'CONTEST_CPP20_OK:42') { throw "C++20 execution failed: $($cppOut -join '')" }
$pyOut = & python3 $env:CS_PY_SRC
if ($LASTEXITCODE -ne 0 -or ($pyOut -join '') -notmatch 'CONTEST_PY310_OK:3\.10:310') { throw "Python 3.10 execution failed: $($pyOut -join '')" }
Write-Output 'STUDENT_TOOLCHAIN_OK'
'@
  $studentProbeFile = Join-Path $env:TEMP 'cs_student_probe.ps1'
  Write-Utf8NoBomText -Path $studentProbeFile -Content $studentProbe
  try {
    $env:CS_CPP_SRC = $cpp20Src
    $env:CS_CPP_EXE = $cpp20Exe
    $env:CS_PY_SRC = $py310Src
    [void](Invoke-Ps51Script -ScriptPath $studentProbeFile)
  } finally {
    Remove-Item -LiteralPath $studentProbeFile -Force -ErrorAction SilentlyContinue
  }

  # Verify ExportCache builds a complete offline bundle
  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'ExportCache',
    '-CacheDir', $CacheBundleDir,
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-NoPause'
  ))
  $cacheManifestFile = Join-Path $CacheBundleDir 'cache-manifest.json'
  Assert-True (Test-Path -LiteralPath $cacheManifestFile) 'Missing ExportCache cache-manifest.json'
  $cacheManifest = (Read-Utf8TextSafe -Path $cacheManifestFile) | ConvertFrom-Json
  Assert-True (@($cacheManifest.Installers).Count -eq 4) "Expected 4 installers in cache-manifest.json, got $(@($cacheManifest.Installers).Count)"
  Assert-True ([int]$cacheManifest.VSCodeExtensionsCount -ge 4) "Expected >= 4 VSCode extensions in cache, got $($cacheManifest.VSCodeExtensionsCount)"
  Assert-True (Test-Path -LiteralPath (Join-Path $CacheBundleDir 'scripts\install-env.ps1')) 'ExportCache missing scripts\install-env.ps1'
  $exportedLibFiles = @(Get-ChildItem -LiteralPath (Join-Path $CacheBundleDir 'scripts\lib') -Filter '*.ps1' -File -ErrorAction Stop)
  Assert-True ($exportedLibFiles.Count -eq 8) "Expected 8 lib/*.ps1 in ExportCache, got $($exportedLibFiles.Count)"
  Remove-Item -LiteralPath $CacheBundleDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 6: Automated Post-Contest Restoration via SYSTEM Scheduled Task
  # ==========================================================================
  Write-CiGroup 'Phase 6: Trigger SYSTEM Scheduled Task ContestSetupRestoreAndCleanup & Verify Complete Restoration'

  Start-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup'
  Wait-ContestRestoreAndCleanupComplete -ContestRoot $ContestRoot -TimeoutSeconds 240

  # 6.1 C:\CPTools completely deleted
  Assert-True (-not (Test-Path -LiteralPath $ContestRoot)) "Expected $ContestRoot to be completely removed after restore"

  # 6.2 Student source code backed up and .exe binaries excluded
  $backupDirs = @(Get-WorkspaceBackupDirectories)
  Assert-True ($backupDirs.Count -ge 1) 'Expected student workspace backup directory after post-contest restore'
  $latestBak = $backupDirs[0].FullName
  $bakCpp = Join-Path $latestBak 'sol_cpp20.cpp'
  $bakPy = Join-Path $latestBak 'sub\sol_py310.py'
  Assert-True (Test-Path -LiteralPath $bakCpp) "Missing backed-up sol_cpp20.cpp in $latestBak"
  Assert-True (Test-Path -LiteralPath $bakPy) "Missing backed-up sub\sol_py310.py in $latestBak"
  Assert-True ((Read-Utf8TextSafe -Path $bakCpp) -match 'CONTEST_CPP20_OK') 'Backed-up C++20 source content mismatch'
  Assert-True ((Read-Utf8TextSafe -Path $bakPy) -match 'CONTEST_PY310_OK') 'Backed-up Python3 source content mismatch'
  $exeInBak = @(Get-ChildItem -LiteralPath $latestBak -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue)
  Assert-True ($exeInBak.Count -eq 0) "Unexpected .exe binary found in workspace backup: $($exeInBak.Name -join ',')"

  # 6.3 All 3 Scheduled Tasks unregistered
  foreach ($tn in @('ContestSetupRestoreAndCleanup', 'ContestSetupExamStartEnforcement', 'ContestSetupRestoreAiHostsBlock')) {
    $leftTask = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Assert-True ($null -eq $leftTask) "Scheduled task '$tn' was not unregistered"
  }

  # 6.4 Desktop shortcut restored to pre-contest target + args + description
  $wshPost = New-Object -ComObject WScript.Shell
  try {
    $restSc = $wshPost.CreateShortcut($DesktopShortcutPath)
    Assert-True ($restSc.TargetPath -ieq (Join-Path $env:WINDIR 'System32\notepad.exe')) "Desktop shortcut target not restored: $($restSc.TargetPath)"
    Assert-True ($restSc.Arguments -eq '--pre-contest-user') "Desktop shortcut args not restored: $($restSc.Arguments)"
    Assert-True ($restSc.Description -eq 'Pre-Contest User VS Code') "Desktop shortcut description not restored: $($restSc.Description)"
  } finally {
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wshPost) } catch {}
  }

  # 6.5 hosts file unblocked & custom judge line preserved
  $hostsAfterRestore = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsAfterRestore -notmatch 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'hosts still contains CP_CONTEST_AI_BLOCKLIST_BEGIN'
  Assert-True ($hostsAfterRestore -notmatch 'CP_CONTEST_AI_BLOCKLIST_END') 'hosts still contains CP_CONTEST_AI_BLOCKLIST_END'
  Assert-True ($hostsAfterRestore -notmatch '(?m)^0\.0\.0\.0\s+chatgpt\.com\s*$') 'hosts still blocks chatgpt.com'
  Assert-True ($hostsAfterRestore -match [regex]::Escape($JudgeHostLine)) 'Custom judge host line was lost after restore'

  # 6.6 HKLM Browser Policies restored (existing Chrome value restored to 'automatic', newly added Naver Whale pruned)
  $chromeAfter = (Get-ItemProperty -LiteralPath $ChromePolicyPath -Name 'DnsOverHttpsMode' -ErrorAction Stop).DnsOverHttpsMode
  Assert-True ($chromeAfter -eq 'automatic') "Chrome DnsOverHttpsMode expected 'automatic' after restore, got '$chromeAfter'"
  if (Test-Path -LiteralPath $WhalePolicyPath) {
    $whaleProp = Get-ItemProperty -LiteralPath $WhalePolicyPath -Name 'DnsOverHttpsMode' -ErrorAction SilentlyContinue
    Assert-True ($null -eq $whaleProp) 'Naver Whale DnsOverHttpsMode policy was not pruned after restore'
  }

  # 6.7 Registry User & Machine PATH restored with REG_EXPAND_SZ preserved and zero C:\CPTools entries
  $postUserRaw = Get-RegistryPathRaw -Scope 'User'
  $postMachineRaw = Get-RegistryPathRaw -Scope 'Machine'
  Assert-True ($postUserRaw.Kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) "User PATH lost REG_EXPAND_SZ kind: $($postUserRaw.Kind)"
  Assert-True ($postUserRaw.Value -match '%SystemRoot%') "User PATH lost unexpanded %SystemRoot%: $($postUserRaw.Value)"
  Assert-True ($postUserRaw.Value -match 'C:\\PreExistingUserTool') "User PATH lost C:\PreExistingUserTool: $($postUserRaw.Value)"
  Assert-True ($postUserRaw.Value -notmatch 'C:\\CPTools') "User PATH still contains C:\CPTools: $($postUserRaw.Value)"
  Assert-True ($postMachineRaw.Value -match 'C:\\PreExistingMachineTool') "Machine PATH lost C:\PreExistingMachineTool: $($postMachineRaw.Value)"
  Assert-True ($postMachineRaw.Value -notmatch 'C:\\CPTools') "Machine PATH still contains C:\CPTools: $($postMachineRaw.Value)"

  # 6.8 MSYS2 preserved + zero .contest-bak or custom PEM leftovers
  Assert-True (Test-Path -LiteralPath "$env:SystemDrive\msys64\usr\bin\bash.exe") 'C:\msys64\usr\bin\bash.exe should remain preserved after restore'
  $bakFiles = @(Get-ChildItem -LiteralPath "$env:SystemDrive\msys64\etc" -Filter '*.contest-bak' -Recurse -File -ErrorAction SilentlyContinue)
  Assert-True ($bakFiles.Count -eq 0) "Found leftover .contest-bak files under C:\msys64\etc"
  Assert-True (-not (Test-Path -LiteralPath "$env:SystemDrive\msys64\etc\pki\ca-trust\source\anchors\contestsetup-windows-roots.pem")) 'Leftover contestsetup-windows-roots.pem remained'

  # 6.9 Personal VS Code config and extensions completely untouched
  Assert-True ((Read-Utf8TextSafe -Path $PersonalVsCodeSettings) -match 'contestCiSentinel') 'Personal VS Code settings.json was modified or deleted'
  Assert-True (Test-Path -LiteralPath $PersonalVsCodeExtPkg) 'Personal VS Code extension was deleted'

  # 6.10 Post-restore -Mode Verify MUST fail (non-zero exit code)
  $verifyPostRestoreRc = Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @(
    '-Mode', 'Verify',
    '-ExamStart', $examStart,
    '-ExamEnd', $examEnd,
    '-RestoreAt', $examEnd,
    '-NoPause'
  ) -AllowNonZeroExit
  Assert-True ($verifyPostRestoreRc -ne 0) "Expected -Mode Verify to return non-zero after full restore, got $verifyPostRestoreRc"
  Write-Host 'All 10 SYSTEM Automated Restore assertions passed.' -ForegroundColor Green
  Write-CiEndGroup

  # ==========================================================================
  # PHASE 7: Standalone install-ai-hosts.ps1 + Manual Operator -Mode Restore
  # ==========================================================================
  Write-CiGroup 'Phase 7: Standalone install-ai-hosts.ps1 + Manual Operator install-env.ps1 -Mode Restore'

  [void](Invoke-Ps51Script -ScriptPath $InstallAiHostsPs1 -Arguments @('-NoSchedule', '-Root', $ContestRoot))
  $hostsStandalone = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsStandalone -match 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'install-ai-hosts.ps1 did not block hosts'

  $manualSrc = Join-Path $ContestRoot 'contest\manual_restore_check.cpp'
  Write-Utf8NoBomText -Path $manualSrc -Content 'int main(){return 0;}'

  [void](Invoke-Ps51Script -ScriptPath $InstallEnvPs1 -Arguments @('-Mode', 'Restore', '-Root', $ContestRoot, '-NoPause'))
  Wait-ContestRestoreAndCleanupComplete -ContestRoot $ContestRoot -TimeoutSeconds 120
  $hostsFinal = Read-Utf8TextSafe -Path $HostsPath
  Assert-True ($hostsFinal -notmatch 'CP_CONTEST_AI_BLOCKLIST_BEGIN') 'Manual -Mode Restore left CP_CONTEST_AI_BLOCKLIST_BEGIN behind'
  Assert-True ($hostsFinal -match [regex]::Escape($JudgeHostLine)) 'Manual -Mode Restore lost custom judge host line'
  Assert-True (-not (Test-Path -LiteralPath $ContestRoot)) "Manual -Mode Restore failed to remove $ContestRoot"
  $finalBackups = @(Get-WorkspaceBackupDirectories)
  $hasManualCpp = $false
  foreach ($bDir in $finalBackups) {
    if (Test-Path -LiteralPath (Join-Path $bDir.FullName 'manual_restore_check.cpp')) { $hasManualCpp = $true; break }
  }
  Assert-True $hasManualCpp 'Manual -Mode Restore did not back up manual_restore_check.cpp'

  Write-Host 'FULL WINDOWS LIFECYCLE E2E VERIFICATION PASSED (ALL 7 PHASES).' -ForegroundColor Green
  Write-CiEndGroup
}
catch {
  Dump-ContestDiagnostics -ContestRoot $ContestRoot
  throw
}
finally {
  foreach ($cleanupPath in @($ContestRoot, $CacheBundleDir, $PersonalVsCodeSettings, (Split-Path -Path $PersonalVsCodeExtPkg -Parent))) {
    if (-not [string]::IsNullOrWhiteSpace($cleanupPath) -and (Test-Path -LiteralPath $cleanupPath)) {
      Remove-Item -LiteralPath $cleanupPath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  foreach ($bDir in @(Get-WorkspaceBackupDirectories)) {
    Remove-Item -LiteralPath $bDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}
