# common.ps1
# Common variables and helper functions for ContestSetup modules

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

try
{
  chcp.com 65001 | Out-Null
  [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = [Console]::OutputEncoding
}
catch {}

# Base Paths (Can be overridden by variables from caller)
if (-not $Root) { $Root = "$env:SystemDrive\CPTools" }
if (-not $MsysRoot) { $MsysRoot = "$env:SystemDrive\msys64" }
if (-not $PythonVersion) { $PythonVersion = '3.10.11' }

$ToolBin = Join-Path $Root 'bin'
$PathBin = Join-Path $Root 'path'
$DownloadDir = Join-Path $Root 'downloads'
$TestDir = Join-Path $Root 'tests'
$LogDir = Join-Path $Root 'logs'
$BackupDir = Join-Path $Root 'backup'
$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$TranscriptPath = Join-Path $LogDir "setup-transcript-$TimeStamp.txt"
$ErrorLogPath = Join-Path $LogDir "setup-error-$TimeStamp.txt"

$MsysBash = Join-Path $MsysRoot 'usr\bin\bash.exe'
$MsysCat = Join-Path $MsysRoot 'usr\bin\cat.exe'
$UcrtBin = Join-Path $MsysRoot 'ucrt64\bin'

$VersionParts = $PythonVersion -split '\.'
$PythonDir = Join-Path $Root ("Python{0}{1}" -f $VersionParts[0], $VersionParts[1])
$PythonExe = Join-Path $PythonDir 'python.exe'
$PythonInstallerName = "python-$PythonVersion-amd64.exe"
$PythonUrl = "https://www.python.org/ftp/python/$PythonVersion/$PythonInstallerName"
$PythonInstaller = Join-Path $DownloadDir $PythonInstallerName

$VSCodeInstallerUrl = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
$VSCodeInstallerPath = Join-Path $DownloadDir 'VSCodeSetup-x64.exe'

$Msys2InstallerUrl = 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe'
$Msys2InstallerPath = Join-Path $DownloadDir 'msys2-x86_64-latest.exe'

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

function Start-SetupLogging
{
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  try
  {
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
  if ($global:TranscriptStarted)
  {
    try { Stop-Transcript | Out-Null } catch {}
    $global:TranscriptStarted = $false
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
    [Parameter(Mandatory = $true)] [string]$Content
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
    [Parameter(Mandatory = $true)] [object]$InputObject,
    [int]$Depth = 30
  )
  $Json = $InputObject | ConvertTo-Json -Depth $Depth
  Write-TextUtf8NoBom -Path $Path -Content ($Json + [Environment]::NewLine)
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

  if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue) -and -not (Test-Path $FilePath))
  {
    throw "Native command not found: $FilePath"
  }
  if (-not $Quiet) { Write-Host ("{0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray }

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
          $Line = $_.ToString()
          $OutputList.Add($Line) | Out-Null
          Write-Host $Line
        }
      }
      $ExitCode = [int]$LASTEXITCODE
      $Output = $OutputList.ToArray()
    }
    else
    {
      $Output = & $FilePath @ArgumentList 2>&1
      $ExitCode = [int]$LASTEXITCODE
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

function Invoke-DownloadFile
{
  param([Parameter(Mandatory = $true)] [string]$Url, [Parameter(Mandatory = $true)] [string]$OutFile, [int]$MaxAttempts = 3)
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  $LastError = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      Write-Host "Downloading ($Attempt/$MaxAttempts): $Url"
      $Params = @{ Uri = $Url; OutFile = $OutFile; ErrorAction = 'Stop' }
      if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
      Invoke-WebRequest @Params
      if (-not (Test-Path $OutFile)) { throw "Download did not create file: $OutFile" }
      return
    }
    catch
    {
      $LastError = $_
      if ($Attempt -lt $MaxAttempts) { Write-Warning "Download failed. Retrying... $($_.Exception.Message)"; Start-Sleep -Seconds 2 }
    }
  }
  throw "Download failed after $MaxAttempts attempts: $Url - $($LastError.Exception.Message)"
}

function Assert-FileSha256
{
  param([Parameter(Mandatory = $true)] [string]$Path, [AllowEmptyString()] [string]$ExpectedSha256)
  if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return }
  $Actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
  if ($Actual -ine $ExpectedSha256) { throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $Actual" }
  Write-Host "SHA256 verified: $Path" -ForegroundColor Green
}

