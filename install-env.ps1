# install-env.ps1
# ContestSetup v2.0 -- Hybrid Local-First & Staged Modular Contest Environment Installer
# Default Exam Schedule: Monday, November 23, 2026, 19:00 ~ 20:30 (Auto-Restore: 2026-11-23T20:30:00 KST)

[CmdletBinding()]
param(
  [ValidateSet('Install', 'Status', 'Verify', 'Restore', 'DryRun', 'ExportCache')]
  [string]$Mode = 'Install',
  [string]$ExamStart = '2026-11-23T19:00:00',
  [string]$ExamEnd = '2026-11-23T20:30:00',
  [string]$RestoreAt = '2026-11-23T20:30:00',
  [string]$Root = "$env:SystemDrive\CPTools",
  [string]$MsysRoot = "$env:SystemDrive\msys64",
  [string]$CacheDir = '',
  [string]$Msys2CaCertificatePath = '',
  [string]$PythonVersion = '3.10.11',
  [string]$TargetUserSid = '',
  [string]$TargetUserProfile = '',
  [switch]$IncludeVisualStudio,
  [switch]$ForceUpdate,
  [switch]$NoRestoreTask,
  [switch]$NoRestoreShutdown,
  [switch]$RollbackOnFailure,
  [switch]$UseRemote,
  [switch]$KeepVSCode,
  [switch]$NoPause,
  [switch]$SkipSignatureCheck,
  [switch]$DeferAiBlockUntilExamStart
)

