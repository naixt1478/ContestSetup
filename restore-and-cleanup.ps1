#requires -Version 5.1
# restore-and-cleanup.ps1
# ContestSetup v2.0 -- Standalone & Scheduled Contest Environment Restoration & Cleanup
[CmdletBinding()]
param(
  [string]$Root = "$env:SystemDrive\CPTools",
  [string]$MsysRoot = "$env:SystemDrive\msys64",
  [string]$PythonDir = '',
  [string]$PythonVersion = '3.10.11',
  [string]$TargetUserSid = '',
  [string]$TargetUserProfile = '',
  [string]$ScheduledRestoreAt = '',
  [switch]$Shutdown,
  [switch]$KeepDownloads,
  [switch]$KeepLogs,
  [switch]$KeepWorkspace,
  [switch]$KeepVSCode,
  [switch]$PurgeWorkspace,
  [switch]$NoPause,
  [switch]$ReinvokedFromTemp
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

# Bind CONTEST_* environment variables when CLI parameters are omitted (and initialize defaults under irm | iex)
$BoundParamMap = if (Get-Variable -Name 'PSBoundParameters' -ErrorAction SilentlyContinue) { $PSBoundParameters } else { @{} }
foreach ($StrSpec in @(
  @{ Name = 'Root';               Env = 'CONTEST_ROOT';                Default = "$env:SystemDrive\CPTools"; AllowEmpty = $false },
  @{ Name = 'MsysRoot';           Env = 'CONTEST_MSYS_ROOT';           Default = "$env:SystemDrive\msys64";  AllowEmpty = $false },
  @{ Name = 'PythonDir';          Env = 'CONTEST_PYTHON_DIR';          Default = '';                          AllowEmpty = $true  },
  @{ Name = 'PythonVersion';      Env = 'CONTEST_PYTHON_VERSION';      Default = '3.10.11';                   AllowEmpty = $false },
  @{ Name = 'TargetUserSid';      Env = 'CONTEST_TARGET_USER_SID';     Default = '';                          AllowEmpty = $true  },
  @{ Name = 'TargetUserProfile';  Env = 'CONTEST_TARGET_USER_PROFILE'; Default = '';                          AllowEmpty = $true  },
  @{ Name = 'ScheduledRestoreAt'; Env = 'CONTEST_SCHEDULED_RESTORE_AT'; Default = '';                         AllowEmpty = $true  }
)) {
  $VarObj = Get-Variable -Name $StrSpec.Name -ErrorAction SilentlyContinue
  $EnvVal = [Environment]::GetEnvironmentVariable($StrSpec.Env)
  $IsExplicitlyBound = ($null -ne $BoundParamMap) -and $BoundParamMap.ContainsKey($StrSpec.Name)
  if ((-not $IsExplicitlyBound) -and (-not [string]::IsNullOrWhiteSpace($EnvVal)))
  {
    Set-Variable -Name $StrSpec.Name -Value $EnvVal
  }
  elseif ($null -eq $VarObj -or $null -eq $VarObj.Value -or ((-not $StrSpec.AllowEmpty) -and [string]::IsNullOrWhiteSpace([string]$VarObj.Value)))
  {
    Set-Variable -Name $StrSpec.Name -Value $StrSpec.Default
  }
}

foreach ($SwSpec in @(
  @{ Name = 'Shutdown';          Env = '' },
  @{ Name = 'KeepDownloads';     Env = '' },
  @{ Name = 'KeepLogs';          Env = '' },
  @{ Name = 'KeepWorkspace';     Env = '' },
  @{ Name = 'KeepVSCode';        Env = 'CONTEST_KEEP_VSCODE' },
  @{ Name = 'PurgeWorkspace';    Env = '' },
  @{ Name = 'NoPause';           Env = 'CONTEST_NO_PAUSE' },
  @{ Name = 'ReinvokedFromTemp'; Env = '' }
)) {
  $SwVar = Get-Variable -Name $SwSpec.Name -ErrorAction SilentlyContinue
  $IsSwBound = ($null -ne $BoundParamMap) -and $BoundParamMap.ContainsKey($SwSpec.Name)
  if ((-not $IsSwBound) -and (-not [string]::IsNullOrWhiteSpace($SwSpec.Env)))
  {
    $SwEnvVal = [Environment]::GetEnvironmentVariable($SwSpec.Env)
    if ($SwEnvVal -match '^(1|true|yes)$')
    {
      Set-Variable -Name $SwSpec.Name -Value ([switch]$true)
      continue
    }
  }
  if ($null -eq $SwVar)
  {
    Set-Variable -Name $SwSpec.Name -Value ([switch]$false)
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
  $WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $WinPs) { return $WinPs }
  $PwshCmds = @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue | Where-Object {
    $_.Source -and ($_.Source -notmatch '\\WindowsApps\\')
  })
  if ($PwshCmds.Count -gt 0) { return $PwshCmds[0].Source }
  return 'powershell.exe'
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

function Read-TextUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-LinesUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}

function Write-TextUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content
  )
  $Dir = [IO.Path]::GetDirectoryName($Path)
  if (-not [string]::IsNullOrWhiteSpace($Dir))
  {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  }
  $Utf8NoBomEnc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBomEnc)
}

function Strip-JsonComments
{
  param([AllowNull()] [AllowEmptyString()] [string]$Json)
  if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
  $Src = $Json.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
  if ([string]::IsNullOrWhiteSpace($Src)) { return '' }
  $Sb = New-Object System.Text.StringBuilder
  $InString = $false
  $Len = $Src.Length
  $Idx = 0
  while ($Idx -lt $Len)
  {
    $Ch = $Src[$Idx]
    if ($InString)
    {
      [void]$Sb.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        $Idx++
        [void]$Sb.Append($Src[$Idx])
      }
      elseif ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }
    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$Sb.Append($Ch)
      $Idx++
      continue
    }
    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Src[$Idx + 1] -eq '/')
    {
      $Idx += 2
      while ($Idx -lt $Len -and $Src[$Idx] -ne "`n" -and $Src[$Idx] -ne "`r") { $Idx++ }
      continue
    }
    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Src[$Idx + 1] -eq '*')
    {
      $Idx += 2
      while ($Idx -lt $Len)
      {
        if (($Idx + 1) -lt $Len -and $Src[$Idx] -eq '*' -and $Src[$Idx + 1] -eq '/')
        {
          $Idx += 2
          break
        }
        $Idx++
      }
      continue
    }
    [void]$Sb.Append($Ch)
    $Idx++
  }

  $Pass1 = $Sb.ToString()
  $OutSb = New-Object System.Text.StringBuilder
  $InString = $false
  $Len = $Pass1.Length
  $Idx = 0
  while ($Idx -lt $Len)
  {
    $Ch = $Pass1[$Idx]
    if ($InString)
    {
      [void]$OutSb.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        $Idx++
        [void]$OutSb.Append($Pass1[$Idx])
      }
      elseif ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }
    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$OutSb.Append($Ch)
      $Idx++
      continue
    }
    if ($Ch -eq ',')
    {
      $Look = $Idx + 1
      while ($Look -lt $Len -and ($Pass1[$Look] -eq ' ' -or $Pass1[$Look] -eq "`t" -or $Pass1[$Look] -eq "`r" -or $Pass1[$Look] -eq "`n")) { $Look++ }
      if ($Look -lt $Len -and ($Pass1[$Look] -eq '}' -or $Pass1[$Look] -eq ']'))
      {
        $Idx++
        continue
      }
    }
    [void]$OutSb.Append($Ch)
    $Idx++
  }
  return $OutSb.ToString().Trim()
}

function ConvertFrom-JsonSafe
{
  param([AllowNull()] [AllowEmptyString()] [string]$Json)
  $Clean = Strip-JsonComments -Json $Json
  if ([string]::IsNullOrWhiteSpace($Clean)) { return $null }
  return (ConvertFrom-Json -InputObject $Clean -ErrorAction Stop)
}

function ConvertFrom-JsonArray
{
  param([AllowNull()] [AllowEmptyString()] [string]$Json)
  $Parsed = ConvertFrom-JsonSafe -Json $Json
  if ($null -eq $Parsed) { return @() }
  if ($Parsed -is [System.Array]) { return $Parsed }
  return @($Parsed)
}

function Build-RestoreForwardArgs
{
  param(
    [Parameter(Mandatory = $true)] [string]$ScriptFile,
    [switch]$IncludeReinvokedFromTemp
  )
  $ArgItems = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $ScriptFile,
    '-Root', $Root,
    '-MsysRoot', $MsysRoot,
    '-PythonVersion', $PythonVersion
  )
  if (-not [string]::IsNullOrWhiteSpace($PythonDir)) { $ArgItems += @('-PythonDir', $PythonDir) }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserSid)) { $ArgItems += @('-TargetUserSid', $TargetUserSid) }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) { $ArgItems += @('-TargetUserProfile', $TargetUserProfile) }
  if (-not [string]::IsNullOrWhiteSpace($ScheduledRestoreAt)) { $ArgItems += @('-ScheduledRestoreAt', $ScheduledRestoreAt) }
  if ($Shutdown) { $ArgItems += '-Shutdown' }
  if ($KeepDownloads) { $ArgItems += '-KeepDownloads' }
  if ($KeepLogs) { $ArgItems += '-KeepLogs' }
  if ($KeepWorkspace) { $ArgItems += '-KeepWorkspace' }
  if ($KeepVSCode) { $ArgItems += '-KeepVSCode' }
  if ($PurgeWorkspace) { $ArgItems += '-PurgeWorkspace' }
  if ($NoPause) { $ArgItems += '-NoPause' }
  if ($IncludeReinvokedFromTemp -or $ReinvokedFromTemp) { $ArgItems += '-ReinvokedFromTemp' }
  return $ArgItems
}

