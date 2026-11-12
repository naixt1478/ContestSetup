# common.ps1
# Common variables and helper functions for ContestSetup v2.0 modules

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
$DownloadDir = Join-Path $Root 'downloads'
$ScriptStageDir = Join-Path $Root 'scripts'
$StateDir = Join-Path $Root 'state'
$StateManifestPath = Join-Path $StateDir 'install-manifest.json'
$TestDir = Join-Path $Root 'tests'
$LogDir = Join-Path $Root 'logs'
$BackupDir = Join-Path $Root 'backup'
$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
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

function Write-Section
{
  param([Parameter(Mandatory = $true)] [string]$Message)
  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host $Message -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
}

function Test-CommandExists
{
  param([Parameter(Mandatory = $true)] [string]$Command)
  return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

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

function Start-SetupLogging
{
  try
  {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $global:TranscriptStarted = $true
    Write-Host 'Logging started.' -ForegroundColor Green
    Write-Host "Transcript log: $TranscriptPath"
    Write-Host "Error log     : $ErrorLogPath"
  }
  catch
  {
    Write-Warning "Failed to start transcript logging. $($_.Exception.Message)"
  }
}

function Stop-SetupLogging
{
  if (Get-Variable -Name 'TranscriptStarted' -Scope Global -ErrorAction SilentlyContinue)
  {
    if ($global:TranscriptStarted)
    {
      try { Stop-Transcript | Out-Null } catch {}
      $global:TranscriptStarted = $false
    }
  }
}

function Backup-SetupLogsToTemp
{
  try
  {
    $TempLogDir = Join-Path $env:TEMP 'ContestSetup-Logs'
    New-Item -ItemType Directory -Force -Path $TempLogDir | Out-Null
    foreach ($PathToCopy in @($TranscriptPath, $ErrorLogPath))
    {
      if (-not [string]::IsNullOrWhiteSpace($PathToCopy) -and (Test-Path -LiteralPath $PathToCopy))
      {
        Copy-Item -LiteralPath $PathToCopy -Destination (Join-Path $TempLogDir ([IO.Path]::GetFileName($PathToCopy))) -Force -ErrorAction SilentlyContinue
      }
    }
    return $TempLogDir
  }
  catch
  {
    return $null
  }
}

function Write-ErrorLog
{
  param([Parameter(Mandatory = $true)] $ErrorRecord)
  try
  {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $Lines = @()
    $Lines += '============================================================'
    $Lines += 'Fatal error'
    $Lines += "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $Lines += '============================================================'
    $Lines += ''
    $Lines += 'Message:'
    $Lines += $ErrorRecord.Exception.Message
    $Lines += ''
    $Lines += 'Exception:'
    $Lines += $ErrorRecord.Exception.GetType().FullName
    $Lines += ''
    $Lines += 'Script stack trace:'
    $Lines += $ErrorRecord.ScriptStackTrace
    $Lines += ''
    $Lines += 'Invocation:'
    $Lines += $ErrorRecord.InvocationInfo.PositionMessage
    Write-LinesUtf8NoBom -Path $ErrorLogPath -Lines $Lines
    Backup-SetupLogsToTemp | Out-Null
  }
  catch
  {
    Write-Warning 'Failed to write error log.'
  }
}

function Write-TextUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content
  )
  $Directory = [IO.Path]::GetDirectoryName($Path)
  if (-not [string]::IsNullOrWhiteSpace($Directory))
  {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  }
  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines
  )
  $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
  Write-TextUtf8NoBom -Path $Path -Content $Content
}

function Write-JsonUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object]$InputObject,
    [int]$Depth = 30
  )
  # Use -InputObject instead of pipeline so 0-element and 1-element arrays are preserved
  $Json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
  if ([string]::IsNullOrWhiteSpace($Json) -and ($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Collections.IDictionary]))
  {
    $Json = '[]'
  }
  Write-TextUtf8NoBom -Path $Path -Content ($Json + [Environment]::NewLine)
}

function Read-TextUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-LinesUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}

function ConvertFrom-JsonSafe
{
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json
  )
  if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
  $Text = $Json.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  # Pass 1: strip // and /* */ comments outside double-quoted JSON strings
  $NoCommentsBuilder = New-Object System.Text.StringBuilder ($Text.Length)
  $InString = $false
  $Idx = 0
  $Len = $Text.Length
  while ($Idx -lt $Len)
  {
    $Ch = $Text[$Idx]
    if ($InString)
    {
      [void]$NoCommentsBuilder.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        [void]$NoCommentsBuilder.Append($Text[$Idx + 1])
        $Idx += 2
        continue
      }
      if ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }

    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$NoCommentsBuilder.Append($Ch)
      $Idx++
      continue
    }

    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '/')
    {
      $Idx += 2
      while ($Idx -lt $Len -and $Text[$Idx] -ne "`n" -and $Text[$Idx] -ne "`r")
      {
        $Idx++
      }
      continue
    }

    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '*')
    {
      $Idx += 2
      while ($Idx -lt $Len)
      {
        if ($Text[$Idx] -eq '*' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '/')
        {
          $Idx += 2
          break
        }
        $Idx++
      }
      continue
    }

    [void]$NoCommentsBuilder.Append($Ch)
    $Idx++
  }

  # Pass 2: strip trailing commas before closing object or array delimiters outside double-quoted JSON strings
  $Pass1 = $NoCommentsBuilder.ToString()
  $CleanBuilder = New-Object System.Text.StringBuilder ($Pass1.Length)
  $InString = $false
  $Idx = 0
  $Len = $Pass1.Length
  while ($Idx -lt $Len)
  {
    $Ch = $Pass1[$Idx]
    if ($InString)
    {
      [void]$CleanBuilder.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        [void]$CleanBuilder.Append($Pass1[$Idx + 1])
        $Idx += 2
        continue
      }
      if ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }

    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$CleanBuilder.Append($Ch)
      $Idx++
      continue
    }

    if ($Ch -eq ',')
    {
      $LookAhead = $Idx + 1
      while ($LookAhead -lt $Len -and ($Pass1[$LookAhead] -eq ' ' -or $Pass1[$LookAhead] -eq "`t" -or $Pass1[$LookAhead] -eq "`r" -or $Pass1[$LookAhead] -eq "`n"))
      {
        $LookAhead++
      }
      if ($LookAhead -lt $Len -and ($Pass1[$LookAhead] -eq ([char]125) -or $Pass1[$LookAhead] -eq ']'))
      {
        $Idx++
        continue
      }
    }

    [void]$CleanBuilder.Append($Ch)
    $Idx++
  }

  $CleanJson = $CleanBuilder.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($CleanJson)) { return $null }
  return (ConvertFrom-Json -InputObject $CleanJson -ErrorAction Stop)
}

function ConvertFrom-JsonArray
{
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json
  )
  if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
  $Parsed = ConvertFrom-JsonSafe -Json $Json
  if ($null -eq $Parsed) { return @() }
  if ($Parsed -is [System.Array]) { return $Parsed }
  return @($Parsed)
}

function Set-ObjectProperty
{
  param(
    [Parameter(Mandatory = $true)] [object]$Object,
    [Parameter(Mandatory = $true)] [string]$Name,
    [AllowNull()] [object]$Value
  )
  $ExistingProp = $Object.PSObject.Properties[$Name]
  if ($null -ne $ExistingProp)
  {
    $ExistingProp.Value = $Value
  }
  else
  {
    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force
  }
}

function Resolve-VSCodeProductJsonPath
{
  param(
    [AllowNull()] [AllowEmptyString()] [string]$VSCodeRoot
  )
  if ([string]::IsNullOrWhiteSpace($VSCodeRoot) -or (-not (Test-Path -LiteralPath $VSCodeRoot)))
  {
    return $null
  }

  # 1. Legacy flat win32-x64-archive layout: vscode\resources\app\product.json
  $LegacyFlat = Join-Path $VSCodeRoot 'resources\app\product.json'
  if (Test-Path -LiteralPath $LegacyFlat)
  {
    return $LegacyFlat
  }

  # 2. Active versioned subdir referenced inside vscode\bin\code.cmd (<commit>\resources\app\out\cli.js)
  $CodeCmdFile = Join-Path $VSCodeRoot 'bin\code.cmd'
  if (Test-Path -LiteralPath $CodeCmdFile)
  {
    try
    {
      $CmdText = Read-TextUtf8 -Path $CodeCmdFile
      if (-not [string]::IsNullOrWhiteSpace($CmdText))
      {
        $CliMatch = [regex]::Match($CmdText, '(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js')
        if ($CliMatch.Success)
        {
          $RefSubDir = $CliMatch.Groups[1].Value
          $RefProductJson = Join-Path (Join-Path $VSCodeRoot $RefSubDir) 'resources\app\product.json'
          if (Test-Path -LiteralPath $RefProductJson)
          {
            return $RefProductJson
          }
        }
      }
    }
    catch {}
  }

  # 3. Scan immediate child directories sorted by LastWriteTime descending (excluding non-version folders)
  $ExcludedChildNames = @('data', 'bin', 'tools', 'policies', 'appx')
  $ChildDirs = @(Get-ChildItem -LiteralPath $VSCodeRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  foreach ($ChildDir in $ChildDirs)
  {
    if ($ExcludedChildNames -contains $ChildDir.Name.ToLowerInvariant())
    {
      continue
    }
    $CandidateProductJson = Join-Path $ChildDir.FullName 'resources\app\product.json'
    if (Test-Path -LiteralPath $CandidateProductJson)
    {
      return $CandidateProductJson
    }
  }

  # 4. Root fallback: vscode\product.json
  $RootProductJson = Join-Path $VSCodeRoot 'product.json'
  if (Test-Path -LiteralPath $RootProductJson)
  {
    return $RootProductJson
  }

  return $null
}

function Expand-ArchiveFast
{
  param(
    [Parameter(Mandatory = $true)] [string]$ArchivePath,
    [Parameter(Mandatory = $true)] [string]$DestinationPath
  )
  if (-not (Test-Path -LiteralPath $ArchivePath))
  {
    throw "Archive not found for extraction: $ArchivePath"
  }
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

  # Tier 1: Explicit Windows System32 bsdtar (never Get-Command 'tar.exe', avoiding MSYS2/Git GNU tar shadowing)
  $SysTar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path -LiteralPath $SysTar)
  {
    try
    {
      $TarRes = Invoke-NativeCommand -FilePath $SysTar -ArgumentList @('-xf', $ArchivePath, '-C', $DestinationPath) -Quiet
      if ($TarRes.ExitCode -eq 0)
      {
        return
      }
      Write-Warning "System32 tar.exe exited with code $($TarRes.ExitCode). Falling back to .NET ZipFile extraction..."
    }
    catch
    {
      Write-Warning "System32 tar.exe failed ($($_.Exception.Message)). Falling back to .NET ZipFile extraction..."
    }
  }

  # Tier 2: .NET System.IO.Compression.ZipFile::ExtractToDirectory
  try
  {
    Get-ChildItem -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
    return
  }
  catch
  {
    Write-Warning ".NET ZipFile extraction failed ($($_.Exception.Message)). Falling back to silent Expand-Archive..."
  }

  # Tier 3: Clean partial files and run Expand-Archive -LiteralPath with silenced progress bar
  $OldProgressPref = $ProgressPreference
  try
  {
    Get-ChildItem -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $ProgressPreference = 'SilentlyContinue'
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
  }
  finally
  {
    $ProgressPreference = $OldProgressPref
  }
}