$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Normalize-InstallPath
{
  param([AllowNull()] [AllowEmptyString()] [string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $Trimmed = $PathValue.Trim()
  try
  {
    if ([IO.Path]::IsPathRooted($Trimmed))
    {
      $Full = [IO.Path]::GetFullPath($Trimmed)
      if ($Full -match '^[A-Za-z]:[\\/]$') { return ($Full.Substring(0, 2) + '\') }
      return $Full.TrimEnd('\', '/')
    }
  }
  catch {}
  if ($Trimmed -match '^[A-Za-z]:[\\/]$') { return ($Trimmed.Substring(0, 2) + '\') }
  return $Trimmed.TrimEnd('\', '/')
}

# Honor explicit CLI arguments first ($PSBoundParameters), then CONTEST_* env vars, then defaults (including irm|iex).
$BoundParamMap = @{}
if (Get-Variable -Name 'PSBoundParameters' -ErrorAction SilentlyContinue)
{
  if ($null -ne $PSBoundParameters) { $BoundParamMap = $PSBoundParameters }
}

foreach ($StringParam in @(
  @{ Name = 'Mode';                   Env = 'CONTEST_MODE';                Default = 'Install';                  AllowEmpty = $false },
  @{ Name = 'ExamStart';              Env = 'CONTEST_EXAM_START';          Default = '2026-11-23T19:00:00';      AllowEmpty = $false },
  @{ Name = 'ExamEnd';                Env = 'CONTEST_EXAM_END';            Default = '2026-11-23T20:30:00';      AllowEmpty = $false },
  @{ Name = 'RestoreAt';              Env = 'CONTEST_RESTORE_AT';          Default = '2026-11-23T20:30:00';      AllowEmpty = $false },
  @{ Name = 'Root';                   Env = 'CONTEST_ROOT';                Default = "$env:SystemDrive\CPTools"; AllowEmpty = $false },
  @{ Name = 'MsysRoot';               Env = 'CONTEST_MSYS_ROOT';           Default = "$env:SystemDrive\msys64";  AllowEmpty = $false },
  @{ Name = 'CacheDir';               Env = 'CONTEST_CACHE_DIR';           Default = '';                         AllowEmpty = $true  },
  @{ Name = 'Msys2CaCertificatePath'; Env = 'CONTEST_MSYS2_CA_PATH';       Default = '';                         AllowEmpty = $true  },
  @{ Name = 'PythonVersion';          Env = 'CONTEST_PYTHON_VERSION';      Default = '3.10.11';                  AllowEmpty = $false },
  @{ Name = 'TargetUserSid';          Env = 'CONTEST_TARGET_USER_SID';     Default = '';                         AllowEmpty = $true  },
  @{ Name = 'TargetUserProfile';      Env = 'CONTEST_TARGET_USER_PROFILE'; Default = '';                         AllowEmpty = $true  }
)) {
  if (-not $BoundParamMap.ContainsKey($StringParam.Name))
  {
    $EnvVal = [Environment]::GetEnvironmentVariable($StringParam.Env)
    if (-not [string]::IsNullOrWhiteSpace($EnvVal))
    {
      Set-Variable -Name $StringParam.Name -Value $EnvVal
    }
    else
    {
      $ExistingVar = Get-Variable -Name $StringParam.Name -ErrorAction SilentlyContinue
      if ($null -eq $ExistingVar -or $null -eq $ExistingVar.Value -or ((-not $StringParam.AllowEmpty) -and [string]::IsNullOrWhiteSpace([string]$ExistingVar.Value)))
      {
        Set-Variable -Name $StringParam.Name -Value $StringParam.Default
      }
    }
  }
}

$AllowedModes = @('Install', 'Status', 'Verify', 'Restore', 'DryRun', 'ExportCache')
if ($AllowedModes -notcontains $Mode)
{
  throw "Invalid Mode '$Mode'. Supported modes: $($AllowedModes -join ', ')."
}

$Root = Normalize-InstallPath $Root
$MsysRoot = Normalize-InstallPath $MsysRoot
if (-not [string]::IsNullOrWhiteSpace($CacheDir)) { $CacheDir = Normalize-InstallPath $CacheDir }
if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = Normalize-InstallPath $TargetUserProfile }

foreach ($SwitchDef in @(
  @{ Name = 'IncludeVisualStudio';        Env = 'CONTEST_INCLUDE_VS' },
  @{ Name = 'ForceUpdate';                Env = 'CONTEST_FORCE_UPDATE' },
  @{ Name = 'NoRestoreTask';              Env = 'CONTEST_NO_RESTORE_TASK' },
  @{ Name = 'NoRestoreShutdown';          Env = 'CONTEST_NO_RESTORE_SHUTDOWN' },
  @{ Name = 'RollbackOnFailure';          Env = 'CONTEST_ROLLBACK_ON_FAILURE' },
  @{ Name = 'UseRemote';                  Env = 'CONTEST_USE_REMOTE' },
  @{ Name = 'KeepVSCode';                 Env = 'CONTEST_KEEP_VSCODE' },
  @{ Name = 'NoPause';                    Env = 'CONTEST_NO_PAUSE' },
  @{ Name = 'SkipSignatureCheck';         Env = 'CONTEST_SKIP_SIGNATURE_CHECK' },
  @{ Name = 'DeferAiBlockUntilExamStart'; Env = 'CONTEST_DEFER_AI_BLOCK' }
)) {
  $VarObj = Get-Variable -Name $SwitchDef.Name -ErrorAction SilentlyContinue
  $EnvVal = [Environment]::GetEnvironmentVariable($SwitchDef.Env)
  if (-not $BoundParamMap.ContainsKey($SwitchDef.Name))
  {
    if (-not [string]::IsNullOrWhiteSpace($EnvVal))
    {
      $BoolVal = ($EnvVal -match '^(?i)(1|true|yes|on)$')
      Set-Variable -Name $SwitchDef.Name -Value $BoolVal
    }
    elseif ($null -eq $VarObj)
    {
      Set-Variable -Name $SwitchDef.Name -Value $false
    }
  }
}

$RepoOwner = 'naixt1478'
$RepoName = 'ContestSetup'
$Branch = 'main'
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

function Test-IsAdmin
{
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell
{
  $WinPs = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  if (Test-Path -LiteralPath $WinPs) { return $WinPs }
  $PwshCandidates = @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue)
  foreach ($Candidate in $PwshCandidates)
  {
    if ($Candidate -and $Candidate.Source -and ($Candidate.Source -notmatch '\\WindowsApps\\pwsh\.exe$'))
    {
      return $Candidate.Source
    }
  }
  return $WinPs
}

function Quote-ProcessArgument
{
  param([AllowNull()] [object]$Value)
  if ($null -eq $Value) { return '""' }
  $Text = [string]$Value
  if ([string]::IsNullOrEmpty($Text)) { return '""' }
  if ($Text -notmatch '[\s"]') { return $Text }
  $Escaped = $Text -replace '(\\*)"', '$1$1\"'
  $Escaped = $Escaped -replace '(\\+)$', '$1$1'
  return '"' + $Escaped + '"'
}

function Write-ScriptUtf8Bom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$Content
  )
  $Dir = [IO.Path]::GetDirectoryName($Path)
  if (-not [string]::IsNullOrWhiteSpace($Dir))
  {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  }
  $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8Bom)
}

function Assert-PowerShellSyntaxValid
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path
  )
  $ParseErrors = $null
  $Tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
  if ($null -ne $ParseErrors -and $ParseErrors.Count -gt 0)
  {
    $FirstErr = $ParseErrors[0].Message
    throw "PowerShell AST syntax validation failed for '$Path': $FirstErr"
  }
}

function Fetch-RemoteScriptContentWithRetry
{
  param(
    [Parameter(Mandatory = $true)] [string]$ScriptName,
    [int]$MaxAttempts = 3
  )
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $LastErr = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      $CacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $Uri = "{0}/{1}?cb={2}" -f $RawBase.TrimEnd('/'), $ScriptName, $CacheBust
      $OldProgressPref = $ProgressPreference
      try
      {
        $ProgressPreference = 'SilentlyContinue'
        $Params = @{
          Uri         = $Uri
          Headers     = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
          ErrorAction = 'Stop'
        }
        if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
        $Response = Invoke-WebRequest @Params
        $Content = $null
        if ($Response.RawContentStream -and $Response.RawContentStream.Length -gt 0)
        {
          $Response.RawContentStream.Position = 0
          $Reader = New-Object System.IO.StreamReader($Response.RawContentStream, [System.Text.Encoding]::UTF8, $true)
          $Content = $Reader.ReadToEnd()
          $Reader.Dispose()
        }
        else
        {
          $Content = [string]$Response.Content
        }
        if ([string]::IsNullOrWhiteSpace($Content))
        {
          throw "Downloaded script '$ScriptName' is empty."
        }
        return $Content
      }
      finally
      {
        $ProgressPreference = $OldProgressPref
      }
    }
    catch
    {
      $LastErr = $_
      if ($Attempt -lt $MaxAttempts)
      {
        Write-Warning "Failed to fetch $ScriptName (attempt $Attempt/$MaxAttempts): $($_.Exception.Message). Retrying..."
        Start-Sleep -Seconds 2
      }
    }
  }
  throw "Failed to fetch $ScriptName after $MaxAttempts attempts: $($LastErr.Exception.Message)"
}

function Show-SetupResultMessage
{
  param(
    [Parameter(Mandatory = $true)] [string]$Title,
    [Parameter(Mandatory = $true)] [string]$Message,
    [ValidateSet('Information', 'Error', 'Warning')] [string]$Icon = 'Information'
  )

  if ($NoPause)
  {
    Write-Host ''
    Write-Host "[$Icon] $Title" -ForegroundColor Cyan
    Write-Host $Message
    return
  }

  try
  {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $MessageBoxIcon = [System.Enum]::Parse([System.Windows.Forms.MessageBoxIcon], $Icon)
    [System.Windows.Forms.MessageBox]::Show(
      $Message,
      $Title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      $MessageBoxIcon
    ) | Out-Null
    return
  }
  catch {}

  try
  {
    $PopupIcon = switch ($Icon) {
      'Error' { 16 }
      'Warning' { 48 }
      default { 64 }
    }
    $Shell = New-Object -ComObject WScript.Shell
    $Shell.Popup($Message, 0, $Title, $PopupIcon) | Out-Null
  }
  catch
  {
    Write-Host ''
    Write-Host $Title -ForegroundColor Yellow
    Write-Host $Message
  }
}

