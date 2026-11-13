# lib/logging-and-manifest.ps1
# Transcript logging, error log persistence, and install-manifest.json state management

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

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
    $TempBase = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath().TrimEnd('\', '/') }
    $TempLogDir = Join-Path $TempBase 'ContestSetup-Logs'
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
    [Alias('ExtraFields')]
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