function Test-PathInside
{
  param(
    [AllowNull()] [AllowEmptyString()] [string]$ChildPath,
    [AllowNull()] [AllowEmptyString()] [string]$ParentPath
  )
  if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath))
  {
    return $false
  }
  $ChildNorm = ($ChildPath -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
  $ParentNorm = ($ParentPath -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($ChildNorm) -or [string]::IsNullOrWhiteSpace($ParentNorm))
  {
    return $false
  }
  return ($ChildNorm -eq $ParentNorm) -or $ChildNorm.StartsWith("$ParentNorm\", [System.StringComparison]::OrdinalIgnoreCase)
}

function New-DefaultContestStateManifest
{
  return [ordered]@{
    Version                       = $ContestSetupVersion
    Root                          = $Root
    MsysRoot                      = $MsysRoot
    TargetUserSid                 = $TargetUserSid
    TargetUserProfile             = $TargetUserProfile
    CustomCaFileName              = ''
    ExamStart                     = $ExamStart
    ExamEnd                       = $ExamEnd
    RestoreAt                     = $RestoreAt
    PythonVersion                 = $PythonVersion
    PythonInstalledByContestSetup = $false
    Msys2PreExisted               = (Test-Path -LiteralPath $MsysBash)
    CompletedModules              = @()
    UpdatedAt                     = (Get-Date -Format 'o')
  }
}

function Read-ContestStateManifest
{
  if (-not (Test-Path -LiteralPath $StateManifestPath))
  {
    return (New-DefaultContestStateManifest)
  }
  try
  {
    $Raw = Read-TextUtf8 -Path $StateManifestPath
    $Parsed = ConvertFrom-JsonSafe -Json $Raw
    if ($null -eq $Parsed) { return (New-DefaultContestStateManifest) }
    $Result = [ordered]@{}
    foreach ($Prop in $Parsed.PSObject.Properties)
    {
      $Result[$Prop.Name] = $Prop.Value
    }
    if (-not $Result.Contains('Version')) { $Result['Version'] = $ContestSetupVersion }
    if (-not $Result.Contains('Root') -or [string]::IsNullOrWhiteSpace([string]$Result['Root'])) { $Result['Root'] = $Root }
    if (-not $Result.Contains('MsysRoot') -or [string]::IsNullOrWhiteSpace([string]$Result['MsysRoot'])) { $Result['MsysRoot'] = $MsysRoot }
    if (-not $Result.Contains('TargetUserSid')) { $Result['TargetUserSid'] = $TargetUserSid }
    if (-not $Result.Contains('TargetUserProfile')) { $Result['TargetUserProfile'] = $TargetUserProfile }
    if (-not $Result.Contains('CustomCaFileName')) { $Result['CustomCaFileName'] = '' }
    if (-not $Result.Contains('CompletedModules') -or $null -eq $Result['CompletedModules']) { $Result['CompletedModules'] = @() }
    return $Result
  }
  catch
  {
    return (New-DefaultContestStateManifest)
  }
}

function Get-ContestStateManifest
{
  return (Read-ContestStateManifest)
}

function Save-ContestStateManifest
{
  param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$Manifest)
  $Manifest['Version'] = $ContestSetupVersion
  $Manifest['Root'] = $Root
  $Manifest['MsysRoot'] = $MsysRoot
  if (-not [string]::IsNullOrWhiteSpace($TargetUserSid)) { $Manifest['TargetUserSid'] = $TargetUserSid }
  elseif (-not $Manifest.Contains('TargetUserSid')) { $Manifest['TargetUserSid'] = '' }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) { $Manifest['TargetUserProfile'] = $TargetUserProfile }
  elseif (-not $Manifest.Contains('TargetUserProfile')) { $Manifest['TargetUserProfile'] = '' }
  if (-not $Manifest.Contains('CustomCaFileName')) { $Manifest['CustomCaFileName'] = '' }
  $Manifest['ExamStart'] = $ExamStart
  $Manifest['ExamEnd'] = $ExamEnd
  $Manifest['RestoreAt'] = $RestoreAt
  $Manifest['UpdatedAt'] = (Get-Date -Format 'o')
  Write-JsonUtf8NoBom -Path $StateManifestPath -InputObject $Manifest -Depth 15
}

function Update-ContestStateManifest
{
  param(
    [string]$CompletedModule = '',
    [hashtable]$Properties = @{}
  )
  $Manifest = Read-ContestStateManifest
  foreach ($Key in $Properties.Keys)
  {
    $Manifest[$Key] = $Properties[$Key]
  }
  if (-not [string]::IsNullOrWhiteSpace($CompletedModule))
  {
    $ModulesList = @($Manifest['CompletedModules'] | Where-Object { $_ })
    if ($ModulesList -notcontains $CompletedModule)
    {
      $ModulesList += $CompletedModule
    }
    $Manifest['CompletedModules'] = @($ModulesList)
  }
  Save-ContestStateManifest -Manifest $Manifest
}

function ConvertTo-KstDateTimeOffset
{
  param(
    [Parameter(Mandatory = $true)] [string]$TimestampText,
    [Parameter(Mandatory = $true)] [string]$FieldName
  )
  $Trimmed = $TimestampText.Trim()
  if ([string]::IsNullOrWhiteSpace($Trimmed))
  {
    throw "Invalid $FieldName timestamp format: '$TimestampText'. Expected ISO-8601 format such as '2026-11-23T19:00:00'."
  }
  $HasExplicitOffset = ($Trimmed -match '(?i)(Z|[+-]\d{2}:?\d{2})$')
  $NormalizedIso = if ($HasExplicitOffset) { $Trimmed } else { "$Trimmed+09:00" }
  try
  {
    return [DateTimeOffset]::Parse($NormalizedIso, [System.Globalization.CultureInfo]::InvariantCulture)
  }
  catch
  {
    throw "Invalid $FieldName timestamp format: '$TimestampText'. Expected ISO-8601 format such as '2026-11-23T19:00:00'."
  }
}

function Test-ExamScheduleConfiguration
{
  param(
    [string]$StartText = $ExamStart,
    [string]$EndText = $ExamEnd,
    [string]$RestoreText = $RestoreAt
  )
  $StartDto = ConvertTo-KstDateTimeOffset -TimestampText $StartText -FieldName 'ExamStart'
  $EndDto = ConvertTo-KstDateTimeOffset -TimestampText $EndText -FieldName 'ExamEnd'
  $RestoreDto = ConvertTo-KstDateTimeOffset -TimestampText $RestoreText -FieldName 'RestoreAt'

  $ParsedStart = $StartDto.LocalDateTime
  $ParsedEnd = $EndDto.LocalDateTime
  $ParsedRestore = $RestoreDto.LocalDateTime

  if ($EndDto -le $StartDto)
  {
    throw "Invalid exam window: ExamEnd ($($EndDto.ToString('o'))) must be later than ExamStart ($($StartDto.ToString('o')))."
  }

  $IsKst = $true
  try
  {
    $Tz = Get-TimeZone -ErrorAction Stop
    $IsKst = ($Tz.BaseUtcOffset -eq [TimeSpan]::FromHours(9))
    if (-not $IsKst)
    {
      Write-Warning "System timezone is '$($Tz.Id)' (UTC offset $($Tz.BaseUtcOffset)), not Korea Standard Time (UTC+09:00). KST (+09:00) schedule converted to local trigger time $($ParsedRestore.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))."
    }
  }
  catch {}

  $KstStart = $StartDto.ToOffset([TimeSpan]::FromHours(9))
  $IsMonday = ($KstStart.DayOfWeek -eq [System.DayOfWeek]::Monday)
  if ($KstStart.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) -eq '2026-11-23' -and -not $IsMonday)
  {
    Write-Warning "Unexpected day of week for 2026-11-23: $($KstStart.DayOfWeek)"
  }

  $NowDto = [DateTimeOffset]::Now
  $IsPastRestoreTime = ($NowDto -ge $RestoreDto)
  $IsBeforeExamStart = ($NowDto -lt $StartDto)

  return [pscustomobject]@{
    ExamStart         = $ParsedStart
    ExamEnd           = $ParsedEnd
    RestoreAt         = $ParsedRestore
    ExamStartDto      = $StartDto
    ExamEndDto        = $EndDto
    RestoreAtDto      = $RestoreDto
    ExamStartIso      = $StartDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    ExamEndIso        = $EndDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    RestoreAtIso      = $RestoreDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    DurationMinutes   = [math]::Round(($EndDto - $StartDto).TotalMinutes, 1)
    DayOfWeek         = $KstStart.DayOfWeek.ToString()
    IsKst             = $IsKst
    IsKstZone         = $IsKst
    IsMonday          = $IsMonday
    IsPastRestoreTime = $IsPastRestoreTime
    IsBeforeExamStart = $IsBeforeExamStart
  }
}

function Clear-StaleAiHostsSectionBeforeInstall
{
  $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (-not (Test-Path -LiteralPath $HostsPath)) { return }
  $BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
  $EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
  try
  {
    $CurrentHosts = Read-TextUtf8 -Path $HostsPath
    if ($null -ne $CurrentHosts -and $CurrentHosts -like "*$BeginMarker*" -and $CurrentHosts -like "*$EndMarker*")
    {
      Write-Host 'Detected active AI blocklist in hosts file from a prior run. Temporarily clearing during setup downloads...' -ForegroundColor Yellow
      $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
      $Cleaned = ([regex]::Replace($CurrentHosts, $Pattern, "`r`n")).TrimEnd()
      $HostItem = Get-Item -LiteralPath $HostsPath -Force -ErrorAction SilentlyContinue
      if ($HostItem -and ($HostItem.Attributes -band [IO.FileAttributes]::ReadOnly))
      {
        $HostItem.Attributes = $HostItem.Attributes -bxor [IO.FileAttributes]::ReadOnly
      }
      Write-TextUtf8NoBom -Path $HostsPath -Content ($Cleaned + "`r`n")
      try { ipconfig.exe /flushdns | Out-Null } catch {}
    }
  }
  catch
  {
    Write-Warning "Could not clear existing AI hosts section prior to install: $($_.Exception.Message)"
  }
}

function Test-SystemClockSkewHttps
{
  param([int]$TimeoutSeconds = 3)
  try
  {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $Handler = New-Object System.Net.Http.HttpClientHandler
    $Handler.AllowAutoRedirect = $true
    $Client = New-Object System.Net.Http.HttpClient($Handler)
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try
    {
      $Req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, 'https://www.microsoft.com')
      $Resp = $Client.SendAsync($Req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      try
      {
        if ($null -ne $Resp.Headers.Date)
        {
          $ServerUtc = [DateTimeOffset]$Resp.Headers.Date.Value
          $LocalUtc = [DateTimeOffset]::UtcNow
          $SkewMinutes = [math]::Round(($LocalUtc - $ServerUtc).TotalMinutes, 1)
          if ([math]::Abs($SkewMinutes) -gt 5.0)
          {
            Write-Warning "System clock skew detected: local UTC differs from HTTPS Date header by $SkewMinutes minutes (> 5 min threshold). Attempting non-blocking clock resync..."
            if (Test-IsAdmin)
            {
              try { & w32tm.exe /resync /nowait 2>$null | Out-Null } catch {}
            }
          }
          else
          {
            Write-Host ("Clock Sync   : Verified within {0} min of HTTPS UTC reference" -f [math]::Abs($SkewMinutes)) -ForegroundColor Green
          }
        }
      }
      finally
      {
        if ($Resp) { $Resp.Dispose() }
        if ($Req) { $Req.Dispose() }
      }
    }
    finally
    {
      if ($Client) { $Client.Dispose() }
      if ($Handler) { $Handler.Dispose() }
    }
  }
  catch
  {
    # Non-blocking best-effort check (offline/USB environments continue seamlessly)
  }
}