# Enforce Administrator privileges FIRST before modifying shortcuts, PATH, hosts, or files
if (-not (Test-IsAdmin))
{
  # Capture invoking student's SID & profile BEFORE UAC elevation switches token to LabAdmin
  try
  {
    $PreElevIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ([string]::IsNullOrWhiteSpace($TargetUserSid) -and $PreElevIdentity -and $PreElevIdentity.User -and $PreElevIdentity.User.Value -ne 'S-1-5-18')
    {
      $TargetUserSid = $PreElevIdentity.User.Value
    }
    if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -and (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)))
    {
      $TargetUserProfile = $env:USERPROFILE
    }
  }
  catch {}

  Write-Host 'Requesting administrator permission for restore-and-cleanup.ps1...' -ForegroundColor Yellow
  $SelfPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($SelfPath) -or -not (Test-Path -LiteralPath $SelfPath))
  {
    $StagedCopy = Join-Path $Root 'restore-and-cleanup.ps1'
    if (Test-Path -LiteralPath $StagedCopy)
    {
      $SelfPath = $StagedCopy
    }
    else
    {
      $TempDir = Join-Path $env:TEMP 'contest-env-installer'
      New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
      $SelfPath = Join-Path $TempDir 'restore-and-cleanup.ps1'
      try
      {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      }
      catch {}
      $OldProgressPref = $ProgressPreference
      try
      {
        $ProgressPreference = 'SilentlyContinue'
        $Params = @{ Uri = "$RawBase/restore-and-cleanup.ps1"; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
        $Resp = Invoke-WebRequest @Params
        $DecodedScript = ''
        if ($null -ne $Resp.PSObject.Properties['RawContentStream'] -and $null -ne $Resp.RawContentStream)
        {
          $Resp.RawContentStream.Position = 0
          $MemBytes = New-Object byte[] $Resp.RawContentStream.Length
          [void]$Resp.RawContentStream.Read($MemBytes, 0, $MemBytes.Length)
          $DecodedScript = [System.Text.Encoding]::UTF8.GetString($MemBytes)
        }
        elseif ($Resp.Content -is [byte[]])
        {
          $DecodedScript = [System.Text.Encoding]::UTF8.GetString([byte[]]$Resp.Content)
        }
        else
        {
          $DecodedScript = [string]$Resp.Content
        }
        if ($DecodedScript.Length -gt 0 -and [int][char]$DecodedScript[0] -eq 0xFEFF)
        {
          $DecodedScript = $DecodedScript.Substring(1)
        }
        $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($SelfPath, $DecodedScript, $Utf8Bom)
      }
      finally
      {
        $ProgressPreference = $OldProgressPref
      }
    }
  }

  $StartArgs = Build-RestoreForwardArgs -ScriptFile $SelfPath
  $ArgumentString = ($StartArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
  try
  {
    $ElevatedProc = Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $ArgumentString -Verb RunAs -Wait -PassThru
    $ExitCode = if ($null -ne $ElevatedProc) { [int]$ElevatedProc.ExitCode } else { 0 }
  }
  catch [System.ComponentModel.Win32Exception]
  {
    Write-Warning "Administrator UAC prompt was cancelled or denied: $($_.Exception.Message)"
    $ExitCode = 1
  }

  if ($PSCommandPath)
  {
    exit $ExitCode
  }
  else
  {
    $global:LASTEXITCODE = $ExitCode
    return
  }
}

# Disable QuickEdit mode and define Win32 WM_SETTINGCHANGE broadcaster
try
{
  $ConsoleAndEnvCode = @"
  using System;
  using System.Runtime.InteropServices;
  public class ConsoleConfig {
      const int STD_INPUT_HANDLE = -10;
      const uint ENABLE_QUICK_EDIT = 0x0040;
      const int HWND_BROADCAST = 0xffff;
      const uint WM_SETTINGCHANGE = 0x001A;
      const uint SMTO_ABORTIFHUNG = 0x0002;
      [DllImport("kernel32.dll", SetLastError = true)]
      static extern IntPtr GetStdHandle(int nStdHandle);
      [DllImport("kernel32.dll")]
      static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
      [DllImport("kernel32.dll")]
      static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
      [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
      static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
      public static void DisableQuickEdit() {
          IntPtr consoleHandle = GetStdHandle(STD_INPUT_HANDLE);
          uint consoleMode;
          if (GetConsoleMode(consoleHandle, out consoleMode)) {
              consoleMode &= ~ENABLE_QUICK_EDIT;
              SetConsoleMode(consoleHandle, consoleMode);
          }
      }
      public static void BroadcastEnvironmentChange() {
          UIntPtr result;
          SendMessageTimeout((IntPtr)HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero, "Environment", SMTO_ABORTIFHUNG, 1000, out result);
      }
  }
"@
  Add-Type -TypeDefinition $ConsoleAndEnvCode -Language CSharp -ErrorAction SilentlyContinue
  [ConsoleConfig]::DisableQuickEdit()
}
catch {}

function Get-NormalizedFullPath
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Normalize-PathForCompare
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return $Path.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

function Assert-SafeRemovalPath
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Path))
  {
    throw "FATAL: $Name is empty. Aborting cleanup."
  }

  $Trimmed = $Path.Trim()
  if (-not [System.IO.Path]::IsPathRooted($Trimmed))
  {
    throw "FATAL: $Name must be an absolute path. Aborting cleanup. Value: $Path"
  }
  if ($Trimmed -match '^[A-Za-z]:[\\/]*$')
  {
    throw "FATAL: $Name points to a drive root. Aborting cleanup. Value: $Path"
  }

  $Normalized = Get-NormalizedFullPath -Path $Trimmed
  $CriticalPaths = @(
    (Get-NormalizedFullPath -Path ([System.IO.Path]::GetPathRoot($Normalized))),
    (Get-NormalizedFullPath -Path $env:SystemRoot),
    (Get-NormalizedFullPath -Path $env:ProgramData)
  )
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $CriticalPaths += (Get-NormalizedFullPath -Path $env:USERPROFILE) }
  if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) { $CriticalPaths += (Get-NormalizedFullPath -Path $TargetUserProfile) }
  if ($env:ProgramFiles) { $CriticalPaths += (Get-NormalizedFullPath -Path $env:ProgramFiles) }
  if (${env:ProgramFiles(x86)}) { $CriticalPaths += (Get-NormalizedFullPath -Path ${env:ProgramFiles(x86)}) }

  if ($CriticalPaths -contains $Normalized)
  {
    throw "FATAL: Safe-guard triggered. $Name ($Path) is a critical system path. Aborting cleanup."
  }

  return $Normalized
}

function Test-PathInside
{
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$ChildPath,
    [Parameter(Mandatory = $true)] [string]$ParentPath
  )
  if ([string]::IsNullOrWhiteSpace($ChildPath)) { return $false }
  try
  {
    $Child = Get-NormalizedFullPath -Path $ChildPath
    $Parent = Get-NormalizedFullPath -Path $ParentPath
    $ParentPrefix = $Parent + '\'
    return ($Child -ieq $Parent) -or $Child.StartsWith($ParentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
  }
  catch
  {
    return $false
  }
}