# Non-admin read-only modes (DryRun, Status, Verify) run without forced UAC relaunch; mutating modes elevate.
if (-not (Test-IsAdmin) -and ($Mode -notin @('DryRun', 'Status', 'Verify')))
{
  Write-Host 'Requesting administrator permission...' -ForegroundColor Yellow

  # Capture invoking student SID and profile BEFORE UAC elevation so over-the-shoulder admin UAC still configures the student account
  if ([string]::IsNullOrWhiteSpace($TargetUserSid))
  {
    try { $TargetUserSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE))
  {
    $TargetUserProfile = Normalize-InstallPath $env:USERPROFILE
  }

  $SelfPath = $PSCommandPath

  if ([string]::IsNullOrWhiteSpace($SelfPath) -or -not (Test-Path -LiteralPath $SelfPath))
  {
    $TempRoot = Join-Path $env:TEMP 'contest-env-installer'
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

    $SelfPath = Join-Path $TempRoot 'install-env.ps1'
    $DownloadedSelf = Fetch-RemoteScriptContentWithRetry -ScriptName 'install-env.ps1'
    Write-ScriptUtf8Bom -Path $SelfPath -Content $DownloadedSelf
    Assert-PowerShellSyntaxValid -Path $SelfPath
  }

  $StartArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $SelfPath,
    '-Mode', $Mode,
    '-ExamStart', $ExamStart,
    '-ExamEnd', $ExamEnd,
    '-RestoreAt', $RestoreAt,
    '-Root', $Root,
    '-MsysRoot', $MsysRoot,
    '-PythonVersion', $PythonVersion
  )

  if (-not [string]::IsNullOrWhiteSpace($CacheDir)) { $StartArgs += @('-CacheDir', $CacheDir) }
  if (-not [string]::IsNullOrWhiteSpace($Msys2CaCertificatePath)) { $StartArgs += @('-Msys2CaCertificatePath', $Msys2CaCertificatePath) }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserSid)) { $StartArgs += @('-TargetUserSid', $TargetUserSid) }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) { $StartArgs += @('-TargetUserProfile', $TargetUserProfile) }
  if ($IncludeVisualStudio) { $StartArgs += '-IncludeVisualStudio' }
  if ($ForceUpdate) { $StartArgs += '-ForceUpdate' }
  if ($NoRestoreTask) { $StartArgs += '-NoRestoreTask' }
  if ($NoRestoreShutdown) { $StartArgs += '-NoRestoreShutdown' }
  if ($RollbackOnFailure) { $StartArgs += '-RollbackOnFailure' }
  if ($UseRemote) { $StartArgs += '-UseRemote' }
  if ($KeepVSCode) { $StartArgs += '-KeepVSCode' }
  if ($NoPause) { $StartArgs += '-NoPause' }
  if ($SkipSignatureCheck) { $StartArgs += '-SkipSignatureCheck' }
  if ($DeferAiBlockUntilExamStart) { $StartArgs += '-DeferAiBlockUntilExamStart' }

  $ArgumentString = ($StartArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
  $ElevatedProc = $null
  try
  {
    $ElevatedProc = Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $ArgumentString -Verb RunAs -Wait -PassThru
  }
  catch [System.ComponentModel.Win32Exception]
  {
    Write-Host ''
    Write-Host "ERROR: Administrator elevation (UAC) was cancelled or declined: $($_.Exception.Message)" -ForegroundColor Red
    if ($PSCommandPath) { exit 1 } else { $global:LASTEXITCODE = 1; return }
  }
  $ExitCode = if ($null -ne $ElevatedProc) { [int]$ElevatedProc.ExitCode } else { 1 }
  if ($PSCommandPath) { exit $ExitCode } else { $global:LASTEXITCODE = $ExitCode; return }
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Disable QuickEdit mode to prevent accidental script pausing when clicking the console
try
{
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
}
catch {}

# Prevent multiple instances from running concurrently
$MutexName = 'Global\ContestSetupEnvironmentMutex'
$Global:SetupMutex = $null
$MutexAcquired = $false
$MutexHeld = $false
$PreviousMutexOwnerPid = $env:CONTEST_MUTEX_OWNER_PID
try
{
  $Global:SetupMutex = New-Object System.Threading.Mutex($false, $MutexName)
  try
  {
    $MutexAcquired = $Global:SetupMutex.WaitOne(0, $false)
  }
  catch [System.Threading.AbandonedMutexException]
  {
    $MutexAcquired = $true
  }

  if (-not $MutexAcquired)
  {
    try { $Global:SetupMutex.Dispose() } catch {}
    $Global:SetupMutex = $null
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' ERROR: Another installation process is already running.' -ForegroundColor Red
    Write-Host ' Please wait for it to finish or close the other window.' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ''
    if (-not $NoPause)
    {
      Write-Host 'This window will close automatically in 5 seconds...' -ForegroundColor Yellow
      Start-Sleep -Seconds 5
    }
    if ($PSCommandPath) { exit 1 } else { $global:LASTEXITCODE = 1; return }
  }

  $env:CONTEST_MUTEX_OWNER_PID = [string]$PID
  $MutexHeld = $true
}
catch
{
  # Non-elevated or restricted token may not access Global\ namespace; proceed without holding mutex
  $MutexAcquired = $false
  $MutexHeld = $false
  if ($Global:SetupMutex)
  {
    try { $Global:SetupMutex.Dispose() } catch {}
    $Global:SetupMutex = $null
  }
  $env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid
}

$SetupSucceeded = $false
$SetupResultMessageShown = $false
$ExitCodeToReturn = 0
$Module = 'initialization'

try
{
  Write-Host 'Contest Environment Setup v2.0 (Hybrid Local-First + Staged Modular)' -ForegroundColor Cyan
  Write-Host "Repository : $RepoOwner/$RepoName ($Branch)"
  Write-Host "Mode       : $Mode"
  Write-Host "Schedule   : $ExamStart ~ $ExamEnd (RestoreAt: $RestoreAt)"
  Write-Host ''

  # Module display names for the outer progress bar
  $ModuleDisplayNames = @{
    'common.ps1'             = 'Core Configuration & Pre-flight'
    'setup-msys2.ps1'        = 'MSYS2 (GCC/GDB)'
    'setup-python.ps1'       = 'Python 3.10'
    'setup-visualstudio.ps1' = 'Visual Studio'
    'setup-vscode.ps1'       = 'VS Code'
    'setup-wrappers.ps1'     = 'Command Wrappers & Tests'
    'setup-ai-hosts.ps1'     = 'AI Hosts Block'
    'setup-restore-task.ps1' = 'Restore Task Scheduler'
  }

  $Modules = @(
    'common.ps1',
    'setup-msys2.ps1',
    'setup-python.ps1',
    'setup-visualstudio.ps1',
    'setup-vscode.ps1',
    'setup-wrappers.ps1',
    'setup-ai-hosts.ps1',
    'setup-restore-task.ps1'
  )

  $AuxiliaryScripts = @(
    'ai-hosts-block.ps1',
    'restore-and-cleanup.ps1'
  )

  $LocalSourceDir = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($LocalSourceDir) -and (-not [string]::IsNullOrWhiteSpace($PSCommandPath)))
  {
    $LocalSourceDir = Split-Path -Path $PSCommandPath -Parent
  }

  $CanUseLocalModules = (-not $UseRemote) -and (-not [string]::IsNullOrWhiteSpace($LocalSourceDir))
  if ($CanUseLocalModules)
  {
    foreach ($ReqScript in $Modules)
    {
      if (-not (Test-Path -LiteralPath (Join-Path $LocalSourceDir $ReqScript)))
      {
        $CanUseLocalModules = $false
        break
      }
    }
  }

  $ScriptStageDir = Join-Path $Root 'scripts'
  $Script:StagedScriptPaths = @{}

  function Resolve-OrStageScriptPath
  {
    param(
      [Parameter(Mandatory = $true)] [string]$ScriptName,
      [switch]$PreferLocalWithoutStaging
    )
    if ($Script:StagedScriptPaths.ContainsKey($ScriptName))
    {
      $CachedPath = [string]$Script:StagedScriptPaths[$ScriptName]
      if (-not [string]::IsNullOrWhiteSpace($CachedPath) -and (Test-Path -LiteralPath $CachedPath))
      {
        if ((-not $PreferLocalWithoutStaging) -and $CanUseLocalModules)
        {
          try
          {
            New-Item -ItemType Directory -Force -Path $ScriptStageDir | Out-Null
            $StagedCopy = Join-Path $ScriptStageDir $ScriptName
            if (-not (Test-Path -LiteralPath $StagedCopy) -and ([IO.Path]::GetFullPath($CachedPath) -ine [IO.Path]::GetFullPath($StagedCopy)))
            {
              Copy-Item -LiteralPath $CachedPath -Destination $StagedCopy -Force
            }
          }
          catch {}
        }
        return $CachedPath
      }
    }

    if ($CanUseLocalModules)
    {
      $LocalPath = Join-Path $LocalSourceDir $ScriptName
      if (Test-Path -LiteralPath $LocalPath)
      {
        Assert-PowerShellSyntaxValid -Path $LocalPath
        if (-not $PreferLocalWithoutStaging)
        {
          try
          {
            New-Item -ItemType Directory -Force -Path $ScriptStageDir | Out-Null
            $StagedCopy = Join-Path $ScriptStageDir $ScriptName
            if ([IO.Path]::GetFullPath($LocalPath) -ine [IO.Path]::GetFullPath($StagedCopy))
            {
              Copy-Item -LiteralPath $LocalPath -Destination $StagedCopy -Force
            }
          }
          catch {}
        }
        $Script:StagedScriptPaths[$ScriptName] = $LocalPath
        return $LocalPath
      }
    }

    New-Item -ItemType Directory -Force -Path $ScriptStageDir | Out-Null
    $StagedPath = Join-Path $ScriptStageDir $ScriptName
    $Content = Fetch-RemoteScriptContentWithRetry -ScriptName $ScriptName
    Write-ScriptUtf8Bom -Path $StagedPath -Content $Content
    Assert-PowerShellSyntaxValid -Path $StagedPath
    $Script:StagedScriptPaths[$ScriptName] = $StagedPath
    return $StagedPath
  }

  # Global progress IDs for two-tier progress bars
  $Global:ProgressIdOuter = 0
  $Global:ProgressIdInner = 1

  $Total = $Modules.Count
  $Step = 1

  # Handle non-install lifecycle modes cleanly without early return skipping post-finally exit code handling
  if ($Mode -in @('Status', 'Verify', 'DryRun'))
  {
    $Module = 'common.ps1'
    $CommonScriptPath = Resolve-OrStageScriptPath -ScriptName 'common.ps1' -PreferLocalWithoutStaging
    . $CommonScriptPath

    if ($Mode -eq 'DryRun')
    {
      $ScheduleReport = Invoke-PreflightChecks -DryRunOnly
      $AuditReport = Invoke-ContestEnvironmentAudit
      Write-Host ''
      Write-Host 'DryRun Validation Complete: No system files were modified.' -ForegroundColor Green
      $SetupSucceeded = $true
      $SetupResultMessageShown = $true
      $ExitCodeToReturn = 0
    }
    else
    {
      $ScheduleReport = Test-ExamScheduleConfiguration -StartText $ExamStart -EndText $ExamEnd -RestoreText $RestoreAt
      Write-Host ("Schedule Target: {0} ~ {1} (Restore: {2})" -f $ScheduleReport.ExamStart.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleReport.ExamEnd.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleReport.RestoreAt.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) -ForegroundColor Cyan
      $AuditReport = Invoke-ContestEnvironmentAudit
      if ($Mode -eq 'Verify')
      {
        if (-not $AuditReport.AllReady)
        {
          Write-Host ''
          Write-Host '[FAIL] Contest environment verification failed: one or more required components are missing or not ready.' -ForegroundColor Red
          $SetupSucceeded = $false
          $SetupResultMessageShown = $true
          $ExitCodeToReturn = 1
        }
        else
        {
          Write-Host ''
          Write-Host '[PASS] Contest environment verification succeeded: all required components are ready.' -ForegroundColor Green
          $SetupSucceeded = $true
          $SetupResultMessageShown = $true
          $ExitCodeToReturn = 0
        }
      }
      else
      {
        $SetupSucceeded = $true
        $SetupResultMessageShown = $true
        $ExitCodeToReturn = 0
      }
    }
  }
  elseif ($Mode -eq 'Restore')
  {
    $Module = 'common.ps1'
    $CommonScriptPath = Resolve-OrStageScriptPath -ScriptName 'common.ps1' -PreferLocalWithoutStaging
    . $CommonScriptPath

    $ResolvedTarget = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
    if ([string]::IsNullOrWhiteSpace($TargetUserSid) -and (-not $ResolvedTarget.IsSystem)) { $TargetUserSid = $ResolvedTarget.Sid }
    if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -and (-not [string]::IsNullOrWhiteSpace($ResolvedTarget.ProfilePath))) { $TargetUserProfile = $ResolvedTarget.ProfilePath }

    $Module = 'restore-and-cleanup.ps1'
    $RestoreScriptToRun = Resolve-OrStageScriptPath -ScriptName 'restore-and-cleanup.ps1' -PreferLocalWithoutStaging
    $RestoreCmdInfo = Get-Command $RestoreScriptToRun -ErrorAction SilentlyContinue
    $SupportsR2RestoreArgs = ($null -ne $RestoreCmdInfo) -and ($null -ne $RestoreCmdInfo.Parameters) -and $RestoreCmdInfo.Parameters.ContainsKey('MsysRoot') -and $RestoreCmdInfo.Parameters.ContainsKey('TargetUserSid')
    if ($SupportsR2RestoreArgs)
    {
      & $RestoreScriptToRun -Root $Root -MsysRoot $MsysRoot -PythonDir $PythonDir -PythonVersion $PythonVersion -TargetUserSid $TargetUserSid -TargetUserProfile $TargetUserProfile -KeepVSCode:$KeepVSCode -NoPause:$NoPause
    }
    else
    {
      & $RestoreScriptToRun -Root $Root -PythonDir $PythonDir -PythonVersion $PythonVersion -NoPause:$NoPause
    }
    $SetupSucceeded = $true
    $SetupResultMessageShown = $true
    $ExitCodeToReturn = 0
  }
  elseif ($Mode -eq 'ExportCache')
  {
    $Module = 'common.ps1'
    $CommonScriptPath = Resolve-OrStageScriptPath -ScriptName 'common.ps1' -PreferLocalWithoutStaging
    . $CommonScriptPath

    $Module = 'ExportCache'
    $ExportRoot = if (-not [string]::IsNullOrWhiteSpace($CacheDir)) { $CacheDir } else { Join-Path $Root 'export-cache' }
    Write-Section "Exporting Offline USB/LAN Cache Bundle to $ExportRoot"
    New-Item -ItemType Directory -Force -Path $ExportRoot | Out-Null
    $ExportScriptsDir = Join-Path $ExportRoot 'scripts'
    $ExportExtDir = Join-Path $ExportRoot 'vscode-extensions'
    $ExportPkgDir = Join-Path $ExportRoot 'msys2-pkg'
    $ExportSyncDir = Join-Path $ExportRoot 'msys2-sync'
    New-Item -ItemType Directory -Force -Path $ExportScriptsDir, $ExportExtDir, $ExportPkgDir, $ExportSyncDir | Out-Null

    $BundleInstallers = @(
      [pscustomobject]@{ Name = 'MSYS2 Installer';            Url = $Msys2InstallerUrl; OutFile = $Msys2InstallerPath; MinBytes = 40MB },
      [pscustomobject]@{ Name = "Python $PythonVersion EXE";  Url = $PythonUrl;         OutFile = $PythonInstaller;    MinBytes = 15MB },
      [pscustomobject]@{ Name = "Python $PythonVersion NuGet"; Url = $PythonNugetUrl;   OutFile = $PythonNugetArchive; MinBytes = 5MB  },
      [pscustomobject]@{ Name = 'VS Code Standalone Archive'; Url = $VSCodeArchiveUrl;  OutFile = $VSCodeArchivePath;  MinBytes = 50MB }
    )
    Invoke-ParallelDownloadFiles -Downloads $BundleInstallers

    $ExportedInstallers = New-Object System.Collections.Generic.List[string]
    foreach ($BundleItem in $BundleInstallers)
    {
      $DestInstaller = Join-Path $ExportRoot ([IO.Path]::GetFileName($BundleItem.OutFile))
      if ([IO.Path]::GetFullPath($BundleItem.OutFile) -ine [IO.Path]::GetFullPath($DestInstaller))
      {
        Copy-Item -LiteralPath $BundleItem.OutFile -Destination $DestInstaller -Force
      }
      $ExportedInstallers.Add([IO.Path]::GetFileName($DestInstaller)) | Out-Null
    }

    $SourceExtDir = Join-Path $Root 'vscode-contest\extensions'
    $ExportedExtCount = 0
    if (Test-Path -LiteralPath $SourceExtDir)
    {
      & robocopy.exe $SourceExtDir $ExportExtDir '/MIR' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' '/MT:16' | Out-Null
      if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy of VS Code extensions returned code $LASTEXITCODE" }
      $ExportedExtCount = @(Get-ChildItem -LiteralPath $ExportExtDir -Directory -ErrorAction SilentlyContinue).Count
    }

    $PacmanPkgCache = Join-Path $MsysRoot 'var\cache\pacman\pkg'
    $ExportedPkgCount = 0
    if (Test-Path -LiteralPath $PacmanPkgCache)
    {
      foreach ($PkgFile in @(Get-ChildItem -Path $PacmanPkgCache -Filter '*.pkg.tar.*' -File -ErrorAction SilentlyContinue))
      {
        Copy-Item -LiteralPath $PkgFile.FullName -Destination (Join-Path $ExportPkgDir $PkgFile.Name) -Force
        $ExportedPkgCount++
      }
    }
    $PacmanSyncCache = Join-Path $MsysRoot 'var\lib\pacman\sync'
    if (Test-Path -LiteralPath $PacmanSyncCache)
    {
      foreach ($DbFile in @(Get-ChildItem -Path $PacmanSyncCache -Filter '*.db*' -File -ErrorAction SilentlyContinue))
      {
        Copy-Item -LiteralPath $DbFile.FullName -Destination (Join-Path $ExportSyncDir $DbFile.Name) -Force
      }
    }

    $AllRepoScripts = @('install-env.ps1', 'install-ai-hosts.ps1') + $Modules + $AuxiliaryScripts
    foreach ($ScriptItem in ($AllRepoScripts | Select-Object -Unique))
    {
      try
      {
        $ResolvedScript = Resolve-OrStageScriptPath -ScriptName $ScriptItem -PreferLocalWithoutStaging
        Copy-Item -LiteralPath $ResolvedScript -Destination (Join-Path $ExportScriptsDir $ScriptItem) -Force
      }
      catch
      {
        Write-Warning "Could not bundle script ${ScriptItem}: $($_.Exception.Message)"
      }
    }

    $CacheManifest = [ordered]@{
      Version               = $ContestSetupVersion
      ExportedAt            = (Get-Date -Format 'o')
      PythonVersion         = $PythonVersion
      Installers            = @($ExportedInstallers.ToArray())
      VSCodeExtensionsCount = $ExportedExtCount
      Msys2PackagesCount    = $ExportedPkgCount
    }
    Write-JsonUtf8NoBom -Path (Join-Path $ExportRoot 'cache-manifest.json') -InputObject $CacheManifest -Depth 10
    if ($ExportedExtCount -lt 4 -or $ExportedPkgCount -eq 0)
    {
      Write-Warning "ExportCache bundle is missing pre-installed components (VSCodeExtensionsCount=$ExportedExtCount, Msys2PackagesCount=$ExportedPkgCount). Run '.\install-env.ps1 -NoPause' first before '-Mode ExportCache' so all 4 VS Code extensions and MSYS2 pacman packages are populated for zero-bandwidth offline installs."
    }
    Write-Host "Offline cache bundle exported successfully to: $ExportRoot" -ForegroundColor Green
    $SetupSucceeded = $true
    $SetupResultMessageShown = $true
    $ExitCodeToReturn = 0
  }
  else
  {
    # Mode == 'Install': Stage all modules & auxiliary scripts upfront when running in remote mode
    if (-not $CanUseLocalModules)
    {
      Write-Host "Staging scripts into $ScriptStageDir ..." -ForegroundColor Cyan
      foreach ($ScriptToStage in ($Modules + $AuxiliaryScripts))
      {
        Resolve-OrStageScriptPath -ScriptName $ScriptToStage | Out-Null
      }
    }
    else
    {
      Write-Host "Using local modules from $LocalSourceDir ..." -ForegroundColor Green
      foreach ($AuxScript in $AuxiliaryScripts)
      {
        Resolve-OrStageScriptPath -ScriptName $AuxScript | Out-Null
      }
    }

    foreach ($Module in $Modules)
    {
      $Global:SetupStepCurrent = $Step
      $Global:SetupStepTotal = $Total
      $Global:SetupModuleName = $Module

      $DisplayName = if ($ModuleDisplayNames.ContainsKey($Module)) { $ModuleDisplayNames[$Module] } else { $Module }
      $OuterPercent = [math]::Floor((($Step - 1) / $Total) * 100)
      Write-Progress -Id $Global:ProgressIdOuter -Activity 'Contest Environment Setup v2.0' -Status "[$Step/$Total] $DisplayName" -PercentComplete $OuterPercent

      Write-Host "[$Step/$Total] Running $Module ($DisplayName)..." -ForegroundColor Yellow
      $ModuleFilePath = Resolve-OrStageScriptPath -ScriptName $Module

      if (($Module -eq 'setup-ai-hosts.ps1') -and $DeferAiBlockUntilExamStart -and ((Read-TextUtf8 -Path $ModuleFilePath) -notmatch 'DeferAiBlockUntilExamStart'))
      {
        $AiStagedSource = Resolve-OrStageScriptPath -ScriptName 'ai-hosts-block.ps1'
        $AiDestRoot = Join-Path $Root 'ai-hosts-block.ps1'
        $AiDestSub = Join-Path (Join-Path $Root 'ai-block') 'ai-hosts-block.ps1'
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'ai-block') | Out-Null
        if ([IO.Path]::GetFullPath($AiStagedSource) -ine [IO.Path]::GetFullPath($AiDestRoot)) { Copy-Item -LiteralPath $AiStagedSource -Destination $AiDestRoot -Force }
        if ([IO.Path]::GetFullPath($AiStagedSource) -ine [IO.Path]::GetFullPath($AiDestSub)) { Copy-Item -LiteralPath $AiStagedSource -Destination $AiDestSub -Force }
        Write-Host "Deferred immediate AI hosts blocking until ExamStart ($ExamStart) per -DeferAiBlockUntilExamStart." -ForegroundColor Yellow
      }
      else
      {
        . $ModuleFilePath
      }

      if ($Module -eq 'common.ps1')
      {
        Start-SetupLogging
        Invoke-PreflightChecks | Out-Null

        $ResolvedUser = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
        if (-not $ResolvedUser.IsSystem)
        {
          if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = $ResolvedUser.Sid }
          if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -and (-not [string]::IsNullOrWhiteSpace($ResolvedUser.ProfilePath))) { $TargetUserProfile = $ResolvedUser.ProfilePath }
        }
        Update-ContestStateManifest -CompletedModule 'common.ps1' -Properties @{
          TargetUserSid     = $TargetUserSid
          TargetUserProfile = $TargetUserProfile
          MsysRoot          = $MsysRoot
        }

        $ExistingBackups = @(Get-ChildItem -Path $BackupDir -Filter 'path-*' -Directory -ErrorAction SilentlyContinue | Where-Object {
          Test-Path -LiteralPath (Join-Path $_.FullName 'path-environment-before-cleanup.txt')
        })
        if ($ExistingBackups.Count -eq 0)
        {
          Backup-PathEnvironment -BackupRoot (Join-Path $BackupDir ("path-$TimeStamp"))
        }
        else
        {
          Write-Host 'PATH backup already exists. Skipping to preserve original state.' -ForegroundColor Gray
        }

        # Parallel Prefetch of required installers that are not yet installed
        $PrefetchItems = New-Object System.Collections.Generic.List[object]
        if (-not (Test-Path -LiteralPath $MsysBash))
        {
          $PrefetchItems.Add([pscustomobject]@{
            Name     = 'MSYS2 Installer'
            Url      = $Msys2InstallerUrl
            OutFile  = $Msys2InstallerPath
            MinBytes = 40MB
          }) | Out-Null
        }
        if (-not (Test-Path -LiteralPath $PythonExe))
        {
          $PrefetchItems.Add([pscustomobject]@{
            Name     = "Python $PythonVersion Installer"
            Url      = $PythonUrl
            OutFile  = $PythonInstaller
            MinBytes = 15MB
          }) | Out-Null
        }
        $VSCodePrefetchRoot = Join-Path $Root 'vscode'
        $VSCodeExeCheck = Join-Path $VSCodePrefetchRoot 'Code.exe'
        $VSCodeCmdCheck = Join-Path $VSCodePrefetchRoot 'bin\code.cmd'
        $VSCodeProdCheck = Resolve-VSCodeProductJsonPath -VSCodeRoot $VSCodePrefetchRoot
        if (-not ((Test-Path -LiteralPath $VSCodeExeCheck) -and (Test-Path -LiteralPath $VSCodeCmdCheck) -and (-not [string]::IsNullOrWhiteSpace($VSCodeProdCheck)) -and (Test-Path -LiteralPath $VSCodeProdCheck)))
        {
          $PrefetchItems.Add([pscustomobject]@{
            Name     = 'VS Code Standalone Archive'
            Url      = $VSCodeArchiveUrl
            OutFile  = $VSCodeArchivePath
            MinBytes = 50MB
          }) | Out-Null
        }
        if ($PrefetchItems.Count -gt 0)
        {
          Invoke-ParallelDownloadFiles -Downloads $PrefetchItems.ToArray()
        }
      }
      else
      {
        Update-ContestStateManifest -CompletedModule $Module
      }

      # Clear inner progress bar after each module completes
      Write-Progress -Id $Global:ProgressIdInner -Activity 'Module Detail' -Completed
      $Step++
    }

    Write-Progress -Id $Global:ProgressIdOuter -Activity 'Contest Environment Setup v2.0' -Status 'Complete!' -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Id $Global:ProgressIdOuter -Activity 'Contest Environment Setup v2.0' -Completed

    Write-Host ''
    Write-Host 'All setup and verification steps completed successfully.' -ForegroundColor Green
    Write-Host 'Important: restart PowerShell and VS Code to reload PATH.' -ForegroundColor Yellow
    $SetupSucceeded = $true
    $ExitCodeToReturn = 0

    # Flush and close transcript BEFORE opening modal GUI dialog so log file is complete on disk
    if (Get-Command Stop-SetupLogging -ErrorAction SilentlyContinue)
    {
      try { Stop-SetupLogging } catch {}
    }

    $LogPath = if (Get-Variable -Name 'TranscriptPath' -ErrorAction SilentlyContinue) { $TranscriptPath } else { $null }
    $SuccessMessage = "Contest environment setup v2.0 completed successfully.`r`n`r`nExam Window: $ExamStart ~ $ExamEnd`r`nAuto-Restore: $RestoreAt`r`n`r`nPlease restart PowerShell and VS Code to reload PATH."
    if (-not [string]::IsNullOrWhiteSpace($LogPath))
    {
      $SuccessMessage += "`r`n`r`nLog: $LogPath"
    }
    Show-SetupResultMessage -Title 'Contest Setup Complete' -Message $SuccessMessage -Icon Information
    $SetupResultMessageShown = $true
  }
}
catch
{
  # Stop transcript logging FIRST so the transcript file is flushed and unlocked before any error handling or rollback
  if (Get-Command Stop-SetupLogging -ErrorAction SilentlyContinue)
  {
    try { Stop-SetupLogging } catch {}
  }

  $SetupSucceeded = $false
  $ExitCodeToReturn = 1

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host " FATAL ERROR during $Module" -ForegroundColor Red
  Write-Host " $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '============================================================' -ForegroundColor Red

  if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) { Write-ErrorLog -ErrorRecord $_ }
  $TempLogsDir = if (Get-Command Backup-SetupLogsToTemp -ErrorAction SilentlyContinue) { Backup-SetupLogsToTemp } else { $null }

  if ($RollbackOnFailure)
  {
    Write-Host ''
    Write-Host 'Initiating safe rollback (-RollbackOnFailure) while preserving logs, downloads, and workspace...' -ForegroundColor Yellow
    try
    {
      $RollbackScriptPath = Resolve-OrStageScriptPath -ScriptName 'restore-and-cleanup.ps1' -PreferLocalWithoutStaging
      $RollbackPythonDir = if (Get-Variable -Name 'PythonDir' -ErrorAction SilentlyContinue) { $PythonDir } else { Join-Path $Root 'Python310' }
      $RollbackCmdInfo = Get-Command $RollbackScriptPath -ErrorAction SilentlyContinue
      $SupportsR2RollbackArgs = ($null -ne $RollbackCmdInfo) -and ($null -ne $RollbackCmdInfo.Parameters) -and $RollbackCmdInfo.Parameters.ContainsKey('MsysRoot') -and $RollbackCmdInfo.Parameters.ContainsKey('TargetUserSid')
      if ($SupportsR2RollbackArgs)
      {
        & $RollbackScriptPath -Root $Root -MsysRoot $MsysRoot -PythonDir $RollbackPythonDir -PythonVersion $PythonVersion -TargetUserSid $TargetUserSid -TargetUserProfile $TargetUserProfile -KeepDownloads -KeepLogs -KeepWorkspace -NoPause
      }
      else
      {
        & $RollbackScriptPath -Root $Root -PythonDir $RollbackPythonDir -PythonVersion $PythonVersion -KeepDownloads -KeepLogs -KeepWorkspace -NoPause
      }
      Write-Host 'Safe rollback completed (logs, cached installers, and contest workspace preserved).' -ForegroundColor Green
    }
    catch
    {
      Write-Warning "Automatic rollback encountered an error: $($_.Exception.Message)"
    }
  }
  else
  {
    Write-Host ''
    Write-Host "Preserving $Root\downloads, $Root\logs, and $Root\contest so you can re-run install-env.ps1 to resume." -ForegroundColor Yellow
    if (($Mode -eq 'Install') -and (Get-Command Clear-StaleAiHostsSectionBeforeInstall -ErrorAction SilentlyContinue))
    {
      try { Clear-StaleAiHostsSectionBeforeInstall } catch {}
    }
  }

  $ErrorLog = if (Get-Variable -Name 'ErrorLogPath' -ErrorAction SilentlyContinue) { $ErrorLogPath } else { $null }
  $TranscriptLog = if (Get-Variable -Name 'TranscriptPath' -ErrorAction SilentlyContinue) { $TranscriptPath } else { $null }
  $FailureMessage = "Contest environment setup failed.`r`n`r`nFailed module: $Module`r`nError: $($_.Exception.Message)"
  if (-not [string]::IsNullOrWhiteSpace($ErrorLog))
  {
    $FailureMessage += "`r`n`r`nError log: $ErrorLog"
  }
  if (-not [string]::IsNullOrWhiteSpace($TranscriptLog))
  {
    $FailureMessage += "`r`nTranscript log: $TranscriptLog"
  }
  if (-not [string]::IsNullOrWhiteSpace($TempLogsDir))
  {
    $FailureMessage += "`r`nBackup logs: $TempLogsDir"
  }
  Show-SetupResultMessage -Title 'Contest Setup Failed' -Message $FailureMessage -Icon Error
  $SetupResultMessageShown = $true
}
finally
{
  if (Get-Command Stop-SetupLogging -ErrorAction SilentlyContinue)
  {
    try { Stop-SetupLogging } catch {}
  }

  if ($MutexHeld)
  {
    $env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid
    $MutexHeld = $false
  }

  if ($Global:SetupMutex)
  {
    if ($MutexAcquired)
    {
      try { $Global:SetupMutex.ReleaseMutex() } catch {}
    }
    try { $Global:SetupMutex.Dispose() } catch {}
    $Global:SetupMutex = $null
  }

  if (-not $SetupResultMessageShown)
  {
    $FallbackTitle = if ($SetupSucceeded) { 'Contest Setup Complete' } else { 'Contest Setup Finished' }
    $FallbackIcon = if ($SetupSucceeded) { 'Information' } else { 'Warning' }
    $FallbackMessage = if ($SetupSucceeded) {
      'Contest environment setup completed successfully.'
    } else {
      'Contest environment setup finished, but the final result could not be determined. Please check the console output and logs.'
    }
    Show-SetupResultMessage -Title $FallbackTitle -Message $FallbackMessage -Icon $FallbackIcon
  }

  if (-not $NoPause -and ($Mode -eq 'Install'))
  {
    Write-Host ''
    Write-Host 'This window will close automatically in 5 seconds...' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
}

$FinalExitCode = if ($SetupSucceeded -and ($ExitCodeToReturn -eq 0)) { 0 } else { if ($ExitCodeToReturn -ne 0) { $ExitCodeToReturn } else { 1 } }
if ($FinalExitCode -ne 0)
{
  if ($PSCommandPath)
  {
    exit $FinalExitCode
  }
  else
  {
    $global:LASTEXITCODE = $FinalExitCode
    return
  }
}
$global:LASTEXITCODE = 0