function Invoke-PreflightChecks
{
  param([switch]$DryRunOnly)
  Write-Section 'Pre-flight System & Schedule Checks'

  if (-not [Environment]::Is64BitOperatingSystem)
  {
    throw 'ContestSetup v2.0 requires a 64-bit Windows operating system.'
  }
  Write-Host 'Architecture : 64-bit OS verified' -ForegroundColor Green

  if ($MsysRoot -match '\s')
  {
    Write-Warning "MsysRoot ('$MsysRoot') contains spaces. MSYS2/GNU tools strongly recommend a space-free path such as C:\msys64."
  }

  $ScheduleInfo = Test-ExamScheduleConfiguration -StartText $ExamStart -EndText $ExamEnd -RestoreText $RestoreAt
  Write-Host ("Exam Window  : {0} ({1}) ~ {2} ({3} mins)" -f $ScheduleInfo.ExamStart.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.DayOfWeek, $ScheduleInfo.ExamEnd.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.DurationMinutes) -ForegroundColor Green
  Write-Host ("Auto Restore : {0} (ISO: {1})" -f $ScheduleInfo.RestoreAt.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.RestoreAtIso) -ForegroundColor Green

  try
  {
    $RootDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Root))
    $MsysDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($MsysRoot))
    $MsysInstalled = (Test-Path -LiteralPath $MsysBash)

    if ($RootDrive -ieq $MsysDrive)
    {
      $DriveInfo = New-Object System.IO.DriveInfo($RootDrive)
      $FreeGb = [math]::Round($DriveInfo.AvailableFreeSpace / 1GB, 2)
      $MinRequiredGb = if ($MsysInstalled) { 0.5 } else { 2.5 }
      if ($FreeGb -lt $MinRequiredGb)
      {
        Write-Warning "Low free disk space on $RootDrive ($FreeGb GB available, recommended >= $MinRequiredGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $FreeGb GB available on $RootDrive" -ForegroundColor Green
      }
    }
    else
    {
      $RootDriveInfo = New-Object System.IO.DriveInfo($RootDrive)
      $RootFreeGb = [math]::Round($RootDriveInfo.AvailableFreeSpace / 1GB, 2)
      $RootMinGb = 0.8
      if ($RootFreeGb -lt $RootMinGb)
      {
        Write-Warning "Low free disk space on Root drive $RootDrive ($RootFreeGb GB available, recommended >= $RootMinGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $RootFreeGb GB available on Root drive $RootDrive" -ForegroundColor Green
      }

      $MsysDriveInfo = New-Object System.IO.DriveInfo($MsysDrive)
      $MsysFreeGb = [math]::Round($MsysDriveInfo.AvailableFreeSpace / 1GB, 2)
      $MsysMinGb = if ($MsysInstalled) { 0.3 } else { 1.8 }
      if ($MsysFreeGb -lt $MsysMinGb)
      {
        Write-Warning "Low free disk space on MsysRoot drive $MsysDrive ($MsysFreeGb GB available, recommended >= $MsysMinGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $MsysFreeGb GB available on MsysRoot drive $MsysDrive" -ForegroundColor Green
      }
    }
  }
  catch {}

  Test-SystemClockSkewHttps -TimeoutSeconds 3

  if ((-not $DryRunOnly) -and ($Mode -eq 'Install'))
  {
    Clear-StaleAiHostsSectionBeforeInstall
  }

  return $ScheduleInfo
}

function Convert-ToForwardSlashPath
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return ($Path -replace '\\', '/')
}