function Assert-AuthenticodeValid
{
  param([Parameter(Mandatory = $true)] [string]$Path, [string[]]$AllowedPublisherKeywords = @())
  if ($SkipSignatureCheck) { Write-Warning "Skipping Authenticode check by -SkipSignatureCheck: $Path"; return }
  $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($Extension -notin @('.exe', '.msi', '.msixbundle', '.appx', '.appxbundle')) { return }
  $Signature = Get-AuthenticodeSignature -FilePath $Path
  if ($Signature.Status -ne 'Valid') { throw "Invalid Authenticode signature: $Path ($($Signature.Status))" }
  if ($AllowedPublisherKeywords.Count -gt 0)
  {
    $Combined = "$($Signature.SignerCertificate.Subject) $($Signature.SignerCertificate.Issuer)"
    $Ok = $false
    foreach ($Keyword in $AllowedPublisherKeywords) { if ($Combined -like "*$Keyword*") { $Ok = $true; break } }
    if (-not $Ok) { throw "Unexpected signer for ${Path}: $($Signature.SignerCertificate.Subject)" }
  }
  Write-Host "Authenticode signature verified: $Path" -ForegroundColor Green
}

function Download-VerifiedFile
{
  param([string]$Url, [string]$OutFile, [string]$ExpectedSha256 = '', [string[]]$AllowedPublisherKeywords = @())
  Invoke-DownloadFile -Url $Url -OutFile $OutFile
  Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
  Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
}

function Normalize-PathForCompare
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Add-UserPathFront
{
  param([Parameter(Mandatory = $true)] [string]$PathToAdd)
  if (-not (Test-Path $PathToAdd)) { Write-Warning "PATH target not found: $PathToAdd"; return }
  $TargetNormalized = Normalize-PathForCompare $PathToAdd
  $Current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $Parts = @()
  if (-not [string]::IsNullOrWhiteSpace($Current))
  {
    $Parts = $Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Normalize-PathForCompare $_) -ne $TargetNormalized }
  }
  $NewPath = ($PathToAdd + ';' + ($Parts -join ';')).TrimEnd(';')
  [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
  $EnvParts = @()
  if (-not [string]::IsNullOrWhiteSpace($env:Path))
  {
    $EnvParts = $env:Path.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Normalize-PathForCompare $_) -ne $TargetNormalized }
  }
  $env:Path = ($PathToAdd + ';' + ($EnvParts -join ';')).TrimEnd(';')
  Write-Host "PATH added: $PathToAdd" -ForegroundColor Green
}

function Remove-PathEntriesMatching
{
  param([Parameter(Mandatory = $true)] [string]$Scope, [Parameter(Mandatory = $true)] [scriptblock]$ShouldRemove)
  $Current = [Environment]::GetEnvironmentVariable('Path', $Scope)
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
    [Environment]::SetEnvironmentVariable('Path', ($Kept.ToArray() -join ';'), $Scope)
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
  $VSCodeBinNorms = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')
  ) | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ }

  $ShouldRemove = {
    param($Original, $Normalized)
    return ($Normalized -eq $ToolBinNorm -or $Normalized -eq $PathBinNorm -or $Normalized -eq $PythonDirNorm -or $Normalized.StartsWith("$PythonDirNorm\") -or $Normalized -eq $MsysRootNorm -or $Normalized.StartsWith("$MsysRootNorm\") -or $Normalized -eq $RootNorm -or $VSCodeBinNorms -contains $Normalized)
  }.GetNewClosure()

  Remove-PathEntriesMatching -Scope 'User' -ShouldRemove $ShouldRemove
  Remove-PathEntriesMatching -Scope 'Process' -ShouldRemove $ShouldRemove
}

function Backup-PathEnvironment
{
  param([Parameter(Mandatory = $true)] [string]$BackupRoot)
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  $SnapshotPath = Join-Path $BackupRoot 'path-environment-before-cleanup.txt'
  $Lines = @('User PATH:', ([Environment]::GetEnvironmentVariable('Path', 'User')), '', 'Process PATH:', $env:Path)
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
  Write-Host "Backing up: $Path`nBackup to : $Destination"
  $Item = Get-Item -LiteralPath $Path -Force
  if ($Item.PSIsContainer)
  {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $RoboLogPath = Join-Path (Join-Path $LogDir 'robocopy') ("backup-{0}-{1}.log" -f $SafeLeaf, $TimeStamp)
    New-Item -ItemType Directory -Force -Path (Split-Path $RoboLogPath -Parent) | Out-Null
    & robocopy.exe $Path $Destination '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' "/LOG+:$RoboLogPath" | Out-Null
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
  if (-not (Test-Path $Path)) { return }
  $BackupTarget = Backup-PathVerified -Path $Path -BackupRoot $BackupRoot
  Write-Host "Removing after verified backup: $Path"
  Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
  Write-Host "Backup saved: $BackupTarget" -ForegroundColor Green
}

function Test-WingetHelpSupports
{
  param([Parameter(Mandatory = $true)] [string]$Command, [Parameter(Mandatory = $true)] [string]$Option)
  try
  {
    $HelpText = (& winget $Command --help 2>$null) -join "`n"
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

Write-Host "common.ps1 loaded successfully." -ForegroundColor Green
