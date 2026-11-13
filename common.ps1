# common.ps1
# Common variables and shared library module loader for ContestSetup v2.0

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

try
{
  chcp.com 65001 | Out-Null
  [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = [Console]::OutputEncoding
}
catch {}

# Base Paths & Schedule Configuration (Can be overridden by caller variables or environment variables)
function Get-ContestVariableValue
{
  param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [object]$DefaultValue = $null,
    [string]$EnvVar = ''
  )
  foreach ($Scope in @(1, 2, 'Script', 'Global'))
  {
    # Numeric scopes deeper than the current call stack throw ArgumentOutOfRange
    # (not suppressible via -ErrorAction), e.g. when dot-sourced at top level or via irm|iex.
    $Variable = $null
    try { $Variable = Get-Variable -Name $Name -Scope $Scope -ErrorAction Stop }
    catch { $Variable = $null }
    if ($null -ne $Variable -and $null -ne $Variable.Value)
    {
      $Value = $Variable.Value
      if ($DefaultValue -is [bool] -or $Value -is [switch] -or $Value -is [bool])
      {
        return [bool]$Value
      }
      if (-not (($Value -is [string]) -and [string]::IsNullOrWhiteSpace($Value)))
      {
        return $Value
      }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($EnvVar))
  {
    $EnvValue = [Environment]::GetEnvironmentVariable($EnvVar)
    if (-not [string]::IsNullOrWhiteSpace($EnvValue))
    {
      if ($DefaultValue -is [bool])
      {
        return ($EnvValue -match '^(?i)(1|true|yes|on)$')
      }
      return $EnvValue
    }
  }
  return $DefaultValue
}

function Normalize-ContestDirectoryPath
{
  param([AllowNull()] [AllowEmptyString()] [string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $Trimmed = $Path.Trim()
  try
  {
    if ([IO.Path]::IsPathRooted($Trimmed))
    {
      $Full = [IO.Path]::GetFullPath($Trimmed)
      if ($Full -match '^[A-Za-z]:[\\/]$')
      {
        return ($Full.Substring(0, 2) + '\')
      }
      return $Full.TrimEnd('\', '/')
    }
  }
  catch {}
  if ($Trimmed -match '^[A-Za-z]:[\\/]$')
  {
    return ($Trimmed.Substring(0, 2) + '\')
  }
  return $Trimmed.TrimEnd('\', '/')
}

$ContestSetupVersion = '2.0.0'
$RawBase = ([string](Get-ContestVariableValue -Name 'RawBase' -DefaultValue 'https://raw.githubusercontent.com/naixt1478/ContestSetup/main' -EnvVar 'CONTEST_RAW_BASE')).TrimEnd('/')
if ($null -eq (Get-Variable -Scope Global -Name 'ProgressIdOuter' -ErrorAction SilentlyContinue)) { $Global:ProgressIdOuter = 0 }
if ($null -eq (Get-Variable -Scope Global -Name 'ProgressIdInner' -ErrorAction SilentlyContinue)) { $Global:ProgressIdInner = 1 }
if ($null -eq (Get-Variable -Scope Global -Name 'SetupStepCurrent' -ErrorAction SilentlyContinue)) { $Global:SetupStepCurrent = 1 }
if ($null -eq (Get-Variable -Scope Global -Name 'SetupStepTotal' -ErrorAction SilentlyContinue)) { $Global:SetupStepTotal = 1 }
$Mode = [string](Get-ContestVariableValue -Name 'Mode' -DefaultValue 'Install' -EnvVar 'CONTEST_MODE')
$ExamStart = [string](Get-ContestVariableValue -Name 'ExamStart' -DefaultValue '2026-11-23T19:00:00' -EnvVar 'CONTEST_EXAM_START')
$ExamEnd = [string](Get-ContestVariableValue -Name 'ExamEnd' -DefaultValue '2026-11-23T20:30:00' -EnvVar 'CONTEST_EXAM_END')
$RestoreAt = [string](Get-ContestVariableValue -Name 'RestoreAt' -DefaultValue '2026-11-23T20:30:00' -EnvVar 'CONTEST_RESTORE_AT')

$Root = Normalize-ContestDirectoryPath ([string](Get-ContestVariableValue -Name 'Root' -DefaultValue "$env:SystemDrive\CPTools" -EnvVar 'CONTEST_ROOT'))
$MsysRoot = Normalize-ContestDirectoryPath ([string](Get-ContestVariableValue -Name 'MsysRoot' -DefaultValue "$env:SystemDrive\msys64" -EnvVar 'CONTEST_MSYS_ROOT'))
$RawCacheDir = [string](Get-ContestVariableValue -Name 'CacheDir' -DefaultValue '' -EnvVar 'CONTEST_CACHE_DIR')
$CacheDir = if ([string]::IsNullOrWhiteSpace($RawCacheDir)) { '' } else { Normalize-ContestDirectoryPath $RawCacheDir }
$Msys2CaCertificatePath = [string](Get-ContestVariableValue -Name 'Msys2CaCertificatePath' -DefaultValue '' -EnvVar 'CONTEST_MSYS2_CA_PATH')
$PythonVersion = [string](Get-ContestVariableValue -Name 'PythonVersion' -DefaultValue '3.10.11' -EnvVar 'CONTEST_PYTHON_VERSION')
$TargetUserSid = [string](Get-ContestVariableValue -Name 'TargetUserSid' -DefaultValue '' -EnvVar 'CONTEST_TARGET_USER_SID')
$TargetUserProfile = [string](Get-ContestVariableValue -Name 'TargetUserProfile' -DefaultValue '' -EnvVar 'CONTEST_TARGET_USER_PROFILE')
if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile))
{
  $TargetUserProfile = Normalize-ContestDirectoryPath $TargetUserProfile
}

$IncludeVisualStudio = [bool](Get-ContestVariableValue -Name 'IncludeVisualStudio' -DefaultValue $false -EnvVar 'CONTEST_INCLUDE_VS')
$ForceUpdate = [bool](Get-ContestVariableValue -Name 'ForceUpdate' -DefaultValue $false -EnvVar 'CONTEST_FORCE_UPDATE')
$NoRestoreTask = [bool](Get-ContestVariableValue -Name 'NoRestoreTask' -DefaultValue $false -EnvVar 'CONTEST_NO_RESTORE_TASK')
$NoRestoreShutdown = [bool](Get-ContestVariableValue -Name 'NoRestoreShutdown' -DefaultValue $false -EnvVar 'CONTEST_NO_RESTORE_SHUTDOWN')
$RollbackOnFailure = [bool](Get-ContestVariableValue -Name 'RollbackOnFailure' -DefaultValue $false -EnvVar 'CONTEST_ROLLBACK_ON_FAILURE')
$UseRemote = [bool](Get-ContestVariableValue -Name 'UseRemote' -DefaultValue $false -EnvVar 'CONTEST_USE_REMOTE')
$KeepVSCode = [bool](Get-ContestVariableValue -Name 'KeepVSCode' -DefaultValue $false -EnvVar 'CONTEST_KEEP_VSCODE')
$NoPause = [bool](Get-ContestVariableValue -Name 'NoPause' -DefaultValue $false -EnvVar 'CONTEST_NO_PAUSE')
$SkipSignatureCheck = [bool](Get-ContestVariableValue -Name 'SkipSignatureCheck' -DefaultValue $false -EnvVar 'CONTEST_SKIP_SIGNATURE_CHECK')
$DeferAiBlockUntilExamStart = [bool](Get-ContestVariableValue -Name 'DeferAiBlockUntilExamStart' -DefaultValue $false -EnvVar 'CONTEST_DEFER_AI_BLOCK')

$ToolBin = Join-Path $Root 'bin'
$PathBin = Join-Path $Root 'path'
$ContestWorkspaceDir = Join-Path $Root 'contest'
$DownloadDir = Join-Path $Root 'downloads'
$ScriptStageDir = Join-Path $Root 'scripts'
$StateDir = Join-Path $Root 'state'
$StateManifestPath = Join-Path $StateDir 'install-manifest.json'
$TestDir = Join-Path $Root 'tests'
$LogDir = Join-Path $Root 'logs'
$BackupDir = Join-Path $Root 'backup'
$TimeStamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
$TranscriptPath = Join-Path $LogDir "setup-transcript-$TimeStamp.txt"
$ErrorLogPath = Join-Path $LogDir "setup-error-$TimeStamp.txt"

$MsysBash = Join-Path $MsysRoot 'usr\bin\bash.exe'
$MsysCat = Join-Path $MsysRoot 'usr\bin\cat.exe'
$UcrtBin = Join-Path $MsysRoot 'ucrt64\bin'
$MsysUsrBin = Join-Path $MsysRoot 'usr\bin'

$VersionParts = @($PythonVersion -split '\.')
$PyMajor = if ($VersionParts.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($VersionParts[0])) { $VersionParts[0] } else { '3' }
$PyMinor = if ($VersionParts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($VersionParts[1])) { $VersionParts[1] } else { '10' }
$PythonDir = Join-Path $Root ("Python{0}{1}" -f $PyMajor, $PyMinor)
$PythonExe = Join-Path $PythonDir 'python.exe'
$Python3Exe = Join-Path $PythonDir 'python3.exe'
$PythonInstallerName = "python-$PythonVersion-amd64.exe"
$PythonUrl = "https://www.python.org/ftp/python/$PythonVersion/$PythonInstallerName"
$PythonInstaller = Join-Path $DownloadDir $PythonInstallerName
$PythonNugetUrl = "https://www.nuget.org/api/v2/package/python/$PythonVersion"
$PythonNugetArchive = Join-Path $DownloadDir "python-$PythonVersion-nuget.zip"

$VSCodeInstallerUrl = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
$VSCodeInstallerPath = Join-Path $DownloadDir 'VSCodeSetup-x64.exe'
$VSCodeArchiveUrl = 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable'
$VSCodeArchivePath = Join-Path $DownloadDir 'vscode-win32-x64-archive.zip'

$Msys2InstallerUrl = 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe'
$Msys2InstallerPath = Join-Path $DownloadDir 'msys2-x86_64-latest.exe'

$Script:WingetHelpCache = @{}
if (-not (Get-Variable -Name 'ContestToolVersions' -Scope Global -ErrorAction SilentlyContinue) -or -not ($Global:ContestToolVersions -is [hashtable]))
{
  $Global:ContestToolVersions = @{}
}

function Import-ContestLibraryModule
{
  param(
    [Parameter(Mandatory = $true)] [string]$ModuleName,
    [switch]$Optional
  )
  $Candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot))
  {
    $Candidates.Add((Join-Path (Join-Path $PSScriptRoot 'lib') $ModuleName)) | Out-Null
  }
  if ($MyInvocation -and (-not [string]::IsNullOrWhiteSpace($MyInvocation.PSScriptRoot)))
  {
    $Candidates.Add((Join-Path (Join-Path $MyInvocation.PSScriptRoot 'lib') $ModuleName)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($PSCommandPath))
  {
    $CmdParent = Split-Path -Parent $PSCommandPath
    if (-not [string]::IsNullOrWhiteSpace($CmdParent))
    {
      $Candidates.Add((Join-Path (Join-Path $CmdParent 'lib') $ModuleName)) | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_LIB_DIR))
  {
    $Candidates.Add((Join-Path $env:CONTEST_LIB_DIR $ModuleName)) | Out-Null
  }
  $StageVar = Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue
  if ($null -ne $StageVar -and -not [string]::IsNullOrWhiteSpace([string]$StageVar.Value))
  {
    $Candidates.Add((Join-Path (Join-Path ([string]$StageVar.Value) 'lib') $ModuleName)) | Out-Null
  }
  try
  {
    $CurLoc = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($CurLoc))
    {
      $Candidates.Add((Join-Path (Join-Path $CurLoc 'lib') $ModuleName)) | Out-Null
    }
  }
  catch {}

  foreach ($Candidate in $Candidates)
  {
    if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate))
    {
      . $Candidate
      $Tokens = $null
      $Errors = $null
      $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Candidate, [ref]$Tokens, [ref]$Errors)
      if ($null -ne $Ast -and $null -ne $Ast.EndBlock)
      {
        foreach ($Stmt in $Ast.EndBlock.Statements)
        {
          if ($Stmt -is [System.Management.Automation.Language.FunctionDefinitionAst])
          {
            $FnName = $Stmt.Name
            $FnItem = Get-Item -LiteralPath "Function:\$FnName" -ErrorAction SilentlyContinue
            if ($null -ne $FnItem)
            {
              Set-Item -Path "Function:\script:$FnName" -Value $FnItem.ScriptBlock
            }
          }
        }
      }
      return
    }
  }

  if ($Optional)
  {
    return
  }
  throw "Required ContestSetup library module not found: lib/$ModuleName"
}

Import-ContestLibraryModule -ModuleName 'core-primitives.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'logging-and-manifest.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'schedule-and-preflight.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'download-and-archive.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'path-and-identity.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'environment-audit.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'browser-policies.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'vscode-workspace.ps1' -Optional

if (Get-Command Write-Host -ErrorAction SilentlyContinue)
{
  Write-Host "common.ps1 (v$ContestSetupVersion) loaded successfully." -ForegroundColor Green
}