function Invoke-NativeCommand
{
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$Quiet,
    [switch]$StreamOutput
  )

  $CmdObj = Get-Command $FilePath -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $CmdObj -and -not (Test-Path -LiteralPath $FilePath))
  {
    throw "Native command not found: $FilePath"
  }
  $ResolvedPath = if (Test-Path -LiteralPath $FilePath) { $FilePath } elseif ($CmdObj -and $CmdObj.Source) { $CmdObj.Source } else { $FilePath }
  if (-not $Quiet) { Write-Host ("{0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray }

  $Ext = [IO.Path]::GetExtension($ResolvedPath).ToLowerInvariant()
  if (($Ext -in @('.cmd', '.bat')) -and (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) -and (Test-Path -LiteralPath $env:ComSpec))
  {
    # PS 5.1 mangles quotes when & invokes a .cmd/.bat file and both FilePath and arguments contain spaces.
    # Use cmd.exe /d /s /c "<QuotedCmdLine>" via ProcessStartInfo so Win32 CreateProcess receives exact quotes.
    $QuotedParts = @((Quote-ProcessArgument $ResolvedPath))
    foreach ($ArgItem in $ArgumentList)
    {
      $QuotedParts += (Quote-ProcessArgument $ArgItem)
    }
    $InnerCmdLine = $QuotedParts -join ' '
    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $env:ComSpec
    $Psi.Arguments = "/d /s /c `"$InnerCmdLine`""
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    try
    {
      $Psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $Psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    catch {}

    $Proc = [System.Diagnostics.Process]::Start($Psi)
    try
    {
      $StdOutTask = $Proc.StandardOutput.ReadToEndAsync()
      $StdErrTask = $Proc.StandardError.ReadToEndAsync()
      $Proc.WaitForExit()
      $StdOutText = $StdOutTask.GetAwaiter().GetResult()
      $StdErrText = $StdErrTask.GetAwaiter().GetResult()
      $ExitCode = [int]$Proc.ExitCode
    }
    finally
    {
      if ($Proc) { $Proc.Dispose() }
    }

    $CombinedLines = New-Object System.Collections.Generic.List[string]
    foreach ($Chunk in @($StdOutText, $StdErrText))
    {
      if (-not [string]::IsNullOrEmpty($Chunk))
      {
        foreach ($SplitLine in ($Chunk -split "\r?\n"))
        {
          if ($SplitLine.Length -gt 0) { $CombinedLines.Add($SplitLine) | Out-Null }
        }
      }
    }
    $Output = $CombinedLines.ToArray()
    if (-not $Quiet)
    {
      foreach ($Line in $Output) { Write-Host $Line }
    }
    return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Output) }
  }

  $OldErrorActionPreference = $ErrorActionPreference
  try
  {
    $ErrorActionPreference = 'Continue'
    if ($StreamOutput -and -not $Quiet)
    {
      $OutputList = New-Object System.Collections.Generic.List[string]
      & $FilePath @ArgumentList 2>&1 | ForEach-Object {
        if ($null -ne $_)
        {
          $Line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
          $OutputList.Add($Line) | Out-Null
          Write-Host $Line
        }
      }
      $ExitCode = [int]$LASTEXITCODE
      $Output = $OutputList.ToArray()
    }
    else
    {
      $RawOutput = & $FilePath @ArgumentList 2>&1
      $ExitCode = [int]$LASTEXITCODE
      $Output = @($RawOutput | ForEach-Object {
        if ($null -ne $_)
        {
          if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
        }
      })
    }
  }
  finally
  {
    $ErrorActionPreference = $OldErrorActionPreference
  }

  if ((-not $Quiet) -and (-not $StreamOutput))
  {
    foreach ($Line in $Output) { if ($null -ne $Line) { Write-Host $Line } }
  }
  return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Output) }
}

function Invoke-NativeChecked
{
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int[]]$SuccessExitCodes = @(0),
    [switch]$Quiet,
    [switch]$StreamOutput
  )
  $Result = Invoke-NativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -Quiet:$Quiet -StreamOutput:$StreamOutput
  if ($SuccessExitCodes -notcontains $Result.ExitCode)
  {
    $OutputText = ($Result.Output | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $Message = "Native command failed with exit code $($Result.ExitCode): $FilePath $($ArgumentList -join ' ')"
    if (-not [string]::IsNullOrWhiteSpace($OutputText))
    {
      $Message += [Environment]::NewLine + [Environment]::NewLine + 'Command output:' + [Environment]::NewLine + $OutputText
    }
    throw $Message
  }
  return $Result
}

function Test-ValidCachedInstallerFile
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [long]$MinBytes = 10485760
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try
  {
    $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($Item.Length -lt $MinBytes) { return $false }

    $Ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try
    {
      $Header = New-Object byte[] 4
      $ReadCount = $Stream.Read($Header, 0, 4)
      if ($ReadCount -lt 4) { return $false }
      if ($Ext -in @('.zip', '.nupkg', '.vsix'))
      {
        # PK\x03\x04 magic bytes
        return ($Header[0] -eq 0x50 -and $Header[1] -eq 0x4B -and $Header[2] -eq 0x03 -and $Header[3] -eq 0x04)
      }
      elseif ($Ext -eq '.exe')
      {
        # MZ magic bytes
        return ($Header[0] -eq 0x4D -and $Header[1] -eq 0x5A)
      }
      return $true
    }
    finally
    {
      $Stream.Dispose()
    }
  }
  catch
  {
    return $false
  }
}

function Copy-FromCacheDirIfPresent
{
  param([Parameter(Mandatory = $true)] [string]$OutFile, [long]$MinBytes = 1024)
  if ([string]::IsNullOrWhiteSpace($CacheDir)) { return $false }
  if (-not (Test-Path -LiteralPath $CacheDir)) { return $false }
  $LeafName = [IO.Path]::GetFileName($OutFile)
  $SearchRoots = @($CacheDir)
  $InstallersSubDir = Join-Path $CacheDir 'installers'
  if (Test-Path -LiteralPath $InstallersSubDir) { $SearchRoots += $InstallersSubDir }

  $MatchedSource = $null
  foreach ($SearchRoot in $SearchRoots)
  {
    $ExactCandidate = Join-Path $SearchRoot $LeafName
    if ((Test-Path -LiteralPath $ExactCandidate) -and (Test-ValidCachedInstallerFile -Path $ExactCandidate -MinBytes $MinBytes))
    {
      $MatchedSource = $ExactCandidate
      break
    }
  }

  if (-not $MatchedSource)
  {
    $FallbackGlobs = @()
    if ($LeafName -ieq 'vscode-win32-x64-archive.zip')
    {
      $FallbackGlobs = @('VSCode-win32-x64*.zip', 'vscode-win32-x64*.zip')
    }
    elseif ($LeafName -ieq 'msys2-x86_64-latest.exe')
    {
      $FallbackGlobs = @('msys2-x86_64-*.exe')
    }
    elseif ($LeafName -imatch '^python-.*-amd64\.exe$')
    {
      $FallbackGlobs = @("python-$PythonVersion*amd64.exe", "python-$PyMajor.$PyMinor.*-amd64.exe")
    }
    elseif ($LeafName -imatch '^python-.*-nuget\.zip$')
    {
      $FallbackGlobs = @("python.$PythonVersion.nupkg", "python-$PythonVersion*nuget.zip", "python.$PyMajor.$PyMinor.*.nupkg")
    }

    foreach ($SearchRoot in $SearchRoots)
    {
      foreach ($GlobPattern in $FallbackGlobs)
      {
        $GlobHits = @(Get-ChildItem -Path $SearchRoot -Filter $GlobPattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($Hit in $GlobHits)
        {
          if (Test-ValidCachedInstallerFile -Path $Hit.FullName -MinBytes $MinBytes)
          {
            $MatchedSource = $Hit.FullName
            break
          }
        }
        if ($MatchedSource) { break }
      }
      if ($MatchedSource) { break }
    }
  }

  if ($MatchedSource)
  {
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
    if ([IO.Path]::GetFullPath($MatchedSource) -ine [IO.Path]::GetFullPath($OutFile))
    {
      Copy-Item -LiteralPath $MatchedSource -Destination $OutFile -Force
      Write-Host "Copied installer from CacheDir: $MatchedSource -> $OutFile" -ForegroundColor Green
    }
    return $true
  }
  return $false
}

function Invoke-DownloadFile
{
  param([Parameter(Mandatory = $true)] [string]$Url, [Parameter(Mandatory = $true)] [string]$OutFile, [int]$MaxAttempts = 3)
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
  try
  {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, 16)
  }
  catch {}

  if (-not $ForceUpdate -and (Copy-FromCacheDirIfPresent -OutFile $OutFile))
  {
    return
  }

  $TempOutFile = "$OutFile.part"
  $LastError = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      Write-Host "Downloading ($Attempt/$MaxAttempts): $Url"
      if (Test-Path -LiteralPath $TempOutFile) { Remove-Item -LiteralPath $TempOutFile -Force -ErrorAction SilentlyContinue }
      $ExpectedLength = $null
      try
      {
        $Handler = $null
        $Client = $null
        $Response = $null
        $InputStream = $null
        $OutputStream = $null
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $Handler = New-Object System.Net.Http.HttpClientHandler
        $Handler.AllowAutoRedirect = $true
        $Client = New-Object System.Net.Http.HttpClient($Handler)
        $Client.Timeout = [TimeSpan]::FromMinutes(60)
        try { $Client.DefaultRequestHeaders.UserAgent.ParseAdd('ContestSetup/2.0') } catch {}

        $Response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $Response.IsSuccessStatusCode)
        {
          throw "HTTP $([int]$Response.StatusCode) $($Response.ReasonPhrase)"
        }
        $ExpectedLength = $Response.Content.Headers.ContentLength

        $InputStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { if ($InputStream.CanTimeout) { $InputStream.ReadTimeout = 120000 } } catch {}
        $OutputStream = [System.IO.File]::Open($TempOutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try
        {
          $Buffer = New-Object byte[] (1024 * 1024)
          while (($BytesRead = $InputStream.Read($Buffer, 0, $Buffer.Length)) -gt 0)
          {
            $OutputStream.Write($Buffer, 0, $BytesRead)
          }
        }
        finally
        {
          if ($OutputStream) { $OutputStream.Dispose() }
          if ($InputStream) { $InputStream.Dispose() }
          if ($Response) { $Response.Dispose() }
          if ($Client) { $Client.Dispose() }
          if ($Handler) { $Handler.Dispose() }
        }
      }
      catch
      {
        Write-Warning "Fast download path failed. Falling back to Invoke-WebRequest. $($_.Exception.Message)"
        $Params = @{ Uri = $Url; OutFile = $TempOutFile; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
        $OldProgressPref = $ProgressPreference
        try { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest @Params }
        finally { $ProgressPreference = $OldProgressPref }
      }

      if (-not (Test-Path -LiteralPath $TempOutFile)) { throw "Download did not create file: $TempOutFile" }
      $ActualLength = (Get-Item -LiteralPath $TempOutFile).Length
      if ($ActualLength -le 0) { throw "Downloaded file is empty: $TempOutFile" }
      if ($null -ne $ExpectedLength -and $ExpectedLength -gt 0 -and $ActualLength -ne $ExpectedLength)
      {
        throw "Downloaded file size mismatch for $OutFile (expected $ExpectedLength bytes, actual $ActualLength bytes)."
      }
      Move-Item -LiteralPath $TempOutFile -Destination $OutFile -Force
      if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download did not create file: $OutFile" }
      return
    }
    catch
    {
      $LastError = $_
      if (Test-Path -LiteralPath $TempOutFile) { Remove-Item -LiteralPath $TempOutFile -Force -ErrorAction SilentlyContinue }
      if ($Attempt -lt $MaxAttempts) { Write-Warning "Download failed. Retrying... $($_.Exception.Message)"; Start-Sleep -Seconds 2 }
    }
  }
  throw "Download failed after $MaxAttempts attempts: $Url - $($LastError.Exception.Message)"
}

function Assert-FileSha256
{
  param([Parameter(Mandatory = $true)] [string]$Path, [AllowEmptyString()] [string]$ExpectedSha256)
  if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return }
  $HashObj = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  $Actual = if ($null -ne $HashObj) { [string]$HashObj.Hash } else { '' }
  if ($Actual -ine $ExpectedSha256) { throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $Actual" }
  Write-Host "SHA256 verified: $Path" -ForegroundColor Green
}

function Assert-AuthenticodeValid
{
  param([Parameter(Mandatory = $true)] [string]$Path, [string[]]$AllowedPublisherKeywords = @())
  if ($SkipSignatureCheck) { Write-Warning "Skipping Authenticode check by -SkipSignatureCheck: $Path"; return }
  $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($Extension -notin @('.exe', '.msi', '.msixbundle', '.appx', '.appxbundle')) { return }
  $Signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($null -eq $Signature -or $Signature.Status -ne 'Valid')
  {
    $StatusLabel = if ($null -ne $Signature) { [string]$Signature.Status } else { 'NullSignature' }
    throw "Invalid Authenticode signature: $Path ($StatusLabel)"
  }
  if ($AllowedPublisherKeywords.Count -gt 0)
  {
    $Subj = if ($null -ne $Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Subject } else { '' }
    $Iss = if ($null -ne $Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Issuer } else { '' }
    $Combined = "$Subj $Iss"
    $Ok = $false
    foreach ($Keyword in $AllowedPublisherKeywords) { if ($Combined -like "*$Keyword*") { $Ok = $true; break } }
    if (-not $Ok) { throw "Unexpected signer for ${Path}: $Subj" }
  }
  Write-Host "Authenticode signature verified: $Path" -ForegroundColor Green
}

function Download-VerifiedFile
{
  param(
    [string]$Url,
    [string]$OutFile,
    [string]$ExpectedSha256 = '',
    [string[]]$AllowedPublisherKeywords = @(),
    [switch]$SkipAuthenticodeCheck,
    [long]$MinValidBytes = 10485760
  )
  if (-not $ForceUpdate)
  {
    Copy-FromCacheDirIfPresent -OutFile $OutFile -MinBytes $MinValidBytes | Out-Null
  }

  $HasValidHeaderAndSize = Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes
  $CanReuseExisting = (-not $ForceUpdate) -and $HasValidHeaderAndSize

  if ($CanReuseExisting -and (Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0))
  {
    try
    {
      if (-not (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes))
      {
        throw "Cached file header or size validation failed: $OutFile"
      }
      Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
      if (-not $SkipAuthenticodeCheck)
      {
        Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
      }
      Write-Host "Using existing verified download: $OutFile" -ForegroundColor Green
      return
    }
    catch
    {
      Write-Warning "Existing download could not be verified. Re-downloading. $($_.Exception.Message)"
      Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
  }

  Invoke-DownloadFile -Url $Url -OutFile $OutFile
  if (-not (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes))
  {
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    throw "Downloaded file failed binary header or minimum size validation ($MinValidBytes bytes): $OutFile"
  }
  Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
  if ($SkipAuthenticodeCheck)
  {
    Write-Warning "Skipping Authenticode check for this unsigned installer: $OutFile"
  }
  else
  {
    Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
  }
}

function Invoke-ParallelDownloadFiles
{
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Downloads
  )
  if ($Downloads.Count -eq 0) { return }

  New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
  try
  {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, 16)
  }
  catch {}

  $Pending = New-Object System.Collections.Generic.List[object]
  foreach ($Item in $Downloads)
  {
    $OutFile = [string]$Item.OutFile
    $MinBytes = if ($Item.PSObject.Properties['MinBytes'] -and $Item.MinBytes) { [long]$Item.MinBytes } else { 10485760L }
    if (-not $ForceUpdate)
    {
      Copy-FromCacheDirIfPresent -OutFile $OutFile -MinBytes $MinBytes | Out-Null
      if (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinBytes)
      {
        Write-Host "Prefetch cache hit: $OutFile" -ForegroundColor Green
        continue
      }
    }
    $Pending.Add($Item) | Out-Null
  }

  if ($Pending.Count -eq 0)
  {
    Write-Host 'All required installers are already cached locally.' -ForegroundColor Green
    return
  }

  Write-Section ("Parallel Prefetch ({0} installer(s))" -f $Pending.Count)
  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  $Handler = New-Object System.Net.Http.HttpClientHandler
  $Handler.AllowAutoRedirect = $true
  $Client = New-Object System.Net.Http.HttpClient($Handler)
  $Client.Timeout = [TimeSpan]::FromMinutes(60)
  try { $Client.DefaultRequestHeaders.UserAgent.ParseAdd('ContestSetup/2.0') } catch {}

  $Tasks = New-Object System.Collections.Generic.List[object]
  try
  {
    # Phase 1: Issue concurrent HTTP GET requests across distinct origins
    foreach ($Item in $Pending)
    {
      $Url = [string]$Item.Url
      $OutFile = [string]$Item.OutFile
      $MinBytes = if ($Item.PSObject.Properties['MinBytes'] -and $Item.MinBytes) { [long]$Item.MinBytes } else { 10485760L }
      $TempFile = "$OutFile.part"
      if (Test-Path -LiteralPath $TempFile) { Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue }
      Write-Host "Starting concurrent prefetch: $($Item.Name) ($Url)" -ForegroundColor Cyan
      $HttpTask = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
      $Tasks.Add([pscustomobject]@{
        Item        = $Item
        Url         = $Url
        OutFile     = $OutFile
        MinBytes    = $MinBytes
        TempFile    = $TempFile
        HeaderTask  = $HttpTask
        Response    = $null
        InStream    = $null
        OutStream   = $null
        CopyTask    = $null
        ExpectedLen = $null
        FailedError = $null
      }) | Out-Null
    }

    # Phase 2: Start asynchronous body stream CopyToAsync for all responses concurrently
    $ActiveCopyTasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    foreach ($Entry in $Tasks)
    {
      try
      {
        $Response = $Entry.HeaderTask.GetAwaiter().GetResult()
        $Entry.Response = $Response
        if (-not $Response.IsSuccessStatusCode)
        {
          throw "HTTP $([int]$Response.StatusCode) $($Response.ReasonPhrase)"
        }
        $Entry.ExpectedLen = $Response.Content.Headers.ContentLength
        $InStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { if ($InStream.CanTimeout) { $InStream.ReadTimeout = 120000 } } catch {}
        $Entry.InStream = $InStream
        $OutStream = [System.IO.File]::Open($Entry.TempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Entry.OutStream = $OutStream
        $CopyTask = $InStream.CopyToAsync($OutStream, 1048576)
        $Entry.CopyTask = $CopyTask
        $ActiveCopyTasks.Add($CopyTask) | Out-Null
      }
      catch
      {
        $Entry.FailedError = $_.Exception.Message
      }
    }

    # Phase 3: Wait concurrently for all active CopyToAsync tasks
    if ($ActiveCopyTasks.Count -gt 0)
    {
      try
      {
        [System.Threading.Tasks.Task]::WhenAll($ActiveCopyTasks.ToArray()).GetAwaiter().GetResult() | Out-Null
      }
      catch
      {
        # Individual task exceptions are handled per entry below
      }
    }

    # Phase 4: Finalize streams, validate sizes & headers, and sequentially retry any failed download
    foreach ($Entry in $Tasks)
    {
      try
      {
        if (-not [string]::IsNullOrWhiteSpace($Entry.FailedError))
        {
          throw $Entry.FailedError
        }
        if ($null -ne $Entry.CopyTask)
        {
          $Entry.CopyTask.GetAwaiter().GetResult() | Out-Null
        }
        if ($null -ne $Entry.OutStream)
        {
          $Entry.OutStream.Flush()
          $Entry.OutStream.Dispose()
          $Entry.OutStream = $null
        }

        $ActualLen = (Get-Item -LiteralPath $Entry.TempFile).Length
        if ($null -ne $Entry.ExpectedLen -and $Entry.ExpectedLen -gt 0 -and $ActualLen -ne $Entry.ExpectedLen)
        {
          throw "Content-Length mismatch (expected $($Entry.ExpectedLen), actual $ActualLen)"
        }
        Move-Item -LiteralPath $Entry.TempFile -Destination $Entry.OutFile -Force
        if (-not (Test-ValidCachedInstallerFile -Path $Entry.OutFile -MinBytes $Entry.MinBytes))
        {
          Remove-Item -LiteralPath $Entry.OutFile -Force -ErrorAction SilentlyContinue
          throw "Prefetched file failed binary header or minimum size validation ($($Entry.MinBytes) bytes)"
        }
        Write-Host "Prefetched: $($Entry.Item.Name) ($([math]::Round($ActualLen / 1MB, 1)) MB)" -ForegroundColor Green
      }
      catch
      {
        Write-Warning "Parallel prefetch for $($Entry.Item.Name) encountered an error ($($_.Exception.Message)); falling back to sequential retry..."
        if ($null -ne $Entry.OutStream) { try { $Entry.OutStream.Dispose() } catch {}; $Entry.OutStream = $null }
        if (Test-Path -LiteralPath $Entry.TempFile) { Remove-Item -LiteralPath $Entry.TempFile -Force -ErrorAction SilentlyContinue }
        Invoke-DownloadFile -Url $Entry.Url -OutFile $Entry.OutFile
        if (-not (Test-ValidCachedInstallerFile -Path $Entry.OutFile -MinBytes $Entry.MinBytes))
        {
          Remove-Item -LiteralPath $Entry.OutFile -Force -ErrorAction SilentlyContinue
          throw "Sequential fallback download failed binary header or minimum size validation ($($Entry.MinBytes) bytes): $($Entry.OutFile)"
        }
      }
      finally
      {
        if ($null -ne $Entry.OutStream) { try { $Entry.OutStream.Dispose() } catch {} }
        if ($null -ne $Entry.InStream) { try { $Entry.InStream.Dispose() } catch {} }
        if ($null -ne $Entry.Response) { try { $Entry.Response.Dispose() } catch {} }
      }
    }
  }
  finally
  {
    if ($Client) { $Client.Dispose() }
    if ($Handler) { $Handler.Dispose() }
  }
}

function Normalize-PathForCompare
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return ($Path -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
}

function Broadcast-EnvironmentChange
{
  try
  {
    if (-not ('ContestSetupWin32EnvBroadcast' -as [type]))
    {
      $CSharpLines = @(
        'using System;',
        'using System.Runtime.InteropServices;',
        'public static class ContestSetupWin32EnvBroadcast {',
        '  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]',
        '  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);',
        '}'
      )
      Add-Type -TypeDefinition ($CSharpLines -join [Environment]::NewLine) -Language CSharp -ErrorAction SilentlyContinue
    }
    $ResultPtr = [UIntPtr]::Zero
    [ContestSetupWin32EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 1000, [ref]$ResultPtr) | Out-Null
  }
  catch {}
}

function Resolve-ContestTargetUser
{
  param(
    [string]$ExplicitSid = '',
    [string]$ExplicitProfile = ''
  )
  $CurrentSid = ''
  $CurrentName = ''
  try
  {
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Identity -and $Identity.User) { $CurrentSid = [string]$Identity.User.Value }
    if ($Identity) { $CurrentName = [string]$Identity.Name }
  }
  catch {}

  $CandidateSid = ''
  if (-not [string]::IsNullOrWhiteSpace($ExplicitSid) -and $ExplicitSid.Trim() -ne 'S-1-5-18')
  {
    $CandidateSid = $ExplicitSid.Trim()
  }
  elseif (-not [string]::IsNullOrWhiteSpace($TargetUserSid) -and $TargetUserSid.Trim() -ne 'S-1-5-18')
  {
    $CandidateSid = $TargetUserSid.Trim()
  }
  elseif (Test-Path -LiteralPath $StateManifestPath)
  {
    try
    {
      $SavedManifest = Read-ContestStateManifest
      $SavedSid = [string]$SavedManifest['TargetUserSid']
      if (-not [string]::IsNullOrWhiteSpace($SavedSid) -and $SavedSid.Trim() -ne 'S-1-5-18')
      {
        $CandidateSid = $SavedSid.Trim()
      }
    }
    catch {}
  }

  # Detect active interactive console user via explorer.exe owner when running as SYSTEM or separate LabAdmin UAC
  if ([string]::IsNullOrWhiteSpace($CandidateSid))
  {
    try
    {
      $ExplorerProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)
      foreach ($ExpProc in $ExplorerProcs)
      {
        $OwnerSidInfo = Invoke-CimMethod -InputObject $ExpProc -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if ($OwnerSidInfo -and -not [string]::IsNullOrWhiteSpace([string]$OwnerSidInfo.Sid) -and ([string]$OwnerSidInfo.Sid -match '^S-1-5-21-'))
        {
          $CandidateSid = [string]$OwnerSidInfo.Sid
          break
        }
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($CandidateSid))
  {
    $CandidateSid = $CurrentSid
  }

  $IsSystemAccount = ([string]::IsNullOrWhiteSpace($CandidateSid) -or ($CandidateSid -eq 'S-1-5-18') -or ($CandidateSid -in @('S-1-5-19', 'S-1-5-20')))

  $ResolvedProfile = ''
  if (-not $IsSystemAccount)
  {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile) -and (Test-Path -LiteralPath $ExplicitProfile))
    {
      $ResolvedProfile = Normalize-ContestDirectoryPath $ExplicitProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TargetUserProfile) -and (Test-Path -LiteralPath $TargetUserProfile) -and ($CandidateSid -eq $TargetUserSid -or [string]::IsNullOrWhiteSpace($TargetUserSid)))
    {
      $ResolvedProfile = Normalize-ContestDirectoryPath $TargetUserProfile
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and (Test-Path -LiteralPath $StateManifestPath))
    {
      try
      {
        $SavedManifest = Read-ContestStateManifest
        $SavedProfile = [string]$SavedManifest['TargetUserProfile']
        if (-not [string]::IsNullOrWhiteSpace($SavedProfile) -and (Test-Path -LiteralPath $SavedProfile) -and ([string]$SavedManifest['TargetUserSid'] -eq $CandidateSid))
        {
          $ResolvedProfile = Normalize-ContestDirectoryPath $SavedProfile
        }
      }
      catch {}
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and -not [string]::IsNullOrWhiteSpace($CandidateSid))
    {
      $ProfileListReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CandidateSid"
      try
      {
        if (Test-Path -LiteralPath $ProfileListReg)
        {
          $ProfProps = Get-ItemProperty -LiteralPath $ProfileListReg -ErrorAction SilentlyContinue
          if ($ProfProps -and -not [string]::IsNullOrWhiteSpace([string]$ProfProps.ProfileImagePath))
          {
            $ExpandedProf = [Environment]::ExpandEnvironmentVariables([string]$ProfProps.ProfileImagePath)
            $ResolvedProfile = Normalize-ContestDirectoryPath $ExpandedProf
          }
        }
      }
      catch {}
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and ($CandidateSid -eq $CurrentSid) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE))
    {
      $ResolvedProfile = Normalize-ContestDirectoryPath $env:USERPROFILE
    }
  }

  $ResolvedUserName = $CurrentName
  if (-not [string]::IsNullOrWhiteSpace($CandidateSid))
  {
    try
    {
      $SecId = New-Object System.Security.Principal.SecurityIdentifier($CandidateSid)
      $ResolvedUserName = $SecId.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch
    {
      if (-not [string]::IsNullOrWhiteSpace($ResolvedProfile))
      {
        $ResolvedUserName = Split-Path -Path $ResolvedProfile -Leaf
      }
    }
  }

  return [pscustomobject]@{
    Sid         = $CandidateSid
    UserName    = $ResolvedUserName
    ProfilePath = $ResolvedProfile
    IsSystem    = $IsSystemAccount
  }
}

function Get-RawMachinePath
{
  try
  {
    $EnvKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    if ($null -ne $EnvKey)
    {
      try
      {
        $RawVal = $EnvKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [string]$RawVal
      }
      finally
      {
        $EnvKey.Dispose()
      }
    }
  }
  catch {}
  return [string]([Environment]::GetEnvironmentVariable('Path', 'Machine'))
}

function Set-RawMachinePath
{
  param([AllowEmptyString()] [string]$PathValue)
  $EnvKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
  if ($null -eq $EnvKey)
  {
    throw 'Could not open HKLM Environment registry key with write access.'
  }
  try
  {
    $ExistingKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try { $ExistingKind = $EnvKey.GetValueKind('Path') } catch {}
    $TargetKind = if ($PathValue -match '%' -or $ExistingKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
      [Microsoft.Win32.RegistryValueKind]::ExpandString
    } else {
      [Microsoft.Win32.RegistryValueKind]::String
    }
    $EnvKey.SetValue('Path', $PathValue, $TargetKind)
  }
  finally
  {
    $EnvKey.Dispose()
  }
  Broadcast-EnvironmentChange
}

function Get-UserPathForTargetUser
{
  param(
    [string]$TargetUserSid = '',
    [string]$TargetUserProfile = ''
  )
  $Resolved = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
  if ($Resolved.IsSystem -or [string]::IsNullOrWhiteSpace($Resolved.Sid) -or $Resolved.Sid -eq 'S-1-5-18')
  {
    return ''
  }

  $Sid = $Resolved.Sid
  $TempHiveName = $null
  $HiveLoadedByUs = $false
  try
  {
    $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid, $false)
    if ($null -eq $UserRootKey -and -not [string]::IsNullOrWhiteSpace($Resolved.ProfilePath) -and (Test-IsAdmin))
    {
      $NtUserDat = Join-Path $Resolved.ProfilePath 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat)
      {
        $SafeSidToken = $Sid -replace '[^A-Za-z0-9_-]', '_'
        $TempHiveName = "ContestSetupHive_$SafeSidToken"
        $LoadRes = Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('load', "HKU\$TempHiveName", $NtUserDat) -Quiet
        if ($LoadRes.ExitCode -eq 0)
        {
          $HiveLoadedByUs = $true
          $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($TempHiveName, $false)
        }
      }
    }

    if ($null -ne $UserRootKey)
    {
      try
      {
        $EnvSubKey = $UserRootKey.OpenSubKey('Environment', $false)
        if ($null -ne $EnvSubKey)
        {
          try
          {
            $RawVal = $EnvSubKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [string]$RawVal
          }
          finally
          {
            $EnvSubKey.Dispose()
          }
        }
        return ''
      }
      finally
      {
        $UserRootKey.Dispose()
      }
    }
  }
  catch {}
  finally
  {
    if ($HiveLoadedByUs -and $TempHiveName)
    {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKU\$TempHiveName") -Quiet | Out-Null } catch {}
    }
  }

  $CurrentIdentitySid = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
  if ($CurrentIdentitySid -eq $Sid -and $Sid -ne 'S-1-5-18')
  {
    return [string]([Environment]::GetEnvironmentVariable('Path', 'User'))
  }
  return ''
}

function Set-UserPathForTargetUser
{
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$PathValue,
    [string]$TargetUserSid = '',
    [string]$TargetUserProfile = ''
  )
  $Resolved = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
  if ($Resolved.IsSystem -or [string]::IsNullOrWhiteSpace($Resolved.Sid) -or $Resolved.Sid -eq 'S-1-5-18')
  {
    Write-Host 'Skipping HKU\.DEFAULT User PATH write because current target identity is SYSTEM (S-1-5-18) with no interactive student SID.' -ForegroundColor Gray
    return
  }

  $Sid = $Resolved.Sid
  $TempHiveName = $null
  $HiveLoadedByUs = $false
  $WroteRegistry = $false
  try
  {
    $TargetSubKeyName = $Sid
    $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid, $true)
    if ($null -eq $UserRootKey -and -not [string]::IsNullOrWhiteSpace($Resolved.ProfilePath) -and (Test-IsAdmin))
    {
      $NtUserDat = Join-Path $Resolved.ProfilePath 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat)
      {
        $SafeSidToken = $Sid -replace '[^A-Za-z0-9_-]', '_'
        $TempHiveName = "ContestSetupHive_$SafeSidToken"
        $LoadRes = Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('load', "HKU\$TempHiveName", $NtUserDat) -Quiet
        if ($LoadRes.ExitCode -eq 0)
        {
          $HiveLoadedByUs = $true
          $TargetSubKeyName = $TempHiveName
          $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($TargetSubKeyName, $true)
        }
      }
    }

    if ($null -ne $UserRootKey)
    {
      try
      {
        $EnvSubKey = $UserRootKey.CreateSubKey('Environment')
        if ($null -ne $EnvSubKey)
        {
          try
          {
            $ExistingKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
            try { $ExistingKind = $EnvSubKey.GetValueKind('Path') } catch {}
            $TargetKind = if ($PathValue -match '%' -or $ExistingKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
              [Microsoft.Win32.RegistryValueKind]::ExpandString
            } else {
              [Microsoft.Win32.RegistryValueKind]::String
            }
            $EnvSubKey.SetValue('Path', $PathValue, $TargetKind)
            $WroteRegistry = $true
          }
          finally
          {
            $EnvSubKey.Dispose()
          }
        }
      }
      finally
      {
        $UserRootKey.Dispose()
      }
    }
  }
  catch
  {
    Write-Warning "Could not write HKU\$Sid\Environment\Path directly: $($_.Exception.Message)"
  }
  finally
  {
    if ($HiveLoadedByUs -and $TempHiveName)
    {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKU\$TempHiveName") -Quiet | Out-Null } catch {}
    }
  }

  if (-not $WroteRegistry)
  {
    $CurrentIdentitySid = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
    if ($CurrentIdentitySid -eq $Sid -and $Sid -ne 'S-1-5-18')
    {
      [Environment]::SetEnvironmentVariable('Path', $PathValue, 'User')
      $WroteRegistry = $true
    }
  }

  if ($WroteRegistry)
  {
    Broadcast-EnvironmentChange
  }
}

function Add-UserPathFront
{
  param([Parameter(Mandatory = $true)] [string]$PathToAdd)
  Add-UserPathsFront -PathsToAdd @($PathToAdd)
}

function Add-UserPathsFront
{
  param([Parameter(Mandatory = $true)] [string[]]$PathsToAdd)
  $ValidPaths = @()
  $Seen = @{}
  foreach ($PathToAdd in $PathsToAdd)
  {
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) { continue }
    if (-not (Test-Path -LiteralPath $PathToAdd)) { Write-Warning "PATH target not found: $PathToAdd"; continue }
    $Normalized = Normalize-PathForCompare $PathToAdd
    if (-not $Seen.ContainsKey($Normalized))
    {
      $Seen[$Normalized] = $true
      $ValidPaths += $PathToAdd
    }
  }
  if ($ValidPaths.Count -eq 0) { return }

  $TargetNormals = @($Seen.Keys)
  $Current = Get-UserPathForTargetUser
  $UserParts = @()
  if (-not [string]::IsNullOrWhiteSpace($Current))
  {
    $UserParts = $Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
  }
  Set-UserPathForTargetUser -PathValue (($ValidPaths + $UserParts) -join ';').TrimEnd(';')

  # Also prepend to Machine PATH when running as Admin so Machine PATH entries never shadow contest tools in new terminals
  if (Test-IsAdmin)
  {
    try
    {
      $CurrentMachine = Get-RawMachinePath
      $MachineParts = @()
      if (-not [string]::IsNullOrWhiteSpace($CurrentMachine))
      {
        $MachineParts = $CurrentMachine.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
      }
      Set-RawMachinePath -PathValue (($ValidPaths + $MachineParts) -join ';').TrimEnd(';')
    }
    catch
    {
      Write-Warning "Could not update Machine PATH: $($_.Exception.Message)"
    }
  }

  $EnvParts = @()
  if (-not [string]::IsNullOrWhiteSpace($env:Path))
  {
    $EnvParts = $env:Path.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
  }
  $env:Path = (($ValidPaths + $EnvParts) -join ';').TrimEnd(';')

  foreach ($PathToAdd in $ValidPaths) { Write-Host "PATH added: $PathToAdd" -ForegroundColor Green }
}

function Remove-PathEntriesMatching
{
  param([Parameter(Mandatory = $true)] [string]$Scope, [Parameter(Mandatory = $true)] [scriptblock]$ShouldRemove)
  $Current = switch ($Scope)
  {
    'User'    { Get-UserPathForTargetUser }
    'Machine' { Get-RawMachinePath }
    default   { [Environment]::GetEnvironmentVariable('Path', $Scope) }
  }
  if ([string]::IsNullOrWhiteSpace($Current)) { return }
  $Removed = New-Object System.Collections.Generic.List[string]
  $Kept = New-Object System.Collections.Generic.List[string]
  foreach ($Part in ($Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
  {
    $Normalized = Normalize-PathForCompare $Part
    if (& $ShouldRemove $Part $Normalized) { $Removed.Add($Part) | Out-Null } else { $Kept.Add($Part) | Out-Null }
  }
  if ($Removed.Count -gt 0)
  {
    $UpdatedPath = ($Kept.ToArray() -join ';')
    switch ($Scope)
    {
      'User'    { Set-UserPathForTargetUser -PathValue $UpdatedPath }
      'Machine' { Set-RawMachinePath -PathValue $UpdatedPath }
      default   { [Environment]::SetEnvironmentVariable('Path', $UpdatedPath, $Scope) }
    }
    foreach ($PathEntry in $Removed) { Write-Host "PATH removed ($Scope): $PathEntry" -ForegroundColor Yellow }
  }
}

function Remove-ConflictingPathEntries
{
  Write-Section 'Clean conflicting PATH entries'
  $RootNorm = Normalize-PathForCompare $Root
  $MsysRootNorm = Normalize-PathForCompare $MsysRoot
  $PythonDirNorm = Normalize-PathForCompare $PythonDir
  $ToolBinNorm = Normalize-PathForCompare $ToolBin
  $PathBinNorm = Normalize-PathForCompare $PathBin

  $TargetUser = Resolve-ContestTargetUser
  $CandidateVSCodeBins = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA))
  {
    $CandidateVSCodeBins.Add((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($TargetUser.ProfilePath))
  {
    $CandidateVSCodeBins.Add((Join-Path $TargetUser.ProfilePath 'AppData\Local\Programs\Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles))
  {
    $CandidateVSCodeBins.Add((Join-Path $env:ProgramFiles 'Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)}))
  {
    $CandidateVSCodeBins.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')) | Out-Null
  }
  $VSCodeBinNorms = @($CandidateVSCodeBins | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ } | Select-Object -Unique)

  $ShouldRemove = {
    param($Original, $Normalized)
    $ExpandedNorm = try { Normalize-PathForCompare ([Environment]::ExpandEnvironmentVariables($Original)) } catch { $Normalized }
    foreach ($CheckNorm in @($Normalized, $ExpandedNorm))
    {
      if (
        $CheckNorm -eq $ToolBinNorm -or
        $CheckNorm -eq $PathBinNorm -or
        $CheckNorm -eq $PythonDirNorm -or
        $CheckNorm.StartsWith("$PythonDirNorm\") -or
        $CheckNorm -eq $MsysRootNorm -or
        $CheckNorm.StartsWith("$MsysRootNorm\") -or
        $CheckNorm -eq $RootNorm -or
        $CheckNorm.StartsWith("$RootNorm\") -or
        $VSCodeBinNorms -contains $CheckNorm
      ) {
        return $true
      }
    }
    return $false
  }.GetNewClosure()

  Remove-PathEntriesMatching -Scope 'User' -ShouldRemove $ShouldRemove
  if (Test-IsAdmin)
  {
    try { Remove-PathEntriesMatching -Scope 'Machine' -ShouldRemove $ShouldRemove } catch {}
  }
  Remove-PathEntriesMatching -Scope 'Process' -ShouldRemove $ShouldRemove
}

function Backup-PathEnvironment
{
  param([Parameter(Mandatory = $true)] [string]$BackupRoot)
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  $SnapshotPath = Join-Path $BackupRoot 'path-environment-before-cleanup.txt'
  if (Test-Path -LiteralPath $SnapshotPath)
  {
    Write-Host "PATH snapshot already exists, preserving original state: $SnapshotPath" -ForegroundColor Gray
    return
  }
  $TargetUser = Resolve-ContestTargetUser
  $UserPathVal = [string](Get-UserPathForTargetUser -TargetUserSid $TargetUser.Sid -TargetUserProfile $TargetUser.ProfilePath)
  $MachinePathVal = [string](Get-RawMachinePath)
  $Lines = @(
    'User PATH:',
    $UserPathVal,
    '',
    'Machine PATH:',
    $MachinePathVal,
    '',
    'Process PATH:',
    [string]$env:Path,
    '',
    'TargetUserSid:',
    [string]$TargetUser.Sid
  )
  Write-LinesUtf8NoBom -Path $SnapshotPath -Lines ([string[]]$Lines)
  Write-Host "PATH snapshot saved: $SnapshotPath" -ForegroundColor Green
}

function Get-PathHashToken
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  $Sha = [Security.Cryptography.SHA256]::Create()
  try
  {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Path)
    return [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '').Substring(0, 12)
  }
  finally { $Sha.Dispose() }
}

function Backup-PathVerified
{
  param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [string]$BackupRoot)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  $SafeLeaf = (Split-Path -Path $Path -Leaf) -replace '[\\/:*?"<>|]', '_'
  $Destination = Join-Path $BackupRoot ("{0}-{1}" -f $SafeLeaf, (Get-PathHashToken -Path $Path))
  if (Test-Path -LiteralPath $Destination)
  {
    Write-Host "Backup already exists, preserving original copy: $Destination" -ForegroundColor Gray
    return $Destination
  }
  Write-Host "Backing up: $Path`nBackup to : $Destination"
  $Item = Get-Item -LiteralPath $Path -Force
  if ($Item.PSIsContainer)
  {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $RoboLogPath = Join-Path (Join-Path $LogDir 'robocopy') ("backup-{0}-{1}.log" -f $SafeLeaf, $TimeStamp)
    New-Item -ItemType Directory -Force -Path (Split-Path $RoboLogPath -Parent) | Out-Null
    & robocopy.exe $Path $Destination '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' '/MT:16' "/LOG+:$RoboLogPath" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backup failed by robocopy. Source=$Path, Destination=$Destination" }
  }
  else
  {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Destination -Parent) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $Destination -Force
  }
  if (-not (Test-Path -LiteralPath $Destination)) { throw "Backup verification failed: $Destination" }
  return $Destination
}

function Backup-And-RemovePathSafe
{
  param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [string]$BackupRoot)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $BackupTarget = Backup-PathVerified -Path $Path -BackupRoot $BackupRoot
  Write-Host "Removing after verified backup: $Path"
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
  Write-Host "Backup saved: $BackupTarget" -ForegroundColor Green
}