function Stop-ProcessesUnderPath
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [string[]]$ProcessNames = @()
  )
  # Terminate ANY process whose executable path resides inside $Path (catches Code, cpptools-srv, rg, node, python, student binaries, etc.)
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    if ($_.Id -eq $PID) { return $false }
    $ProcExe = try { $_.Path } catch { $null }
    return ($null -ne $ProcExe) -and (Test-PathInside -ChildPath $ProcExe -ParentPath $Path)
  } | ForEach-Object {
    try
    {
      Write-Host "  Stopping process: $($_.ProcessName) (PID $($_.Id))" -ForegroundColor Gray
      Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    catch {}
  }

  foreach ($ProcName in $ProcessNames)
  {
    Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object {
      if ($_.Id -eq $PID) { return $false }
      $NamedExe = try { $_.Path } catch { $null }
      return ($null -ne $NamedExe) -and (Test-PathInside -ChildPath $NamedExe -ParentPath $Path)
    } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

function Get-ObjectPropertyValue
{
  param([AllowNull()] [object]$Object, [Parameter(Mandatory = $true)] [string]$Name)
  if ($null -eq $Object -or $null -eq $Object.PSObject) { return '' }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return '' }
  return [string]$Property.Value
}

function ConvertTo-LocalScheduleTime
{
  param([Parameter(Mandatory = $true)] [string]$Text)
  $Trimmed = $Text.Trim()
  if ($Trimmed -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$')
  {
    $IsoKst = ($Trimmed -replace ' ', 'T') + '+09:00'
    return ([DateTimeOffset]::Parse($IsoKst, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
  }
  return ([DateTimeOffset]::Parse($Trimmed, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
}

function Resolve-ProfilePathFromSid
{
  param([AllowNull()] [string]$Sid)
  if ([string]::IsNullOrWhiteSpace($Sid) -or $Sid -eq 'S-1-5-18') { return '' }
  try
  {
    $ProfKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path -LiteralPath $ProfKey)
    {
      $ProfProps = Get-ItemProperty -LiteralPath $ProfKey -ErrorAction SilentlyContinue
      $RawImg = Get-ObjectPropertyValue -Object $ProfProps -Name 'ProfileImagePath'
      if (-not [string]::IsNullOrWhiteSpace($RawImg))
      {
        return [Environment]::ExpandEnvironmentVariables($RawImg)
      }
    }
  }
  catch {}
  return ''
}

function Resolve-TargetStudentIdentity
{
  param(
    [AllowNull()] [string]$CandidateSid,
    [AllowNull()] [string]$CandidateProfile
  )
  $ResolvedSid = if (-not [string]::IsNullOrWhiteSpace($CandidateSid) -and $CandidateSid -ne 'S-1-5-18') { $CandidateSid.Trim() } else { '' }
  $ResolvedProfile = if (-not [string]::IsNullOrWhiteSpace($CandidateProfile)) { $CandidateProfile.Trim() } else { '' }

  if ([string]::IsNullOrWhiteSpace($ResolvedSid))
  {
    # Detect active console explorer.exe owner SID when running under SYSTEM or LabAdmin
    try
    {
      if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)
      {
        $ExplorerProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)
        foreach ($ExpProc in $ExplorerProcs)
        {
          $OwnerRes = Invoke-CimMethod -InputObject $ExpProc -MethodName GetOwnerSid -ErrorAction SilentlyContinue
          if ($null -ne $OwnerRes -and (-not [string]::IsNullOrWhiteSpace($OwnerRes.Sid)) -and $OwnerRes.Sid -ne 'S-1-5-18')
          {
            $ResolvedSid = [string]$OwnerRes.Sid
            break
          }
        }
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($ResolvedSid))
  {
    try
    {
      $CurId = [Security.Principal.WindowsIdentity]::GetCurrent()
      if ($CurId -and $CurId.User -and $CurId.User.Value -ne 'S-1-5-18')
      {
        $ResolvedSid = $CurId.User.Value
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and (-not [string]::IsNullOrWhiteSpace($ResolvedSid)))
  {
    $ResolvedProfile = Resolve-ProfilePathFromSid -Sid $ResolvedSid
  }

  if ([string]::IsNullOrWhiteSpace($ResolvedSid) -and (-not [string]::IsNullOrWhiteSpace($ResolvedProfile)))
  {
    try
    {
      $NormTargetProf = Normalize-PathForCompare $ResolvedProfile
      $ProfListItems = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)
      foreach ($Item in $ProfListItems)
      {
        if ($Item.PSChildName -notmatch '^S-1-5-21-') { continue }
        $Props = Get-ItemProperty -LiteralPath $Item.PSPath -ErrorAction SilentlyContinue
        $Img = Get-ObjectPropertyValue -Object $Props -Name 'ProfileImagePath'
        if (-not [string]::IsNullOrWhiteSpace($Img))
        {
          $Expanded = [Environment]::ExpandEnvironmentVariables($Img)
          if ((Normalize-PathForCompare $Expanded) -eq $NormTargetProf)
          {
            $ResolvedSid = $Item.PSChildName
            break
          }
        }
      }
    }
    catch {}
  }

  return [pscustomobject]@{
    Sid         = $ResolvedSid
    ProfilePath = $ResolvedProfile
  }
}

function Broadcast-EnvironmentSettingChange
{
  try { [ConsoleConfig]::BroadcastEnvironmentChange() } catch {}
}

function Get-RegistryScopePathValue
{
  param(
    [Parameter(Mandatory = $true)] [ValidateSet('User', 'Machine')] [string]$Scope,
    [string]$UserSid = '',
    [string]$UserProfile = ''
  )
  if ($Scope -eq 'Machine')
  {
    $RegKey = $null
    try
    {
      $RegKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
      if ($null -eq $RegKey) { return '' }
      $Val = $RegKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      return [string]$Val
    }
    catch
    {
      return [string]([Environment]::GetEnvironmentVariable('Path', 'Machine'))
    }
    finally
    {
      if ($null -ne $RegKey) { $RegKey.Close() }
    }
  }

  $CurSid = try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
  $EffectiveSid = if (-not [string]::IsNullOrWhiteSpace($UserSid) -and $UserSid -ne 'S-1-5-18') { $UserSid } elseif ($CurSid -ne 'S-1-5-18') { $CurSid } else { '' }
  if ([string]::IsNullOrWhiteSpace($EffectiveSid))
  {
    return ''
  }

  $LoadedTempHive = $false
  $HiveRootName = $EffectiveSid
  $TempHiveMount = "ContestTemp_$($EffectiveSid -replace '[^A-Za-z0-9_-]', '_')"
  $SubKeyObj = $null
  try
  {
    $MountedTest = [Microsoft.Win32.Registry]::Users.OpenSubKey($EffectiveSid, $false)
    if ($null -ne $MountedTest)
    {
      $MountedTest.Close()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($UserProfile))
    {
      $NtUserDat = Join-Path $UserProfile 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat)
      {
        & reg.exe load "HKU\$TempHiveMount" $NtUserDat 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0)
        {
          $LoadedTempHive = $true
          $HiveRootName = $TempHiveMount
        }
      }
    }

    $SubKeyObj = [Microsoft.Win32.Registry]::Users.OpenSubKey("$HiveRootName\Environment", $false)
    if ($null -eq $SubKeyObj) { return '' }
    $RawVal = $SubKeyObj.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [string]$RawVal
  }
  catch
  {
    if ($CurSid -ne 'S-1-5-18' -and $CurSid -eq $EffectiveSid)
    {
      return [string]([Environment]::GetEnvironmentVariable('Path', 'User'))
    }
    return ''
  }
  finally
  {
    if ($null -ne $SubKeyObj) { $SubKeyObj.Close() }
    if ($LoadedTempHive)
    {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { & reg.exe unload "HKU\$TempHiveMount" 2>$null | Out-Null } catch {}
    }
  }
}

function Set-RegistryScopePathValue
{
  param(
    [Parameter(Mandatory = $true)] [ValidateSet('User', 'Machine')] [string]$Scope,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$PathValue,
    [string]$UserSid = '',
    [string]$UserProfile = ''
  )
  if ($Scope -eq 'Machine')
  {
    $RegKey = $null
    try
    {
      $RegKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
      if ($null -ne $RegKey)
      {
        $RegKey.SetValue('Path', $PathValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Broadcast-EnvironmentSettingChange
        return $true
      }
    }
    catch {}
    finally
    {
      if ($null -ne $RegKey) { $RegKey.Close() }
    }
    [Environment]::SetEnvironmentVariable('Path', $PathValue, 'Machine')
    return $true
  }

  $CurSid = try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
  $EffectiveSid = if (-not [string]::IsNullOrWhiteSpace($UserSid) -and $UserSid -ne 'S-1-5-18') { $UserSid } elseif ($CurSid -ne 'S-1-5-18') { $CurSid } else { '' }

  # NEVER write User PATH into HKU\.DEFAULT when running under SYSTEM (S-1-5-18)
  if ([string]::IsNullOrWhiteSpace($EffectiveSid) -or $EffectiveSid -eq 'S-1-5-18')
  {
    Write-Warning '  Skipping User PATH registry write under SYSTEM because no student TargetUserSid was resolved (protecting HKU\.DEFAULT).'
    return $false
  }

  $LoadedTempHive = $false
  $HiveRootName = $EffectiveSid
  $TempHiveMount = "ContestTemp_$($EffectiveSid -replace '[^A-Za-z0-9_-]', '_')"
  $UserRootKey = $null
  $EnvSubKey = $null
  try
  {
    $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($EffectiveSid, $true)
    if ($null -eq $UserRootKey -and (-not [string]::IsNullOrWhiteSpace($UserProfile)))
    {
      $NtUserDat = Join-Path $UserProfile 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat)
      {
        & reg.exe load "HKU\$TempHiveMount" $NtUserDat 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0)
        {
          $LoadedTempHive = $true
          $HiveRootName = $TempHiveMount
          $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($HiveRootName, $true)
        }
      }
    }

    if ($null -ne $UserRootKey)
    {
      $EnvSubKey = $UserRootKey.CreateSubKey('Environment')
      if ($null -ne $EnvSubKey)
      {
        $EnvSubKey.SetValue('Path', $PathValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Broadcast-EnvironmentSettingChange
        return $true
      }
    }
  }
  catch
  {
    Write-Warning "  Registry User PATH write warning for SID $EffectiveSid : $($_.Exception.Message)"
  }
  finally
  {
    if ($null -ne $EnvSubKey) { $EnvSubKey.Close() }
    if ($null -ne $UserRootKey) { $UserRootKey.Close() }
    if ($LoadedTempHive)
    {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { & reg.exe unload "HKU\$TempHiveMount" 2>$null | Out-Null } catch {}
    }
  }

  if ($CurSid -ne 'S-1-5-18' -and $CurSid -eq $EffectiveSid)
  {
    [Environment]::SetEnvironmentVariable('Path', $PathValue, 'User')
    return $true
  }
  return $false
}

function Remove-ContestEntriesFromPathScope
{
  param(
    [Parameter(Mandatory = $true)] [ValidateSet('User', 'Machine', 'Process')] [string]$Scope,
    [Parameter(Mandatory = $true)] [string]$ContestRoot,
    [string]$MsysRootPath = '',
    [switch]$IncludeMsys,
    [string]$UserSid = '',
    [string]$UserProfile = ''
  )
  try
  {
    $Current = if ($Scope -eq 'Process') {
      [string]$env:Path
    } else {
      Get-RegistryScopePathValue -Scope $Scope -UserSid $UserSid -UserProfile $UserProfile
    }
    if ([string]::IsNullOrWhiteSpace($Current)) { return }

    $RootNorm = Normalize-PathForCompare $ContestRoot
    $MsysNorm = if ($IncludeMsys -and (-not [string]::IsNullOrWhiteSpace($MsysRootPath))) { Normalize-PathForCompare $MsysRootPath } else { '' }
    $Kept = New-Object System.Collections.Generic.List[string]
    $Changed = $false
    foreach ($Part in ($Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
      $ExpandedPart = [Environment]::ExpandEnvironmentVariables($Part)
      $Norm = Normalize-PathForCompare $ExpandedPart
      $MatchesRoot = ($Norm -eq $RootNorm) -or $Norm.StartsWith("$RootNorm\")
      $MatchesMsys = (-not [string]::IsNullOrWhiteSpace($MsysNorm)) -and (($Norm -eq $MsysNorm) -or $Norm.StartsWith("$MsysNorm\"))
      if ($MatchesRoot -or $MatchesMsys)
      {
        $Changed = $true
      }
      else
      {
        $Kept.Add($Part) | Out-Null
      }
    }
    if ($Changed)
    {
      $UpdatedPath = $Kept.ToArray() -join ';'
      if ($Scope -eq 'Process')
      {
        $env:Path = $UpdatedPath
        Write-Host "  Cleaned residual contest PATH entries from Process scope." -ForegroundColor Green
      }
      elseif (Set-RegistryScopePathValue -Scope $Scope -PathValue $UpdatedPath -UserSid $UserSid -UserProfile $UserProfile)
      {
        Write-Host "  Cleaned residual contest PATH entries from $Scope scope." -ForegroundColor Green
      }
    }
  }
  catch {}
}

function Restore-Msys2ContestConfiguration
{
  param(
    [AllowNull()] [string]$ToolchainRoot,
    [AllowNull()] [string]$CustomCaFileName = ''
  )
  # Non-destructively restore MSYS2 pacman.conf, mirrorlists, and CA anchors without deleting the MSYS2 installation itself
  if ([string]::IsNullOrWhiteSpace($ToolchainRoot) -or (-not (Test-Path -LiteralPath $ToolchainRoot)))
  {
    return
  }

  $PacmanConfFile = Join-Path $ToolchainRoot 'etc\pacman.conf'
  $PacmanConfBak = "$PacmanConfFile.contest-bak"
  if (Test-Path -LiteralPath $PacmanConfBak)
  {
    try
    {
      Copy-Item -LiteralPath $PacmanConfBak -Destination $PacmanConfFile -Force
      Remove-Item -LiteralPath $PacmanConfBak -Force -ErrorAction SilentlyContinue
      Write-Host "  Restored MSYS2 configuration: $PacmanConfFile" -ForegroundColor Green
    }
    catch
    {
      Write-Warning "  Could not restore $PacmanConfFile : $($_.Exception.Message)"
    }
  }

  $MirrorDirPath = Join-Path $ToolchainRoot 'etc\pacman.d'
  if (Test-Path -LiteralPath $MirrorDirPath)
  {
    $MirrorBackups = @(Get-ChildItem -LiteralPath $MirrorDirPath -Filter 'mirrorlist.*.contest-bak' -File -ErrorAction SilentlyContinue)
    foreach ($MirrorBak in $MirrorBackups)
    {
      try
      {
        $OriginalMirrorPath = $MirrorBak.FullName.Substring(0, $MirrorBak.FullName.Length - '.contest-bak'.Length)
        Copy-Item -LiteralPath $MirrorBak.FullName -Destination $OriginalMirrorPath -Force
        Remove-Item -LiteralPath $MirrorBak.FullName -Force -ErrorAction SilentlyContinue
      }
      catch {}
    }
    if ($MirrorBackups.Count -gt 0)
    {
      Write-Host "  Restored $($MirrorBackups.Count) MSYS2 mirrorlist file(s)." -ForegroundColor Green
    }
  }

  $CaAnchorDir = Join-Path $ToolchainRoot 'etc\pki\ca-trust\source\anchors'
  $RemovedAnyCa = $false
  if (Test-Path -LiteralPath $CaAnchorDir)
  {
    $InjectedPemBundle = Join-Path $CaAnchorDir 'contestsetup-windows-roots.pem'
    if (Test-Path -LiteralPath $InjectedPemBundle)
    {
      try
      {
        Remove-Item -LiteralPath $InjectedPemBundle -Force -ErrorAction SilentlyContinue
        $RemovedAnyCa = $true
      }
      catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($CustomCaFileName))
    {
      $CaLeaf = [IO.Path]::GetFileName($CustomCaFileName)
      if (-not [string]::IsNullOrWhiteSpace($CaLeaf))
      {
        $CaStem = [IO.Path]::GetFileNameWithoutExtension($CaLeaf)
        foreach ($CandidateLeaf in @($CaLeaf, "$CaStem.crt"))
        {
          $CustomAnchorFile = Join-Path $CaAnchorDir $CandidateLeaf
          if (Test-Path -LiteralPath $CustomAnchorFile)
          {
            try
            {
              Remove-Item -LiteralPath $CustomAnchorFile -Force -ErrorAction SilentlyContinue
              $RemovedAnyCa = $true
            }
            catch {}
          }
        }
      }
    }
  }

  if ($RemovedAnyCa)
  {
    $BashExecutable = Join-Path $ToolchainRoot 'usr\bin\bash.exe'
    if (Test-Path -LiteralPath $BashExecutable)
    {
      try
      {
        Start-Process -FilePath $BashExecutable -ArgumentList @('-lc', 'update-ca-trust') -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        Write-Host '  Refreshed MSYS2 CA trust store after removing contest certificates.' -ForegroundColor Green
      }
      catch {}
    }
  }
}

function Get-ExtendedBrowserPolicySpecifications
{
  return @(
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BuiltInAIAPIsEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'GenAILocalFoundationalModelSettings'; Type = 'DWord'; Value = 1 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeEntraCopilotPageContext'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BuiltInAIAPIsEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'BraveAIChatEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' }
  )
}

function Restore-BrowserPoliciesFallback
{
  param([Parameter(Mandatory = $true)] [string]$ContestRoot)

  $Specs = @(
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'CopilotPageContext'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Enabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Locked'; Type = 'DWord'; Value = 1 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'DWord'; Value = 1 }
  )
  $AllSpecs = @($Specs + (Get-ExtendedBrowserPolicySpecifications))

  $PolicyBakPath = Join-Path (Join-Path $ContestRoot 'ai-block') 'browser-policies.bak.json'
  if (Test-Path -LiteralPath $PolicyBakPath)
  {
    try
    {
      $RawPolicyJson = Read-TextUtf8 -Path $PolicyBakPath
      $PolicyEntries = @(ConvertFrom-JsonArray -Json $RawPolicyJson)
      $KeysToPrune = New-Object System.Collections.Generic.List[string]
      foreach ($Entry in $PolicyEntries)
      {
        if ($null -eq $Entry) { continue }
        $KeyPath = Get-ObjectPropertyValue -Object $Entry -Name 'KeyPath'
        $ValName = Get-ObjectPropertyValue -Object $Entry -Name 'ValueName'
        if ([string]::IsNullOrWhiteSpace($KeyPath) -or [string]::IsNullOrWhiteSpace($ValName)) { continue }
        $ValType = Get-ObjectPropertyValue -Object $Entry -Name 'ValueType'
        if ([string]::IsNullOrWhiteSpace($ValType)) { $ValType = 'String' }
        $ValExisted = ($null -ne $Entry.PSObject.Properties['ValueExisted']) -and ([bool]$Entry.ValueExisted)
        $KeyExisted = ($null -ne $Entry.PSObject.Properties['KeyExisted']) -and ([bool]$Entry.KeyExisted)

        if ($ValExisted)
        {
          if (-not (Test-Path -LiteralPath $KeyPath))
          {
            New-Item -Path $KeyPath -Force -ErrorAction SilentlyContinue | Out-Null
          }
          $PriorVal = if ($null -ne $Entry.PSObject.Properties['PriorValue']) { $Entry.PriorValue } else { '' }
          New-ItemProperty -LiteralPath $KeyPath -Name $ValName -Value $PriorVal -PropertyType $ValType -Force -ErrorAction SilentlyContinue | Out-Null
        }
        elseif (Test-Path -LiteralPath $KeyPath)
        {
          Remove-ItemProperty -LiteralPath $KeyPath -Name $ValName -Force -ErrorAction SilentlyContinue
        }

        if (-not $KeyExisted -and -not $KeysToPrune.Contains($KeyPath))
        {
          $KeysToPrune.Add($KeyPath) | Out-Null
        }
      }

      foreach ($PruneKey in $KeysToPrune)
      {
        try
        {
          if (Test-Path -LiteralPath $PruneKey)
          {
            $KeyObj = Get-Item -LiteralPath $PruneKey -ErrorAction SilentlyContinue
            if ($null -ne $KeyObj -and $KeyObj.ValueCount -eq 0 -and $KeyObj.SubKeyCount -eq 0)
            {
              Remove-Item -LiteralPath $PruneKey -Force -ErrorAction SilentlyContinue
            }
          }
        }
        catch {}
      }

      Remove-Item -LiteralPath $PolicyBakPath -Force -ErrorAction SilentlyContinue
      Write-Host '  Verified Browser DoH and Copilot policy restoration from backup.' -ForegroundColor Green
      return
    }
    catch {}
  }

  foreach ($Spec in $AllSpecs)
  {
    try
    {
      if (Test-Path -LiteralPath $Spec.KeyPath)
      {
        $ItemProps = Get-ItemProperty -LiteralPath $Spec.KeyPath -ErrorAction SilentlyContinue
        if ($null -ne $ItemProps -and $null -ne $ItemProps.PSObject.Properties[$Spec.Name])
        {
          $CurrentVal = $ItemProps.PSObject.Properties[$Spec.Name].Value
          if ([string]$CurrentVal -eq [string]$Spec.Value)
          {
            Remove-ItemProperty -LiteralPath $Spec.KeyPath -Name $Spec.Name -Force -ErrorAction SilentlyContinue
          }
        }
        $RegItem = Get-Item -LiteralPath $Spec.KeyPath -ErrorAction SilentlyContinue
        if ($null -ne $RegItem -and $RegItem.ValueCount -eq 0 -and $RegItem.SubKeyCount -eq 0)
        {
          Remove-Item -LiteralPath $Spec.KeyPath -Force -ErrorAction SilentlyContinue
        }
      }
    }
    catch {}
  }
}

function Write-HostsFileDirectRetry
{
  param(
    [Parameter(Mandatory = $true)] [string]$HostsFilePath,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content,
    [int]$MaxAttempts = 5
  )
  $Enc = New-Object System.Text.UTF8Encoding($false)
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      if (Test-Path -LiteralPath $HostsFilePath)
      {
        $FileItem = Get-Item -LiteralPath $HostsFilePath -Force -ErrorAction SilentlyContinue
        if ($FileItem -and ($FileItem.Attributes -band [IO.FileAttributes]::ReadOnly))
        {
          $FileItem.Attributes = $FileItem.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
      }
      [System.IO.File]::WriteAllText($HostsFilePath, $Content, $Enc)
      return $true
    }
    catch
    {
      if ($Attempt -lt $MaxAttempts)
      {
        Start-Sleep -Milliseconds (200 * $Attempt)
      }
    }
  }
  return $false
}

function Restore-VSCodeProductJsonWhenKept
{
  param([Parameter(Mandatory = $true)] [string]$ContestRoot)

  $VSCodeDir = Join-Path $ContestRoot 'vscode'
  if (-not (Test-Path -LiteralPath $VSCodeDir)) { return }

  $CandidateProductPaths = New-Object System.Collections.Generic.List[string]
  $CandidateProductPaths.Add((Join-Path $VSCodeDir 'resources\app\product.json')) | Out-Null

  $CodeCmdFile = Join-Path $VSCodeDir 'bin\code.cmd'
  if (Test-Path -LiteralPath $CodeCmdFile)
  {
    try
    {
      $CmdText = Read-TextUtf8 -Path $CodeCmdFile
      $CliMatch = [regex]::Match($CmdText, '(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js')
      if ($CliMatch.Success)
      {
        $RefSubDir = $CliMatch.Groups[1].Value
        $CandidateProductPaths.Add((Join-Path (Join-Path $VSCodeDir $RefSubDir) 'resources\app\product.json')) | Out-Null
      }
    }
    catch {}
  }

  $ExcludedNames = @('data', 'bin', 'tools', 'policies', 'appx')
  foreach ($ChildDir in @(Get-ChildItem -LiteralPath $VSCodeDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending))
  {
    if ($ExcludedNames -contains $ChildDir.Name.ToLowerInvariant()) { continue }
    $CandidateProductPaths.Add((Join-Path $ChildDir.FullName 'resources\app\product.json')) | Out-Null
  }
  $CandidateProductPaths.Add((Join-Path $VSCodeDir 'product.json')) | Out-Null

  foreach ($ProdJsonPath in @($CandidateProductPaths.ToArray() | Select-Object -Unique))
  {
    $OrigJsonPath = "$ProdJsonPath.contest-orig"
    $AltBackupJsonPath = "$ProdJsonPath.contest-backup"
    $BackupToRestore = if (Test-Path -LiteralPath $OrigJsonPath) {
      $OrigJsonPath
    } elseif (Test-Path -LiteralPath $AltBackupJsonPath) {
      $AltBackupJsonPath
    } else {
      ''
    }
    if ([string]::IsNullOrWhiteSpace($BackupToRestore)) { continue }

    try
    {
      Copy-Item -LiteralPath $BackupToRestore -Destination $ProdJsonPath -Force
      if (Test-Path -LiteralPath $OrigJsonPath)
      {
        Remove-Item -LiteralPath $OrigJsonPath -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $AltBackupJsonPath)
      {
        Remove-Item -LiteralPath $AltBackupJsonPath -Force -ErrorAction SilentlyContinue
      }
      Write-Host "  Restored VS Code Marketplace configuration from backup: $ProdJsonPath" -ForegroundColor Green
    }
    catch
    {
      Write-Warning "  Could not restore VS Code product.json ($($_.Exception.Message))."
    }
  }
}

function Resolve-WorkspaceBackupBaseDir
{
  param([AllowNull()] [string]$StudentProfilePath = '')

  $Candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($StudentProfilePath) -and (Test-Path -LiteralPath $StudentProfilePath))
  {
    $Candidates.Add((Join-Path (Join-Path $StudentProfilePath 'AppData\Local') 'ContestSetup-Backups')) | Out-Null
    $Candidates.Add((Join-Path $StudentProfilePath 'AppData\Local\Temp')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA))
  {
    $CurSidCheck = try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
    if ($CurSidCheck -ne 'S-1-5-18')
    {
      $Candidates.Add((Join-Path $env:LOCALAPPDATA 'ContestSetup-Backups')) | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramData))
  {
    $Candidates.Add((Join-Path $env:ProgramData 'ContestSetup-Backups')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:TEMP))
  {
    $Candidates.Add($env:TEMP) | Out-Null
  }

  foreach ($BaseCandidate in $Candidates)
  {
    if ([string]::IsNullOrWhiteSpace($BaseCandidate)) { continue }
    if (Test-PathInside -ChildPath $BaseCandidate -ParentPath $Root) { continue }
    try
    {
      New-Item -ItemType Directory -Force -Path $BaseCandidate -ErrorAction Stop | Out-Null
      return $BaseCandidate
    }
    catch {}
  }
  return $env:TEMP
}

function Backup-ContestWorkspaceSources
{
  param(
    [Parameter(Mandatory = $true)] [string]$ContestRoot,
    [AllowNull()] [string]$StudentProfilePath = ''
  )

  $WorkspaceDir = Join-Path $ContestRoot 'contest'
  if (-not (Test-Path -LiteralPath $WorkspaceDir)) { return '' }

  $AllowedExts = @('.cpp', '.cc', '.cxx', '.c', '.h', '.hpp', '.py', '.java', '.txt', '.md')
  $MaxBytes = 5 * 1024 * 1024
  $DotVscodeDir = Join-Path $WorkspaceDir '.vscode'

  $CandidateFiles = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $Ext = [IO.Path]::GetExtension($_.Name).ToLowerInvariant()
    ($AllowedExts -contains $Ext) -and
    ($_.Length -gt 0) -and
    ($_.Length -le $MaxBytes) -and
    (-not (Test-PathInside -ChildPath $_.FullName -ParentPath $DotVscodeDir))
  })

  if ($CandidateFiles.Count -eq 0) { return '' }

  $Stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
  $BackupParentDir = Resolve-WorkspaceBackupBaseDir -StudentProfilePath $StudentProfilePath
  $BackupDestRoot = Join-Path $BackupParentDir "ContestSetup-Workspace-Backup-$Stamp"
  New-Item -ItemType Directory -Force -Path $BackupDestRoot | Out-Null

  $CopiedCount = 0
  $NormWorkspace = Get-NormalizedFullPath -Path $WorkspaceDir
  foreach ($SrcFile in $CandidateFiles)
  {
    try
    {
      $FullSrc = Get-NormalizedFullPath -Path $SrcFile.FullName
      $RelSubPath = $FullSrc.Substring($NormWorkspace.Length).TrimStart('\', '/')
      $DestFile = Join-Path $BackupDestRoot $RelSubPath
      $DestParent = Split-Path -Path $DestFile -Parent
      if (-not [string]::IsNullOrWhiteSpace($DestParent))
      {
        New-Item -ItemType Directory -Force -Path $DestParent | Out-Null
      }
      Copy-Item -LiteralPath $SrcFile.FullName -Destination $DestFile -Force
      $CopiedCount++
    }
    catch {}
  }

  if ($CopiedCount -gt 0)
  {
    Write-Host "  Backed up $CopiedCount student workspace file(s) to: $BackupDestRoot" -ForegroundColor Green
    return $BackupDestRoot
  }
  return ''
}

# Critical Safety Check: Prevent deletion of system drives or critical folders
$Root = Assert-SafeRemovalPath -Path $Root -Name 'Root'

$ContestVSCodeRoot = Join-Path $Root 'vscode-contest'
$ManifestPath = Join-Path $ContestVSCodeRoot 'shortcut-manifest.json'
$StateManifestPath = Join-Path (Join-Path $Root 'state') 'install-manifest.json'
$ProgressActivity = 'Contest Environment Restore & Cleanup (v2.0)'

# Inspect install-manifest.json early to recover MsysRoot, TargetUserSid, TargetUserProfile, CustomCaFileName, and PythonInstalledByContestSetup
$PythonInstalledByContestSetup = $true
$RecordedCustomCaFileName = ''
if (Test-Path -LiteralPath $StateManifestPath)
{
  try
  {
    $StateRaw = Read-TextUtf8 -Path $StateManifestPath
    $StateObj = ConvertFrom-JsonSafe -Json $StateRaw
    if ($null -ne $StateObj)
    {
      if ($null -ne $StateObj.PSObject.Properties['PythonInstalledByContestSetup'])
      {
        $PythonInstalledByContestSetup = [bool]$StateObj.PythonInstalledByContestSetup
      }
      $ManifestMsys = Get-ObjectPropertyValue -Object $StateObj -Name 'MsysRoot'
      $IsMsysBound = ($null -ne $BoundParamMap) -and $BoundParamMap.ContainsKey('MsysRoot')
      if ((-not $IsMsysBound) -and [string]::IsNullOrWhiteSpace($env:CONTEST_MSYS_ROOT) -and (-not [string]::IsNullOrWhiteSpace($ManifestMsys)))
      {
        $MsysRoot = $ManifestMsys
      }
      if ([string]::IsNullOrWhiteSpace($TargetUserSid))
      {
        $ManifestSid = Get-ObjectPropertyValue -Object $StateObj -Name 'TargetUserSid'
        if (-not [string]::IsNullOrWhiteSpace($ManifestSid) -and $ManifestSid -ne 'S-1-5-18')
        {
          $TargetUserSid = $ManifestSid
        }
      }
      if ([string]::IsNullOrWhiteSpace($TargetUserProfile))
      {
        $ManifestProf = Get-ObjectPropertyValue -Object $StateObj -Name 'TargetUserProfile'
        if (-not [string]::IsNullOrWhiteSpace($ManifestProf))
        {
          $TargetUserProfile = $ManifestProf
        }
      }
      $RecordedCustomCaFileName = Get-ObjectPropertyValue -Object $StateObj -Name 'CustomCaFileName'
      if ([string]::IsNullOrWhiteSpace($RecordedCustomCaFileName))
      {
        $RecordedCustomCaFileName = Get-ObjectPropertyValue -Object $StateObj -Name 'Msys2CaCertificatePath'
      }
    }
  }
  catch {}
}

if (-not [string]::IsNullOrWhiteSpace($MsysRoot))
{
  try { $MsysRoot = Get-NormalizedFullPath -Path $MsysRoot } catch {}
}

# Infer student profile from shortcut-manifest.json if running as SYSTEM without recorded TargetUserProfile
if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -and (Test-Path -LiteralPath $ManifestPath))
{
  try
  {
    $ShortcutItemsPreview = @(ConvertFrom-JsonArray -Json (Read-TextUtf8 -Path $ManifestPath))
    foreach ($EntryPreview in $ShortcutItemsPreview)
    {
      $ScPath = Get-ObjectPropertyValue -Object $EntryPreview -Name 'ShortcutPath'
      if ($ScPath -match '^([A-Za-z]:\\Users\\[^\\]+)\\' -and $matches[1] -notmatch '\\Public$')
      {
        $TargetUserProfile = $matches[1]
        break
      }
    }
  }
  catch {}
}

$ResolvedStudent = Resolve-TargetStudentIdentity -CandidateSid $TargetUserSid -CandidateProfile $TargetUserProfile
$TargetUserSid = $ResolvedStudent.Sid
$TargetUserProfile = $ResolvedStudent.ProfilePath

$PreserveDirs = @()
if ($KeepDownloads) { $PreserveDirs += 'downloads' }
if ($KeepLogs) { $PreserveDirs += 'logs' }
if ($KeepWorkspace) { $PreserveDirs += 'contest' }
if ($KeepVSCode) { $PreserveDirs += @('vscode', 'vscode-contest') }

# Self-relocate to $env:TEMP\contest-restore-runner.ps1 when running from inside $Root so PowerShell holds zero handles inside $Root
if ($PSCommandPath -and (-not $ReinvokedFromTemp) -and ($PreserveDirs.Count -eq 0) -and (Test-PathInside -ChildPath $PSCommandPath -ParentPath $Root))
{
  try
  {
    $TempRunner = Join-Path $env:TEMP 'contest-restore-runner.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $TempRunner -Force -ErrorAction Stop
    Set-Location -LiteralPath $env:TEMP
    $RelocArgs = Build-RestoreForwardArgs -ScriptFile $TempRunner -IncludeReinvokedFromTemp
    $RelocArgString = ($RelocArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $RelocProc = Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $RelocArgString -Wait -PassThru -NoNewWindow -ErrorAction Stop
    $RelocExit = if ($null -ne $RelocProc) { [int]$RelocProc.ExitCode } else { 0 }
    exit $RelocExit
  }
  catch
  {
    Write-Warning "Self-relocation to TEMP could not complete ($($_.Exception.Message)); continuing cleanup in-process."
  }
}

# Late-Boot Shutdown Guard: never shut down a student PC on next-morning boot when -StartWhenAvailable fires >25 minutes late
if ($Shutdown -and (-not [string]::IsNullOrWhiteSpace($ScheduledRestoreAt)))
{
  try
  {
    $ScheduledTargetLocal = ConvertTo-LocalScheduleTime -Text $ScheduledRestoreAt
    $LateMinutes = ((Get-Date) - $ScheduledTargetLocal).TotalMinutes
    if ($LateMinutes -gt 25)
    {
      Write-Warning ("Scheduled restore is executing {0:N1} minutes after scheduled target ({1}). Suppressing -Shutdown to prevent unexpected forced shutdown after late boot." -f $LateMinutes, $ScheduledRestoreAt)
      $Shutdown = [switch]$false
    }
  }
  catch
  {
    Write-Warning "Could not parse -ScheduledRestoreAt '$ScheduledRestoreAt' ($($_.Exception.Message)); proceeding with requested flags."
  }
}

# Auto-discover PythonDir if not provided
if (-not $PythonDir)
{
  $PyDirs = @(Get-ChildItem -Path $Root -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue)
  if ($PyDirs.Count -gt 0)
  {
    $PythonDir = $PyDirs[0].FullName
    if ($PyDirs[0].Name -match 'Python(\d)(\d+)')
    {
      $PythonVersion = "$($matches[1]).$($matches[2])"
    }
  }
  else
  {
    $PythonDir = Join-Path $Root 'Python310'
  }
}

# Acquire cross-process mutex so concurrent Scheduled Tasks (19:00 vs 20:30) serialize cleanly without self-contending with parent orchestrator
$RestoreMutex = $null
$RestoreMutexAcquired = $false
$MutexHeld = $false
$PreviousMutexOwnerPid = $env:CONTEST_MUTEX_OWNER_PID

try
{
  try
  {
    $RestoreMutex = New-Object System.Threading.Mutex($false, 'Global\ContestSetupEnvironmentMutex')
    $OwnerPid = 0
    $ParentHoldsMutex = $false
    if ((-not [string]::IsNullOrWhiteSpace($env:CONTEST_MUTEX_OWNER_PID)) -and [int]::TryParse($env:CONTEST_MUTEX_OWNER_PID.Trim(), [ref]$OwnerPid))
    {
      if ($OwnerPid -gt 0 -and $OwnerPid -ne $PID -and ($null -ne (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)))
      {
        $ParentHoldsMutex = $true
      }
    }

    if ($ParentHoldsMutex)
    {
      Write-Host "  Parent ContestSetup process (PID $OwnerPid) already holds Global\ContestSetupEnvironmentMutex; skipping mutex wait." -ForegroundColor Gray
      $RestoreMutexAcquired = $false
      $MutexHeld = $false
      try { $RestoreMutex.Dispose() } catch {}
      $RestoreMutex = $null
    }
    else
    {
      try
      {
        $RestoreMutexAcquired = $RestoreMutex.WaitOne([TimeSpan]::FromSeconds(60))
      }
      catch [System.Threading.AbandonedMutexException]
      {
        $RestoreMutexAcquired = $true
      }
      if ($RestoreMutexAcquired)
      {
        $MutexHeld = $true
        $env:CONTEST_MUTEX_OWNER_PID = [string]$PID
      }
      else
      {
        $MutexHeld = $false
        try { $RestoreMutex.Dispose() } catch {}
        $RestoreMutex = $null
      }
    }
  }
  catch
  {
    if ($MutexHeld)
    {
      $env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid
      $MutexHeld = $false
    }
    if ($null -ne $RestoreMutex)
    {
      try { $RestoreMutex.Dispose() } catch {}
    }
    $RestoreMutex = $null
    $RestoreMutexAcquired = $false
  }

  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host '  Contest Environment Restore & Cleanup (v2.0)' -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host ''

  # -- Step 0/6: Unregister Scheduled Tasks --
  Write-Host '[0/6] Unregistering Contest Scheduled Tasks...' -ForegroundColor Yellow
  foreach ($ScheduledTaskName in @(
    'ContestSetupRestoreAndCleanup',
    'ContestSetupRestoreAiHostsBlock',
    'ContestSetupExamStartEnforcement'
  )) {
    try
    {
      $ExistingTask = Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue
      if ($ExistingTask)
      {
        Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Unregistered scheduled task: $ScheduledTaskName" -ForegroundColor Green
      }
    }
    catch {}
    try { schtasks.exe /Delete /TN $ScheduledTaskName /F 2>$null | Out-Null } catch {}
  }

  # -- Step 1/6: Restore VS Code Shortcuts --
  Write-Progress -Activity $ProgressActivity -Status '[1/6] Restoring VS Code Shortcuts...' -PercentComplete 10
  Write-Host '[1/6] Restoring VS Code Shortcuts...' -ForegroundColor Yellow
  if (-not $KeepVSCode)
  {
    if (Test-Path -LiteralPath $ManifestPath)
    {
      try
      {
        $RawManifestJson = Read-TextUtf8 -Path $ManifestPath
        $Manifest = @(ConvertFrom-JsonArray -Json $RawManifestJson)
        foreach ($Item in $Manifest)
        {
          if ($null -eq $Item) { continue }
          $ShortcutPath = Get-ObjectPropertyValue -Object $Item -Name 'ShortcutPath'
          $BackupPath = Get-ObjectPropertyValue -Object $Item -Name 'BackupPath'
          $Existed = ($null -ne $Item.PSObject.Properties['Existed']) -and ([bool]$Item.Existed)
          if ([string]::IsNullOrWhiteSpace($ShortcutPath)) { continue }
          try
          {
            if ($Existed -and (-not [string]::IsNullOrWhiteSpace($BackupPath)) -and (Test-Path -LiteralPath $BackupPath))
            {
              New-Item -ItemType Directory -Force -Path (Split-Path -Path $ShortcutPath -Parent) | Out-Null
              Copy-Item -LiteralPath $BackupPath -Destination $ShortcutPath -Force
              Write-Host "  Restored: $ShortcutPath" -ForegroundColor Green
            }
            elseif (Test-Path -LiteralPath $ShortcutPath)
            {
              Remove-Item -LiteralPath $ShortcutPath -Force
              Write-Host "  Removed: $ShortcutPath" -ForegroundColor Green
            }
          }
          catch
          {
            Write-Warning "  Failed: $ShortcutPath ($($_.Exception.Message))"
          }
        }
      }
      catch
      {
        Write-Warning "  Could not parse shortcut manifest: $($_.Exception.Message)"
      }
    }
    else
    {
      Write-Host '  No shortcut manifest found. Skipping.' -ForegroundColor Gray
    }
  }
  else
  {
    Write-Host '  Preserving contest VS Code shortcuts (-KeepVSCode).' -ForegroundColor Cyan
    Restore-VSCodeProductJsonWhenKept -ContestRoot $Root
  }

  # -- Step 2/6: Restore PATH Environment Variable & MSYS2 Config --
  Write-Progress -Activity $ProgressActivity -Status '[2/6] Restoring PATH & MSYS2 Config...' -PercentComplete 25
  Write-Host '[2/6] Restoring PATH Environment Variable & MSYS2 Config...' -ForegroundColor Yellow
  $BackupDir = Join-Path $Root 'backup'
  # Sort ascending by CreationTime so the oldest original pre-install snapshot is selected first
  $PathSnapshots = @(Get-ChildItem -Path $BackupDir -Filter 'path-*' -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime)
  $UserSnapshotRestored = $false
  $MachineSnapshotRestored = $false

  if ($PathSnapshots.Count -gt 0)
  {
    $OriginalSnapshotDir = $PathSnapshots[0].FullName
    $SnapshotFile = Join-Path $OriginalSnapshotDir 'path-environment-before-cleanup.txt'
    if (Test-Path -LiteralPath $SnapshotFile)
    {
      [string[]]$Lines = @(Read-LinesUtf8 -Path $SnapshotFile)
      $SidHeaderIdx = [Array]::IndexOf($Lines, 'TargetUserSid:')
      if ([string]::IsNullOrWhiteSpace($TargetUserSid) -and $SidHeaderIdx -ge 0 -and ($SidHeaderIdx + 1) -lt $Lines.Count)
      {
        $SnapSid = $Lines[$SidHeaderIdx + 1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($SnapSid) -and $SnapSid -ne 'S-1-5-18')
        {
          $TargetUserSid = $SnapSid
          if ([string]::IsNullOrWhiteSpace($TargetUserProfile))
          {
            $TargetUserProfile = Resolve-ProfilePathFromSid -Sid $TargetUserSid
          }
        }
      }

      $UserIdx = [Array]::IndexOf($Lines, 'User PATH:')
      if ($UserIdx -ge 0 -and ($UserIdx + 1) -lt $Lines.Count)
      {
        $UserPath = $Lines[$UserIdx + 1]
        if (Set-RegistryScopePathValue -Scope 'User' -PathValue $UserPath -UserSid $TargetUserSid -UserProfile $TargetUserProfile)
        {
          $UserSnapshotRestored = $true
          Write-Host '  User PATH restored from original pre-install snapshot (REG_EXPAND_SZ preserved).' -ForegroundColor Green
        }
      }

      $MachineIdx = [Array]::IndexOf($Lines, 'Machine PATH:')
      if ($MachineIdx -ge 0 -and ($MachineIdx + 1) -lt $Lines.Count)
      {
        $MachinePath = $Lines[$MachineIdx + 1]
        if (-not [string]::IsNullOrWhiteSpace($MachinePath))
        {
          try
          {
            if (Set-RegistryScopePathValue -Scope 'Machine' -PathValue $MachinePath)
            {
              $MachineSnapshotRestored = $true
              Write-Host '  Machine PATH restored from original pre-install snapshot (REG_EXPAND_SZ preserved).' -ForegroundColor Green
            }
          }
          catch {}
        }
      }
    }
  }
  else
  {
    Write-Host '  No PATH backup snapshot found; applying surgical PATH cleanup.' -ForegroundColor Gray
  }

  # Strip residual $Root entries unconditionally; only strip $MsysRoot when no pre-install snapshot was restored
  Remove-ContestEntriesFromPathScope -Scope 'User' -ContestRoot $Root -MsysRootPath $MsysRoot -IncludeMsys:(-not $UserSnapshotRestored) -UserSid $TargetUserSid -UserProfile $TargetUserProfile
  Remove-ContestEntriesFromPathScope -Scope 'Machine' -ContestRoot $Root -MsysRootPath $MsysRoot -IncludeMsys:(-not $MachineSnapshotRestored)
  Remove-ContestEntriesFromPathScope -Scope 'Process' -ContestRoot $Root -MsysRootPath $MsysRoot -IncludeMsys:(-not $UserSnapshotRestored)

  # Restore MSYS2 pacman.conf, mirrorlist.*, and CA trust anchors while preserving the MSYS2 installation
  Restore-Msys2ContestConfiguration -ToolchainRoot $MsysRoot -CustomCaFileName $RecordedCustomCaFileName

  # -- Step 3/6: Restore AI Hosts Block & Browser Policies --
  Write-Progress -Activity $ProgressActivity -Status '[3/6] Restoring AI Hosts & Browser Policies...' -PercentComplete 40
  Write-Host '[3/6] Restoring AI Hosts Block & Browser Policies...' -ForegroundColor Yellow
  $AiScriptCandidates = @(
    (Join-Path $Root 'ai-hosts-block.ps1'),
    (Join-Path (Join-Path $Root 'ai-block') 'ai-hosts-block.ps1'),
    (Join-Path (Join-Path $Root 'ai-hosts-block') 'ai-hosts-block.ps1'),
    (Join-Path (Join-Path $Root 'scripts') 'ai-hosts-block.ps1')
  )
  if ($PSScriptRoot) { $AiScriptCandidates += (Join-Path $PSScriptRoot 'ai-hosts-block.ps1') }
  $AiScript = $AiScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

  if ($AiScript)
  {
    try
    {
      $PsExe = Get-PreferredPowerShell
      $AiRestoreArgs = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AiScript, '-Restore', '-Root', $Root) | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
      $Proc = Start-Process -FilePath $PsExe -ArgumentList $AiRestoreArgs -Wait -PassThru -WindowStyle Hidden
      if ($Proc.ExitCode -eq 0)
      {
        Write-Host '  AI hosts block removed via ai-hosts-block.ps1.' -ForegroundColor Green
      }
      else
      {
        Write-Warning "  ai-hosts-block.ps1 -Restore returned exit code $($Proc.ExitCode); verifying direct fallback."
      }
    }
    catch
    {
      Write-Warning "  ai-hosts-block.ps1 -Restore failed ($($_.Exception.Message)); applying direct fallback."
    }
  }

  # Unconditionally verify hosts file has no lingering ContestSetup blocklist markers
  $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (Test-Path -LiteralPath $HostsPath)
  {
    try
    {
      $BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
      $EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
      $RawHosts = Read-TextUtf8 -Path $HostsPath
      if (($RawHosts -like "*$BeginMarker*") -or ($RawHosts -like "*$EndMarker*"))
      {
        $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
        $Stripped = [regex]::Replace($RawHosts, $Pattern, "`r`n")
        if ($Stripped -like "*$BeginMarker*")
        {
          $OrphanPattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + ".*\z"
          $Stripped = [regex]::Replace($Stripped, $OrphanPattern, "`r`n")
        }
        $Stripped = $Stripped.TrimEnd()
        $CleanedHosts = if ([string]::IsNullOrWhiteSpace($Stripped)) { "`r`n" } else { $Stripped + "`r`n" }
        if (Write-HostsFileDirectRetry -HostsFilePath $HostsPath -Content $CleanedHosts -MaxAttempts 5)
        {
          Write-Host '  AI hosts block removed directly from hosts file.' -ForegroundColor Green
        }
      }
    }
    catch
    {
      Write-Warning "  Direct hosts verification warning: $($_.Exception.Message)"
    }
  }

  Restore-BrowserPoliciesFallback -ContestRoot $Root
  try { if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) { Clear-DnsClientCache -ErrorAction SilentlyContinue } } catch {}
  try { ipconfig.exe /flushdns | Out-Null } catch {}

  # -- Step 4/6: Uninstall Python (Only if installed inside $Root) --
  Write-Progress -Activity $ProgressActivity -Status '[4/6] Uninstalling Contest Python...' -PercentComplete 55
  Write-Host '[4/6] Uninstalling Contest Python...' -ForegroundColor Yellow

  Stop-ProcessesUnderPath -Path $Root -ProcessNames @('python', 'python3')

  $PythonUninstalled = $false

  # Only touch MSI/Registry uninstallers if ContestSetup installed Python AND a sub-package InstallLocation is verified inside $Root
  if ($PythonInstalledByContestSetup)
  {
    $UninstallKeys = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetUserSid) -and $TargetUserSid -ne 'S-1-5-18')
    {
      $SidUninstallKey = "Registry::HKEY_USERS\$TargetUserSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
      if (Test-Path -Path "Registry::HKEY_USERS\$TargetUserSid") { $UninstallKeys += $SidUninstallKey }
    }

    $AllPythonEntries = New-Object System.Collections.Generic.List[object]
    $MatchingEntries = New-Object System.Collections.Generic.List[object]
    foreach ($KeyPath in $UninstallKeys)
    {
      $Scanned = @(Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue)
      foreach ($Item in $Scanned)
      {
        $DisplayName = Get-ObjectPropertyValue -Object $Item -Name 'DisplayName'
        if ([string]::IsNullOrWhiteSpace($DisplayName)) { continue }
        if (-not ($DisplayName -like "Python $PythonVersion*" -or $DisplayName -like 'Python 3.10*')) { continue }
        $AllPythonEntries.Add($Item) | Out-Null

        $InstallLocation = Get-ObjectPropertyValue -Object $Item -Name 'InstallLocation'
        if ((-not [string]::IsNullOrWhiteSpace($InstallLocation)) -and (Test-PathInside -ChildPath $InstallLocation -ParentPath $Root))
        {
          $MatchingEntries.Add($Item) | Out-Null
        }
      }
    }

    # If at least one sub-MSI verified InstallLocation inside $Root, also include WiX Burn bundle entries (where InstallLocation is empty)
    if ($MatchingEntries.Count -gt 0)
    {
      foreach ($Cand in $AllPythonEntries)
      {
        $CandLoc = Get-ObjectPropertyValue -Object $Cand -Name 'InstallLocation'
        $QuietUninst = Get-ObjectPropertyValue -Object $Cand -Name 'QuietUninstallString'
        $StdUninst = Get-ObjectPropertyValue -Object $Cand -Name 'UninstallString'
        if ([string]::IsNullOrWhiteSpace($CandLoc) -and (($QuietUninst -match 'Package Cache') -or ($StdUninst -match 'Package Cache')))
        {
          $MatchingEntries.Add($Cand) | Out-Null
        }
      }
    }

    # Run WiX Burn bundle uninstallers BEFORE individual MsiExec sub-packages
    $OrderedEntries = @($MatchingEntries | Sort-Object {
      $U = Get-ObjectPropertyValue -Object $_ -Name 'UninstallString'
      if ($U -match 'MsiExec') { 1 } else { 0 }
    })

    foreach ($Entry in $OrderedEntries)
    {
      $DisplayName = Get-ObjectPropertyValue -Object $Entry -Name 'DisplayName'
      $QuietUninstallString = Get-ObjectPropertyValue -Object $Entry -Name 'QuietUninstallString'
      $UninstallString = Get-ObjectPropertyValue -Object $Entry -Name 'UninstallString'
      if ($QuietUninstallString -or $UninstallString)
      {
        Write-Host "  Found contest Python uninstaller (inside $Root): $DisplayName" -ForegroundColor Cyan
        try
        {
          if ($UninstallString -match 'MsiExec' -and $UninstallString -match '(\{[0-9A-Fa-f-]+\})')
          {
            $ProductCode = $matches[1]
            Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $ProductCode /quiet /norestart" -Wait -PassThru -WindowStyle Hidden | Out-Null
          }
          else
          {
            $BurnCmd = if (-not [string]::IsNullOrWhiteSpace($QuietUninstallString)) {
              $QuietUninstallString
            } elseif ($UninstallString -notmatch '/quiet') {
              "$UninstallString /quiet"
            } else {
              $UninstallString
            }
            Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c "' + $BurnCmd + '"') -Wait -PassThru -WindowStyle Hidden | Out-Null
          }
          $PythonUninstalled = $true
        }
        catch
        {
          Write-Warning "  Registry uninstall failed: $($_.Exception.Message)"
        }
      }
    }
  }

  # Remove the managed $PythonDir directory inside $Root
  if (Test-Path -LiteralPath $PythonDir)
  {
    if (Test-PathInside -ChildPath $PythonDir -ParentPath $Root)
    {
      Write-Host "  Removing contest Python directory: $PythonDir" -ForegroundColor Cyan
      try
      {
        Remove-Item -LiteralPath $PythonDir -Recurse -Force -ErrorAction Stop
        $PythonUninstalled = $true
        Write-Host '  Contest Python directory removed.' -ForegroundColor Green
      }
      catch
      {
        Write-Warning "  Directory removal deferred to root cleanup: $($_.Exception.Message)"
      }
    }
  }

  if ($PythonUninstalled)
  {
    Write-Host '  Contest Python cleaned up successfully (user system Python installations left untouched).' -ForegroundColor Green
  }
  else
  {
    Write-Host '  Contest Python was not found or already removed.' -ForegroundColor Gray
  }

  # -- Step 5/6: Backup Student Solutions, Stop Processes & Clean CPTools Folder --
  Write-Progress -Activity $ProgressActivity -Status '[5/6] Cleaning CPTools folder...' -PercentComplete 75
  Write-Host '[5/6] Backing up student workspace (if any), stopping processes & cleaning directory...' -ForegroundColor Yellow

  if ((-not $KeepWorkspace) -and (-not $PurgeWorkspace))
  {
    try { [void](Backup-ContestWorkspaceSources -ContestRoot $Root -StudentProfilePath $TargetUserProfile) } catch {}
  }

  $CleanupProcNames = if ($KeepVSCode) {
    @('python', 'python3', 'g++', 'gcc', 'gdb', 'bash', 'sh')
  } else {
    @('Code', 'Code - Insiders', 'node', 'python', 'python3', 'g++', 'gcc', 'gdb', 'bash', 'sh', 'cpptools', 'cpptools-srv', 'rg')
  }
  if (-not $KeepVSCode)
  {
    Stop-ProcessesUnderPath -Path $Root -ProcessNames $CleanupProcNames
    Start-Sleep -Seconds 2
  }
  else
  {
    foreach ($SubToolDir in @($PythonDir, (Join-Path $Root 'bin')))
    {
      if (-not [string]::IsNullOrWhiteSpace($SubToolDir) -and (Test-Path -LiteralPath $SubToolDir))
      {
        Stop-ProcessesUnderPath -Path $SubToolDir -ProcessNames $CleanupProcNames
      }
    }
  }
}
finally
{
  if ($MutexHeld)
  {
    $env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid
    $MutexHeld = $false
  }
  if ($null -ne $RestoreMutex)
  {
    if ($RestoreMutexAcquired)
    {
      try { $RestoreMutex.ReleaseMutex() } catch {}
    }
    try { $RestoreMutex.Dispose() } catch {}
  }
}

if ($PreserveDirs.Count -gt 0)
{
  Write-Host ("  Selective cleanup mode: preserving {0} inside {1}" -f ($PreserveDirs -join ', '), $Root) -ForegroundColor Cyan
  if (Test-Path -LiteralPath $Root)
  {
    Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object {
      $PreserveDirs -notcontains $_.Name
    } | ForEach-Object {
      try
      {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
      }
      catch
      {
        Write-Warning "  Could not remove $($_.FullName): $($_.Exception.Message)"
      }
    }
  }

  Write-Progress -Activity $ProgressActivity -Status '[6/6] Finalizing...' -PercentComplete 100
  Write-Progress -Activity $ProgressActivity -Completed
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host '  Selective contest environment rollback completed!' -ForegroundColor Green
  Write-Host '============================================================' -ForegroundColor Cyan
  return
}

$DirectRemoveOk = $false
if (Test-Path -LiteralPath $Root)
{
  try
  {
    Set-Location -LiteralPath $env:TEMP
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
    $DirectRemoveOk = (-not (Test-Path -LiteralPath $Root))
    if ($DirectRemoveOk)
    {
      Write-Host "  CPTools folder removed: $Root" -ForegroundColor Green
    }
  }
  catch
  {
    Write-Host '  Direct removal encountered a file lock. Scheduling UTF-8 deferred batch cleanup...' -ForegroundColor Yellow
  }
}
else
{
  $DirectRemoveOk = $true
}

# -- Step 6/6: Finalize & Optional Post-Cleanup Shutdown --
Write-Progress -Activity $ProgressActivity -Status '[6/6] Finalizing...' -PercentComplete 95
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  All contest environment cleanup completed!' -ForegroundColor Green
Write-Progress -Activity $ProgressActivity -Completed

if (-not $DirectRemoveOk -and (Test-Path -LiteralPath $Root))
{
  $TempBat = Join-Path $env:TEMP 'remove-cptools.cmd'
  $EscapedRootForCmd = $Root.Replace('%', '%%')
  $BatchLines = @(
    '@echo off',
    'chcp 65001 >nul',
    'cd /d "%TEMP%"',
    'ping 127.0.0.1 -n 4 >nul',
    ('rmdir /s /q "{0}"' -f $EscapedRootForCmd),
    ('if exist "{0}" (' -f $EscapedRootForCmd),
    '    ping 127.0.0.1 -n 6 >nul',
    ('    rmdir /s /q "{0}"' -f $EscapedRootForCmd),
    ')'
  )
  if ($Shutdown)
  {
    $BatchLines += 'shutdown.exe /s /f /t 15 /c "ContestSetup post-exam cleanup complete"'
  }
  $BatchLines += 'del "%~f0"'
  $BatContent = ($BatchLines -join "`r`n") + "`r`n"
  Write-TextUtf8NoBom -Path $TempBat -Content $BatContent
  Start-Process -FilePath 'cmd.exe' -ArgumentList "/d /c `"$TempBat`"" -WindowStyle Hidden
  if ($Shutdown)
  {
    Write-Host '  Deferred cleanup launched; system will shut down after CPTools removal completes.' -ForegroundColor Yellow
  }
  else
  {
    Write-Host '  Deferred cleanup launched. CPTools will be removed shortly.' -ForegroundColor Green
  }
  return
}

if ($Shutdown)
{
  Write-Host '  Computer will shut down in 30 seconds (run shutdown /a to cancel).' -ForegroundColor Red
  Write-Host '============================================================' -ForegroundColor Cyan
  $ShutdownLaunched = $false
  try
  {
    & shutdown.exe /s /f /t 30 /c "ContestSetup post-exam cleanup complete" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ShutdownLaunched = $true }
  }
  catch {}
  if (-not $ShutdownLaunched)
  {
    Start-Sleep -Seconds 30
    Stop-Computer -Force
  }
}
else
{
  Write-Host '  Shutdown was NOT requested. Exiting.' -ForegroundColor Yellow
}
