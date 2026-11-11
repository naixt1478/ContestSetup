#requires -Version 5.1
# install-ai-hosts.ps1
# ContestSetup v2.0 -- Standalone AI Hosts Block Bootstrapper
#
# Default:
#   Stages ai-hosts-block.ps1, applies the built-in AI hosts blocklist (IPv4 + IPv6 + www + Browser DoH policy),
#   and schedules automatic restore at 2026-11-23 20:30 KST when run before exam end (or after 5 hours / at -Until).
#
# Usage:
#   irm https://raw.githubusercontent.com/<USER>/<REPO>/main/install-ai-hosts.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File .\install-ai-hosts.ps1 -DurationHours 3
#   powershell -ExecutionPolicy Bypass -File .\install-ai-hosts.ps1 -Until "2026-11-23 20:30"
#   powershell -ExecutionPolicy Bypass -File .\install-ai-hosts.ps1 -Restore

[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
  [Parameter(ParameterSetName = 'Apply')] [switch]$Apply,
  [Parameter(ParameterSetName = 'Restore')] [switch]$Restore,
  [Parameter(ParameterSetName = 'Apply')] [int]$DurationHours = 0,
  [Parameter(ParameterSetName = 'Apply')] [string]$Until = '',
  [Parameter(ParameterSetName = 'Apply')] [switch]$NoSchedule,
  [Parameter(ParameterSetName = 'Apply')] [string]$NotAfter = '',
  [switch]$SkipBrowserPolicy,
  [string]$Root = "$env:SystemDrive\CPTools"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

if (-not (Get-Variable -Name 'Root' -ErrorAction SilentlyContinue) -or [string]::IsNullOrWhiteSpace($Root))
{
  $Root = if ($env:CONTEST_ROOT) { $env:CONTEST_ROOT } else { "$env:SystemDrive\CPTools" }
}
foreach ($SwitchVar in @('Apply', 'Restore', 'NoSchedule', 'SkipBrowserPolicy'))
{
  if (-not (Get-Variable -Name $SwitchVar -ErrorAction SilentlyContinue))
  {
    Set-Variable -Name $SwitchVar -Value $false
  }
}
if (-not (Get-Variable -Name 'DurationHours' -ErrorAction SilentlyContinue)) { $DurationHours = 0 }
if (-not (Get-Variable -Name 'Until' -ErrorAction SilentlyContinue) -or $null -eq $Until) { $Until = '' }
if (-not (Get-Variable -Name 'NotAfter' -ErrorAction SilentlyContinue) -or $null -eq $NotAfter) { $NotAfter = '' }

$FullRoot = [IO.Path]::GetFullPath($Root.Trim())
if ($FullRoot -notmatch '^[A-Za-z]:\\$')
{
  $Root = $FullRoot.TrimEnd('\', '/')
}

$RepoOwner = 'naixt1478'
$RepoName = 'ContestSetup'
$Branch = 'main'
$AiScriptName = 'ai-hosts-block.ps1'
$DefaultExamEndKstIso = '2026-11-23T20:30:00+09:00'

$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$AiScriptUrl = "$RawBase/$AiScriptName"
$BootstrapDir = Join-Path $env:TEMP 'contest-env-installer'
$AiScriptPath = Join-Path $BootstrapDir $AiScriptName

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

try
{
  try
  {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }
  catch {}

  Write-Host ''
  Write-Host 'Contest AI Hosts Block Installer (v2.0)' -ForegroundColor Cyan
  Write-Host "Repository : $RepoOwner/$RepoName"
  Write-Host "Branch     : $Branch"
  Write-Host "Script     : $AiScriptName"
  Write-Host ''

  New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null

  $LocalCandidate = if ($PSScriptRoot) { Join-Path $PSScriptRoot $AiScriptName } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($LocalCandidate) -and (Test-Path -LiteralPath $LocalCandidate))
  {
    Copy-Item -LiteralPath $LocalCandidate -Destination $AiScriptPath -Force
    Write-Host "Copied local script: $LocalCandidate -> $AiScriptPath" -ForegroundColor Green
  }
  else
  {
    Write-Host 'Downloading AI hosts script...'
    Write-Host $AiScriptUrl
    $Downloaded = $false
    $LastErr = $null
    for ($Attempt = 1; $Attempt -le 3; $Attempt++)
    {
      try
      {
        $CacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $OldProgressPref = $ProgressPreference
        try
        {
          $ProgressPreference = 'SilentlyContinue'
          $Params = @{ Uri = "${AiScriptUrl}?cb=$CacheBust"; OutFile = $AiScriptPath; ErrorAction = 'Stop' }
          if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
          Invoke-WebRequest @Params
          $Downloaded = $true
          break
        }
        finally
        {
          $ProgressPreference = $OldProgressPref
        }
      }
      catch
      {
        $LastErr = $_
        if ($Attempt -lt 3) { Start-Sleep -Seconds 2 }
      }
    }
    if (-not $Downloaded -or -not (Test-Path -LiteralPath $AiScriptPath))
    {
      $ErrDetail = if ($null -ne $LastErr) { $LastErr.Exception.Message } else { 'unknown download failure' }
      throw "Download failed: $AiScriptPath ($ErrDetail)"
    }
    Write-Host "Downloaded: $AiScriptPath" -ForegroundColor Green
  }

  $PowerShellExe = Get-PreferredPowerShell
  # Do NOT pass -NoExit so unattended or elevated execution completes cleanly without hanging
  $ForwardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AiScriptPath)
  if ($Restore)
  {
    $ForwardArgs += '-Restore'
  }
  else
  {
    $ForwardArgs += '-Apply'
    $HasExplicitDuration = ($null -ne $PSBoundParameters) -and $PSBoundParameters.ContainsKey('DurationHours')
    if (-not [string]::IsNullOrWhiteSpace($Until))
    {
      $ForwardArgs += @('-Until', $Until)
    }
    elseif ($HasExplicitDuration -or $DurationHours -gt 0)
    {
      $ForwardArgs += @('-DurationHours', [string]$DurationHours)
    }
    else
    {
      $ExamEndLocal = ([DateTimeOffset]::Parse($DefaultExamEndKstIso, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
      if ((Get-Date).AddMinutes(2) -lt $ExamEndLocal)
      {
        $ForwardArgs += @('-Until', '2026-11-23 20:30')
      }
      else
      {
        $ForwardArgs += @('-DurationHours', '5')
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($NotAfter))
    {
      $ForwardArgs += @('-NotAfter', $NotAfter)
    }
    if ($NoSchedule) { $ForwardArgs += '-NoSchedule' }
  }
  if ($SkipBrowserPolicy) { $ForwardArgs += '-SkipBrowserPolicy' }
  $ForwardArgs += @('-Root', $Root)

  if (Test-IsAdmin)
  {
    Write-Host 'Running AI hosts script as administrator...' -ForegroundColor Green
    & $PowerShellExe @ForwardArgs
    $ChildExitCode = $LASTEXITCODE
    if ($null -ne $ChildExitCode -and $ChildExitCode -ne 0)
    {
      throw "AI hosts script exited with failure code $ChildExitCode."
    }
  }
  else
  {
    Write-Host 'Requesting administrator permission...' -ForegroundColor Yellow
    $ArgumentString = ($ForwardArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    try
    {
      $Proc = Start-Process -FilePath $PowerShellExe -ArgumentList $ArgumentString -Verb RunAs -Wait -PassThru
    }
    catch [System.ComponentModel.Win32Exception]
    {
      throw "Administrator UAC prompt was cancelled or denied: $($_.Exception.Message)"
    }
    $ElevatedExitCode = if ($null -ne $Proc) { [int]$Proc.ExitCode } else { 1 }
    if ($ElevatedExitCode -ne 0)
    {
      throw "Elevated AI hosts script exited with failure code $ElevatedExitCode."
    }
  }

  Write-Host ''
  Write-Host 'AI hosts installer finished.' -ForegroundColor Green
}
catch
{
  Write-Host ''
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  if ($PSCommandPath)
  {
    exit 1
  }
  else
  {
    $global:LASTEXITCODE = 1
    return
  }
}
