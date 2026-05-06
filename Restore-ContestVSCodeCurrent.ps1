# Restore-ContestVSCodeCurrent.ps1
# Restores the current isolated contest VS Code setup.
# This script is safe for Task Scheduler: it reads an explicit manifest instead of relying on user profile env vars.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Root = "$env:SystemDrive\CPTools",
  [string]$ManifestPath = '',
  [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = 'C:\CPTools'
}

$StateRoot = Join-Path $Root 'vscode-contest-state'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $StateRoot 'manifest.json'
}

function Write-Section {
  param([Parameter(Mandatory = $true)] [string]$Message)

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host $Message -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
}

function Stop-VSCodeProcesses {
  Write-Host 'Closing VS Code processes if running...'
  foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium')) {
    try {
      Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {}
  }
  Start-Sleep -Seconds 2
}

function Restore-ShortcutFromManifest {
  param([Parameter(Mandatory = $true)] $Entry)

  $ShortcutPath = [string]$Entry.Path
  $BackupPath = [string]$Entry.BackupPath
  $Existed = [bool]$Entry.Existed

  if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
    return
  }

  $Parent = Split-Path -Path $ShortcutPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($Parent)) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }

  if ($Existed -and -not [string]::IsNullOrWhiteSpace($BackupPath) -and (Test-Path -LiteralPath $BackupPath)) {
    if ($PSCmdlet.ShouldProcess($ShortcutPath, "restore shortcut from $BackupPath")) {
      Copy-Item -LiteralPath $BackupPath -Destination $ShortcutPath -Force
      Write-Host "Shortcut restored: $ShortcutPath" -ForegroundColor Green
    }
  }
  else {
    # The setup script created this shortcut even though it did not exist before.
    # Remove it to return to the pre-contest state.
    if (Test-Path -LiteralPath $ShortcutPath) {
      if ($PSCmdlet.ShouldProcess($ShortcutPath, 'remove contest-created shortcut')) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        Write-Host "Contest-created shortcut removed: $ShortcutPath" -ForegroundColor Green
      }
    }
  }
}

function Remove-ContestCodeWrapper {
  param([AllowNull()] [AllowEmptyString()] [string]$WrapperPath)

  if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
    $WrapperPath = Join-Path $Root 'bin\code.cmd'
  }

  if (-not (Test-Path -LiteralPath $WrapperPath)) {
    return
  }

  $Raw = ''
  try { $Raw = Get-Content -LiteralPath $WrapperPath -Raw -ErrorAction Stop } catch {}
  if ($Raw -match 'vscode-contest|--user-data-dir|--extensions-dir|CONTEST_VSCODE_WRAPPER') {
    if ($PSCmdlet.ShouldProcess($WrapperPath, 'remove contest VS Code code.cmd wrapper')) {
      Remove-Item -LiteralPath $WrapperPath -Force
      Write-Host "Removed contest code wrapper: $WrapperPath" -ForegroundColor Green
    }
  }
  else {
    Write-Warning "Skipping wrapper removal because the file does not look contest-owned: $WrapperPath"
  }
}

function Remove-ContestDirectory {
  param([AllowNull()] [AllowEmptyString()] [string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  if (Test-Path -LiteralPath $Path) {
    if ($PSCmdlet.ShouldProcess($Path, 'remove contest VS Code directory')) {
      Remove-Item -LiteralPath $Path -Recurse -Force
      Write-Host "Removed: $Path" -ForegroundColor Green
    }
  }
}

function Remove-ScheduledRestoreTask {
  param([AllowNull()] [AllowEmptyString()] [string]$TaskName)

  if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = 'ContestSetup-Restore-VSCode'
  }

  try {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task) {
      if ($PSCmdlet.ShouldProcess($TaskName, 'unregister scheduled restore task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task removed: $TaskName" -ForegroundColor Green
      }
    }
  }
  catch {
    Write-Warning "Failed to unregister scheduled task: $($_.Exception.Message)"
  }
}

function Restore-ContestVSCodeCurrent {
  Write-Section 'Restore current contest VS Code setup'

  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Warning "Manifest not found: $ManifestPath"
    Write-Warning 'Removing default contest VS Code artifacts only.'

    Stop-VSCodeProcesses
    Remove-ContestDirectory -Path (Join-Path $Root 'vscode-contest')
    Remove-ContestCodeWrapper -WrapperPath (Join-Path $Root 'bin\code.cmd')
    Remove-ScheduledRestoreTask -TaskName 'ContestSetup-Restore-VSCode'
    return
  }

  $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

  Stop-VSCodeProcesses

  if ($Manifest.Shortcuts) {
    foreach ($Entry in @($Manifest.Shortcuts)) {
      Restore-ShortcutFromManifest -Entry $Entry
    }
  }

  Remove-ContestCodeWrapper -WrapperPath ([string]$Manifest.CodeWrapperPath)
  Remove-ContestDirectory -Path ([string]$Manifest.ContestVSCodeRoot)

  if ($Manifest.TaskName) {
    Remove-ScheduledRestoreTask -TaskName ([string]$Manifest.TaskName)
  }
  else {
    Remove-ScheduledRestoreTask -TaskName 'ContestSetup-Restore-VSCode'
  }

  Write-Host ''
  Write-Host 'Contest VS Code restore completed.' -ForegroundColor Green
}

try {
  Restore-ContestVSCodeCurrent
}
finally {
  if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch {}
  }
}