function Test-WingetHelpSupports
{
  param([Parameter(Mandatory = $true)] [string]$Command, [Parameter(Mandatory = $true)] [string]$Option)
  try
  {
    if (-not $Script:WingetHelpCache.ContainsKey($Command))
    {
      $Script:WingetHelpCache[$Command] = ((& winget $Command --help 2>$null) -join "`n")
    }
    $HelpText = [string]$Script:WingetHelpCache[$Command]
    return $HelpText -match [regex]::Escape($Option)
  }
  catch { return $false }
}

function Invoke-Winget
{
  param([Parameter(Mandatory = $true)] [string[]]$Arguments)
  return (Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList $Arguments).ExitCode
}

function Install-ByWinget
{
  param([Parameter(Mandatory = $true)] [string]$Id, [Parameter(Mandatory = $true)] [string]$NameForLog)
  if (-not (Test-CommandExists 'winget')) { Write-Warning "winget not found. Fallback will be used for $NameForLog."; return $false }
  Write-Host "Installing by winget: $NameForLog"
  $WingetLogPath = Join-Path (Join-Path $LogDir 'winget') (($NameForLog -replace '[\\/:*?"<>| ]', '_') + "-install.log")
  New-Item -ItemType Directory -Force -Path (Split-Path $WingetLogPath -Parent) | Out-Null
  $Args = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--log', $WingetLogPath)
  if (Test-WingetHelpSupports -Command 'install' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  try
  {
    $ExitCode = Invoke-Winget -Arguments $Args
    if ($ExitCode -eq 0) { Write-Host "$NameForLog installed by winget." -ForegroundColor Green; return $true }
    if ((& winget list --id $Id --exact --accept-source-agreements 2>$null) -join "`n" -match [regex]::Escape($Id))
    {
      Write-Host "$NameForLog appears to be already installed. Continuing." -ForegroundColor Green; return $true
    }
  }
  catch { Write-Warning "winget failed for $NameForLog." }
  return $false
}

function Uninstall-WingetPackageIfExists
{
  param([Parameter(Mandatory = $true)] [string]$Id, [Parameter(Mandatory = $true)] [string]$NameForLog)
  if (-not (Test-CommandExists 'winget')) { return }
  try
  {
    if ((& winget list --id $Id --exact --accept-source-agreements 2>$null) -join "`n" -notmatch [regex]::Escape($Id)) { return }
  }
  catch { return }
  $Args = @('uninstall', '--id', $Id, '--exact', '--silent')
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--source') { $Args += '--source'; $Args += 'winget' }
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--accept-source-agreements') { $Args += '--accept-source-agreements' }
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  Write-Host "Uninstalling: $NameForLog"
  try { Invoke-Winget -Arguments $Args | Out-Null } catch {}
}

function Update-WingetClient
{
  Write-Section 'Update winget / App Installer'
  if (-not (Test-CommandExists 'winget')) { Write-Warning 'winget not found.'; return }
  $Args = @('upgrade', 'Microsoft.AppInstaller', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  if (Test-WingetHelpSupports -Command 'upgrade' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  try
  {
    $Exit = Invoke-Winget -Arguments $Args
    if ($Exit -eq 0) { Write-Host 'winget update completed.' -ForegroundColor Green }
  }
  catch {}
}

function Invoke-ContestEnvironmentAudit
{
  Write-Section 'ContestSetup v2.0 Environment Status & Verification'

  $RunExecutableChecks = ($Mode -eq 'Verify')
  $Checks = New-Object System.Collections.Generic.List[object]

  # 1. MSYS2 GCC/GDB/cat existence + executable health check in Verify mode
  $GppPath = Join-Path $UcrtBin 'g++.exe'
  $GccPath = Join-Path $UcrtBin 'gcc.exe'
  $GdbPath = Join-Path $UcrtBin 'gdb.exe'
  $MsysFilesOk = (Test-Path -LiteralPath $GppPath) -and (Test-Path -LiteralPath $GccPath) -and (Test-Path -LiteralPath $GdbPath) -and (Test-Path -LiteralPath $MsysCat)
  $MsysExecOk = $true
  $MsysDetail = if ($MsysFilesOk) { $UcrtBin } else { "Missing tools under $MsysRoot" }
  if ($MsysFilesOk -and $RunExecutableChecks)
  {
    $OldPath = $env:Path
    try
    {
      $env:Path = "$UcrtBin;$MsysUsrBin;$OldPath"
      foreach ($BinCheck in @($GppPath, $GccPath, $GdbPath, $MsysCat))
      {
        $VerRes = Invoke-NativeCommand -FilePath $BinCheck -ArgumentList @('--version') -Quiet
        if ($VerRes.ExitCode -ne 0)
        {
          $MsysExecOk = $false
          $MsysDetail = "Executable --version failed (exit $($VerRes.ExitCode)): $BinCheck"
          break
        }
      }
    }
    catch
    {
      $MsysExecOk = $false
      $MsysDetail = "Toolchain execution error: $($_.Exception.Message)"
    }
    finally
    {
      $env:Path = $OldPath
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'MSYS2 UCRT64 (g++, gcc, gdb, cat)'
    Ready     = ($MsysFilesOk -and $MsysExecOk)
    Detail    = $MsysDetail
  }) | Out-Null

  # 2. Python 3.10 existence + stdlib execution check in Verify mode
  $PyFilesOk = (Test-Path -LiteralPath $PythonExe) -and (Test-Path -LiteralPath $Python3Exe)
  $PyExecOk = $true
  $PyDetail = if ($PyFilesOk) { $PythonDir } else { "Missing $PythonExe or $Python3Exe" }
  if ($PyFilesOk -and $RunExecutableChecks)
  {
    try
    {
      $PyVerCheck = Invoke-NativeCommand -FilePath $PythonExe -ArgumentList @('--version') -Quiet
      $PyStdCheck = Invoke-NativeCommand -FilePath $PythonExe -ArgumentList @('-c', 'import site, encodings') -Quiet
      if ($PyVerCheck.ExitCode -ne 0 -or $PyStdCheck.ExitCode -ne 0)
      {
        $PyExecOk = $false
        $PyDetail = "Python runtime/stdlib check failed at $PythonExe"
      }
    }
    catch
    {
      $PyExecOk = $false
      $PyDetail = "Python execution error: $($_.Exception.Message)"
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = "Python $PythonVersion (python.exe & python3.exe)"
    Ready     = ($PyFilesOk -and $PyExecOk)
    Detail    = $PyDetail
  }) | Out-Null

  # 3. Standalone VS Code & Parsed Marketplace Lock
  $VSCodeAuditRoot = Join-Path $Root 'vscode'
  $CodeExePath = Join-Path $VSCodeAuditRoot 'Code.exe'
  $CodeCliPath = Join-Path $VSCodeAuditRoot 'bin\code.cmd'
  $ProductJsonPath = Resolve-VSCodeProductJsonPath -VSCodeRoot $VSCodeAuditRoot
  $VSCodeOk = (Test-Path -LiteralPath $CodeExePath) -and (Test-Path -LiteralPath $CodeCliPath) -and (-not [string]::IsNullOrWhiteSpace($ProductJsonPath)) -and (Test-Path -LiteralPath $ProductJsonPath)
  $MarketplaceLocked = $false
  if ($VSCodeOk)
  {
    try
    {
      $ProdRaw = Read-TextUtf8 -Path $ProductJsonPath
      $ProdObj = ConvertFrom-JsonSafe -Json $ProdRaw
      if ($null -ne $ProdObj)
      {
        $GalProp = $ProdObj.PSObject.Properties['extensionsGallery']
        if ($null -ne $GalProp -and $null -ne $GalProp.Value)
        {
          $SvcProp = $GalProp.Value.PSObject.Properties['serviceUrl']
          $ItmProp = $GalProp.Value.PSObject.Properties['itemUrl']
          $SvcLocked = ($null -ne $SvcProp) -and ([string]$SvcProp.Value -eq 'https://127.0.0.1')
          $ItmLocked = ($null -eq $ItmProp) -or ([string]$ItmProp.Value -eq 'https://127.0.0.1')
          $MarketplaceLocked = ($SvcLocked -and $ItmLocked)
        }
      }
    }
    catch {}
  }
  $Checks.Add([pscustomobject]@{
    Component = 'Portable VS Code & Marketplace Lock'
    Ready     = ($VSCodeOk -and $MarketplaceLocked)
    Detail    = "VSCode=$VSCodeOk, MarketplaceLocked=$MarketplaceLocked"
  }) | Out-Null

  # 4. VS Code Extensions, Korean Locale, Portable Data & AI Lockdown Settings
  $RequiredExts = @('ms-ceintl.vscode-language-pack-ko', 'ms-vscode.cpptools', 'ms-python.python', 'ms-python.debugpy')
  $AllowedExts = @(
    'ms-ceintl.vscode-language-pack-ko',
    'ms-vscode.cpptools',
    'ms-vscode.cpptools-themes',
    'ms-vscode.cpptools-extension-pack',
    'ms-python.python',
    'ms-python.debugpy',
    'ms-python.vscode-pylance',
    'ms-python.vscode-python-envs'
  )
  $ExtDir = Join-Path $Root 'vscode-contest\extensions'
  $PortableExtDir = Join-Path $Root 'vscode\data\extensions'
  $ExtFolders = if (Test-Path -LiteralPath $ExtDir) { @(Get-ChildItem -LiteralPath $ExtDir -Directory -ErrorAction SilentlyContinue) } else { @() }
  $MissingReqExts = @()
  foreach ($ReqExt in $RequiredExts)
  {
    $HasReq = @($ExtFolders | Where-Object { $_.Name.ToLowerInvariant().StartsWith("$ReqExt-") }).Count -gt 0
    if (-not $HasReq) { $MissingReqExts += $ReqExt }
  }
  $UnauthorizedExts = @()
  foreach ($ScanDir in @($ExtDir, $PortableExtDir))
  {
    if (Test-Path -LiteralPath $ScanDir)
    {
      foreach ($SubDir in @(Get-ChildItem -LiteralPath $ScanDir -Directory -ErrorAction SilentlyContinue))
      {
        $LowerName = $SubDir.Name.ToLowerInvariant()
        if ($LowerName.StartsWith('.')) { continue }
        $MatchedAllowed = $false
        foreach ($AllowId in $AllowedExts)
        {
          if ($LowerName -eq $AllowId -or $LowerName.StartsWith("$AllowId-"))
          {
            $MatchedAllowed = $true
            break
          }
        }
        if (-not $MatchedAllowed)
        {
          $UnauthorizedExts += $SubDir.Name
        }
      }
    }
  }

  $ContestArgvPath = Join-Path $Root 'vscode-contest\user-data\argv.json'
  $PortableArgvPath = Join-Path $Root 'vscode\data\argv.json'
  $ContestSettingsPath = Join-Path $Root 'vscode-contest\user-data\User\settings.json'
  $WorkspaceVscDir = Join-Path $Root 'contest\.vscode'
  $LocaleOk = $false
  $AiSettingsOk = $false
  try
  {
    if ((Test-Path -LiteralPath $ContestArgvPath) -and (Test-Path -LiteralPath $PortableArgvPath))
    {
      $ContestArgv = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $ContestArgvPath)
      $PortableArgv = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $PortableArgvPath)
      $ContestLocProp = if ($ContestArgv) { $ContestArgv.PSObject.Properties['locale'] } else { $null }
      $PortableLocProp = if ($PortableArgv) { $PortableArgv.PSObject.Properties['locale'] } else { $null }
      $LocaleOk = ($null -ne $ContestLocProp -and [string]$ContestLocProp.Value -eq 'ko') -and ($null -ne $PortableLocProp -and [string]$PortableLocProp.Value -eq 'ko')
    }
    if (Test-Path -LiteralPath $ContestSettingsPath)
    {
      $SetObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $ContestSettingsPath)
      $DisableAiProp = if ($SetObj) { $SetObj.PSObject.Properties['chat.disableAIFeatures'] } else { $null }
      $AiSettingsOk = ($null -ne $DisableAiProp -and [bool]$DisableAiProp.Value -eq $true)
    }
  }
  catch {}
  $WorkspaceCfgsOk = (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'tasks.json')) -and
                     (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'c_cpp_properties.json')) -and
                     (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'launch.json'))
  $ProfileHardened = ($MissingReqExts.Count -eq 0) -and ($UnauthorizedExts.Count -eq 0) -and $LocaleOk -and $AiSettingsOk -and $WorkspaceCfgsOk
  $ProfileDetailParts = @()
  if ($MissingReqExts.Count -gt 0) { $ProfileDetailParts += ("MissingExts=" + ($MissingReqExts -join ',')) }
  if ($UnauthorizedExts.Count -gt 0) { $ProfileDetailParts += ("UnauthorizedExts=" + ($UnauthorizedExts -join ',')) }
  if (-not $LocaleOk) { $ProfileDetailParts += 'LocaleKo=False' }
  if (-not $AiSettingsOk) { $ProfileDetailParts += 'AiDisabled=False' }
  if (-not $WorkspaceCfgsOk) { $ProfileDetailParts += 'WorkspaceConfigs=False' }
  $ProfileDetail = if ($ProfileHardened) { "4 required exts, allowlist clean, locale=ko, AI disabled" } else { $ProfileDetailParts -join '; ' }
  $Checks.Add([pscustomobject]@{
    Component = 'VS Code Contest Profile, Allowlist & Locale'
    Ready     = $ProfileHardened
    Detail    = $ProfileDetail
  }) | Out-Null

  # 5. All 10 Command Wrappers
  $ExpectedWrappers = @('g++14.cmd', 'g++17.cmd', 'g++20.cmd', 'g++.cmd', 'gcc.cmd', 'gdb.cmd', 'python.cmd', 'python3.cmd', 'cat.cmd', 'code.cmd')
  $MissingWrappers = @($ExpectedWrappers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ToolBin $_)) })
  $WrappersOk = ($MissingWrappers.Count -eq 0)
  $Checks.Add([pscustomobject]@{
    Component = 'CLI Wrappers (10 .cmd wrappers)'
    Ready     = $WrappersOk
    Detail    = if ($WrappersOk) { $ToolBin } else { "Missing in ${ToolBin}: " + ($MissingWrappers -join ', ') }
  }) | Out-Null

  # 6. AI Hosts Block (Active entries count + IPv4 & IPv6 sentinel domains inside managed section)
  $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $HostsBlocked = $false
  $HostsDetail = $HostsPath
  if (Test-Path -LiteralPath $HostsPath)
  {
    try
    {
      $HostsContent = Read-TextUtf8 -Path $HostsPath
      $BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
      $EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
      $SectionMatch = [regex]::Match($HostsContent, '(?s)' + [regex]::Escape($BeginMarker) + '(.*?)' + [regex]::Escape($EndMarker))
      if ($SectionMatch.Success)
      {
        $ManagedSection = $SectionMatch.Groups[1].Value
        $RuleMatches = [regex]::Matches($ManagedSection, '(?m)^\s*(?:0\.0\.0\.0|::)\s+\S+')
        $RuleCount = $RuleMatches.Count
        $SentinelsOk = ($ManagedSection -match '(?m)^\s*0\.0\.0\.0\s+chatgpt\.com\s*$') -and
                       ($ManagedSection -match '(?m)^\s*::\s+chatgpt\.com\s*$') -and
                       ($ManagedSection -match '(?m)^\s*0\.0\.0\.0\s+claude\.ai\s*$') -and
                       ($ManagedSection -match '(?m)^\s*::\s+claude\.ai\s*$')
        $HostsBlocked = ($RuleCount -ge 100) -and $SentinelsOk
        $HostsDetail = "$HostsPath ($RuleCount active block entries, IPv4+IPv6 verified=$SentinelsOk)"
      }
      elseif ($DeferAiBlockUntilExamStart)
      {
        $HostsDetail = "Deferred until ExamStart ($ExamStart) by -DeferAiBlockUntilExamStart"
        if ($Mode -eq 'Status') { $HostsBlocked = $true }
      }
      else
      {
        $HostsDetail = "Managed AI blocklist markers missing in $HostsPath"
      }
    }
    catch
    {
      $HostsDetail = "Could not inspect ${HostsPath}: $($_.Exception.Message)"
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'AI Hosts Blocklist'
    Ready     = $HostsBlocked
    Detail    = $HostsDetail
  }) | Out-Null

  # 7. Scheduled Task for Auto-Restore (State + Trigger + schtasks fallback + non-admin DACL note)
  $TaskReady = $false
  $TaskDetail = "Target: $RestoreAt"
  if ($NoRestoreTask)
  {
    $TaskReady = $true
    $TaskDetail = 'Skipped by -NoRestoreTask'
  }
  else
  {
    $TaskFound = $false
    try
    {
      $TaskObj = Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction SilentlyContinue
      if ($null -ne $TaskObj)
      {
        $TaskFound = $true
        $StateStr = [string]$TaskObj.State
        $StateOk = ($StateStr -notin @('Disabled', 'Unknown'))
        $BoundaryStr = ''
        $TriggerOk = $true
        if ($TaskObj.Triggers -and @($TaskObj.Triggers).Count -gt 0)
        {
          $FirstTrigger = @($TaskObj.Triggers)[0]
          if ($FirstTrigger.PSObject.Properties['StartBoundary'] -and -not [string]::IsNullOrWhiteSpace([string]$FirstTrigger.StartBoundary))
          {
            $BoundaryStr = [string]$FirstTrigger.StartBoundary
          }
        }
        else
        {
          $TriggerOk = $false
        }
        $TaskReady = ($StateOk -and $TriggerOk)
        $TaskDetail = "Registered (State: $StateStr, Trigger: $(if ($BoundaryStr) { $BoundaryStr } else { 'none' }), Target: $RestoreAt)"
      }
    }
    catch {}

    if (-not $TaskFound)
    {
      try
      {
        $SchRes = Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @('/Query', '/TN', 'ContestSetupRestoreAndCleanup', '/FO', 'LIST', '/V') -Quiet
        if ($SchRes.ExitCode -eq 0)
        {
          $TaskFound = $true
          $SchText = ($SchRes.Output -join "`n")
          $IsDisabled = ($SchText -imatch 'Status:\s*Disabled|Scheduled Task State:\s*Disabled')
          $TaskReady = (-not $IsDisabled)
          $TaskDetail = "Registered via schtasks (Disabled=$IsDisabled, Target: $RestoreAt)"
        }
      }
      catch {}
    }

    if ((-not $TaskFound) -and (-not (Test-IsAdmin)))
    {
      $ManifestRegistered = $false
      try
      {
        if (Test-Path -LiteralPath $StateManifestPath)
        {
          $SavedMan = Read-ContestStateManifest
          $ManifestRegistered = (@($SavedMan['CompletedModules']) -contains 'setup-restore-task.ps1')
        }
      }
      catch {}

      if ($Mode -eq 'Status' -and $ManifestRegistered)
      {
        $TaskReady = $true
        $TaskDetail = "Recorded in install-manifest.json (Run elevated to inspect SYSTEM Scheduled Task DACL directly; Target: $RestoreAt)"
      }
      else
      {
        $TaskDetail = "Not visible to non-admin token (Run elevated to inspect SYSTEM Scheduled Task DACL; Target: $RestoreAt)"
      }
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'Auto-Restore Scheduled Task'
    Ready     = $TaskReady
    Detail    = $TaskDetail
  }) | Out-Null

  $AllReady = $true
  foreach ($Check in $Checks)
  {
    $Badge = if ($Check.Ready) { '[READY]  ' } else { '[MISSING]' }
    $Color = if ($Check.Ready) { 'Green' } else { 'Yellow' }
    if (-not $Check.Ready) { $AllReady = $false }
    Write-Host ("{0} {1} -> {2}" -f $Badge, $Check.Component, $Check.Detail) -ForegroundColor $Color
  }

  return [pscustomobject]@{
    AllReady = $AllReady
    Checks   = $Checks.ToArray()
  }
}

Write-Host "common.ps1 (v$ContestSetupVersion) loaded successfully." -ForegroundColor Green
