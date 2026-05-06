# Restore-LegacyVSCodeFromOldBackups.ps1
# Restores VS Code from old ContestSetup backups created by Reset-VSCodeCompletely.
# It is designed for the old backup layout:
#   C:\CPTools\backup\vscode-YYYYMMDD-HHmmss\<Leaf>-<SHA12>
#
# Why this exists:
# The old restore-vscode.ps1 matched backup children only by leaf name such as "Code-*".
# That can confuse %APPDATA%\Code and %LOCALAPPDATA%\Code because both have the same leaf.
# This script recomputes the same SHA12 token from the original path, so each piece maps exactly.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Root = "$env:SystemDrive\CPTools",

  # Optional: use a specific backup folder, for example:
  # -BackupRoot "C:\CPTools\backup\vscode-20260504-175616"
  [string]$BackupRoot = '',

  # Show detected backup candidates without restoring.
  [switch]$ListOnly,

  # Restore VS Code install folders too. By default only user data/extensions are restored.
  # Use this if you want a byte-level restore of the old installed VS Code folders.
  [switch]$RestoreInstallFolders,

  # Remove C:\CPTools\vscode-contest and contest code.cmd wrapper after restore.
  [switch]$RemoveContestArtifacts,

  [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BackupDir = Join-Path $Root 'backup'
$RestoreBackupRoot = Join-Path $BackupDir ("restore-current-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Section {
  param([Parameter(Mandatory = $true)] [string]$Message)

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host $Message -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
}

function Join-PathIfBase {
  param(
    [AllowNull()] [AllowEmptyString()] [string]$Base,
    [Parameter(Mandatory = $true)] [string]$Child
  )

  if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
  return Join-Path $Base $Child
}

function Get-PathHashToken {
  param([Parameter(Mandatory = $true)] [string]$Path)

  $Sha = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Path)
    return [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '').Substring(0, 12)
  }
  finally {
    $Sha.Dispose()
  }
}

function Get-SafeLeafName {
  param([Parameter(Mandatory = $true)] [string]$Path)

  $Leaf = Split-Path -Path $Path -Leaf
  return ($Leaf -replace '[\\/:*?"<>|]', '_')
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

function Get-VSCodeBackupTargets {
  $Targets = New-Object System.Collections.Generic.List[object]

  $AppDataCode = Join-PathIfBase -Base $env:APPDATA -Child 'Code'
  $LocalAppDataCode = Join-PathIfBase -Base $env:LOCALAPPDATA -Child 'Code'
  $UserVscode = Join-PathIfBase -Base $env:USERPROFILE -Child '.vscode'

  if ($AppDataCode) {
    $Targets.Add([pscustomobject]@{
      Name = 'Roaming user data'
      OriginalPath = $AppDataCode
      Destination = $AppDataCode
      Kind = 'UserData'
      Weight = 40
      Required = $true
    }) | Out-Null
  }

  if ($LocalAppDataCode) {
    $Targets.Add([pscustomobject]@{
      Name = 'Local user data/cache'
      OriginalPath = $LocalAppDataCode
      Destination = $LocalAppDataCode
      Kind = 'UserData'
      Weight = 20
      Required = $false
    }) | Out-Null
  }

  if ($UserVscode) {
    $Targets.Add([pscustomobject]@{
      Name = 'Extensions directory'
      OriginalPath = $UserVscode
      Destination = $UserVscode
      Kind = 'Extensions'
      Weight = 30
      Required = $false
    }) | Out-Null
  }

  foreach ($InstallPath in @(
    (Join-PathIfBase -Base $env:LOCALAPPDATA -Child 'Programs\Microsoft VS Code'),
    (Join-PathIfBase -Base $env:ProgramFiles -Child 'Microsoft VS Code'),
    (Join-PathIfBase -Base ${env:ProgramFiles(x86)} -Child 'Microsoft VS Code')
  )) {
    if ($InstallPath) {
      $Targets.Add([pscustomobject]@{
        Name = "Install folder: $InstallPath"
        OriginalPath = $InstallPath
        Destination = $InstallPath
        Kind = 'Install'
        Weight = 10
        Required = $false
      }) | Out-Null
    }
  }

  return $Targets.ToArray()
}

function Get-ExpectedBackupPiece {
  param(
    [Parameter(Mandatory = $true)] [string]$CandidateRoot,
    [Parameter(Mandatory = $true)] [string]$OriginalPath
  )

  $SafeLeaf = Get-SafeLeafName -Path $OriginalPath
  $Token = Get-PathHashToken -Path $OriginalPath
  $Expected = Join-Path $CandidateRoot ("{0}-{1}" -f $SafeLeaf, $Token)

  if (Test-Path -LiteralPath $Expected) {
    return Get-Item -LiteralPath $Expected -Force
  }

  return $null
}

function Get-LegacyBackupCandidates {
  if (-not (Test-Path -LiteralPath $BackupDir)) {
    return @()
  }

  $Targets = Get-VSCodeBackupTargets

  $Candidates = foreach ($Dir in (Get-ChildItem -LiteralPath $BackupDir -Directory -Filter 'vscode-*' -ErrorAction SilentlyContinue)) {
    $Pieces = New-Object System.Collections.Generic.List[object]
    $Score = 0
    $UserPieceCount = 0
    $InstallPieceCount = 0

    foreach ($Target in $Targets) {
      $Piece = Get-ExpectedBackupPiece -CandidateRoot $Dir.FullName -OriginalPath $Target.OriginalPath
      if ($Piece) {
        $Score += [int]$Target.Weight
        if ($Target.Kind -eq 'Install') { $InstallPieceCount++ } else { $UserPieceCount++ }
        $Pieces.Add([pscustomobject]@{
          Name = $Target.Name
          Kind = $Target.Kind
          OriginalPath = $Target.OriginalPath
          Destination = $Target.Destination
          Source = $Piece.FullName
        }) | Out-Null
      }
    }

    [pscustomobject]@{
      BackupRoot = $Dir.FullName
      Name = $Dir.Name
      LastWriteTime = $Dir.LastWriteTime
      Score = $Score
      UserPieceCount = $UserPieceCount
      InstallPieceCount = $InstallPieceCount
      Pieces = $Pieces.ToArray()
    }
  }

  return @($Candidates | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true })
}

function Select-BestLegacyBackup {
  if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
      throw "Specified backup root does not exist: $BackupRoot"
    }

    $Candidates = Get-LegacyBackupCandidates
    $Full = (Get-Item -LiteralPath $BackupRoot -Force).FullName
    $Selected = $Candidates | Where-Object { $_.BackupRoot -eq $Full } | Select-Object -First 1

    if (-not $Selected) {
      throw "Specified backup root exists, but no recognizable VS Code backup pieces were found: $BackupRoot"
    }

    return $Selected
  }

  $All = Get-LegacyBackupCandidates
  return @($All | Where-Object { $_.UserPieceCount -gt 0 } | Select-Object -First 1)[0]
}

function Copy-DirectoryRobust {
  param(
    [Parameter(Mandatory = $true)] [string]$Source,
    [Parameter(Mandatory = $true)] [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null

  $RoboLogRoot = Join-Path $Root 'logs\robocopy'
  New-Item -ItemType Directory -Force -Path $RoboLogRoot | Out-Null

  $SafeName = (Split-Path -Path $Destination -Leaf) -replace '[\\/:*?"<>| ]', '_'
  $RoboLogPath = Join-Path $RoboLogRoot ("restore-legacy-vscode-{0}-{1}.log" -f $SafeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

  & robocopy.exe $Source $Destination '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' "/LOG+:$RoboLogPath" | Out-Null

  if ($LASTEXITCODE -ge 8) {
    throw "robocopy restore failed. Source=$Source, Destination=$Destination, ExitCode=$LASTEXITCODE, Log=$RoboLogPath"
  }
}

function Move-CurrentPathAside {
  param([Parameter(Mandatory = $true)] [string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  New-Item -ItemType Directory -Force -Path $RestoreBackupRoot | Out-Null

  $SafeLeaf = Get-SafeLeafName -Path $Path
  $Token = Get-PathHashToken -Path $Path
  $Destination = Join-Path $RestoreBackupRoot ("current-{0}-{1}" -f $SafeLeaf, $Token)

  if (Test-Path -LiteralPath $Destination) {
    $Destination = "$Destination-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  }

  Move-Item -LiteralPath $Path -Destination $Destination -Force
  return $Destination
}

function Restore-PathPiece {
  param(
    [Parameter(Mandatory = $true)] [string]$Source,
    [Parameter(Mandatory = $true)] [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Backup source not found: $Source"
  }

  if ($PSCmdlet.ShouldProcess($Destination, "restore from $Source")) {
    $Moved = Move-CurrentPathAside -Path $Destination
    if ($Moved) {
      Write-Host "Current path moved aside:"
      Write-Host "  $Moved"
    }

    $Parent = Split-Path -Path $Destination -Parent
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
      New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }

    $SourceItem = Get-Item -LiteralPath $Source -Force
    if ($SourceItem.PSIsContainer) {
      Copy-DirectoryRobust -Source $Source -Destination $Destination
    }
    else {
      Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
      throw "Restore verification failed: $Destination"
    }

    Write-Host "Restored: $Destination" -ForegroundColor Green
  }
}

function Remove-ContestVSCodeArtifacts {
  Write-Section 'Remove contest VS Code artifacts'

  $ContestVSCodeRoot = Join-Path $Root 'vscode-contest'
  if (Test-Path -LiteralPath $ContestVSCodeRoot) {
    if ($PSCmdlet.ShouldProcess($ContestVSCodeRoot, 'remove isolated contest VS Code data')) {
      Remove-Item -LiteralPath $ContestVSCodeRoot -Recurse -Force
      Write-Host "Removed: $ContestVSCodeRoot" -ForegroundColor Green
    }
  }

  $ContestCodeCmd = Join-Path $Root 'bin\code.cmd'
  if (Test-Path -LiteralPath $ContestCodeCmd) {
    $Raw = ''
    try { $Raw = Get-Content -LiteralPath $ContestCodeCmd -Raw -ErrorAction Stop } catch {}
    if ($Raw -match 'vscode-contest|--user-data-dir|--extensions-dir') {
      if ($PSCmdlet.ShouldProcess($ContestCodeCmd, 'remove contest code.cmd wrapper')) {
        Remove-Item -LiteralPath $ContestCodeCmd -Force
        Write-Host "Removed: $ContestCodeCmd" -ForegroundColor Green
      }
    }
  }
}

function Show-LegacyBackupCandidates {
  Write-Section 'Detected legacy VS Code backup candidates'

  $Candidates = Get-LegacyBackupCandidates
  if ($Candidates.Count -eq 0) {
    Write-Warning "No legacy VS Code backup candidates found under: $BackupDir"
    return
  }

  $Index = 1
  foreach ($Candidate in $Candidates) {
    Write-Host ("[{0}] {1}" -f $Index, $Candidate.BackupRoot) -ForegroundColor Yellow
    Write-Host ("    Score: {0}, User pieces: {1}, Install pieces: {2}, LastWriteTime: {3}" -f $Candidate.Score, $Candidate.UserPieceCount, $Candidate.InstallPieceCount, $Candidate.LastWriteTime)
    foreach ($Piece in $Candidate.Pieces) {
      Write-Host ("    - {0}: {1}" -f $Piece.Name, $Piece.Source)
    }
    $Index++
  }
}

function Restore-LegacyVSCodeBackup {
  Write-Section 'Restore VS Code from legacy ContestSetup backup'

  if ($ListOnly) {
    Show-LegacyBackupCandidates
    return
  }

  Stop-VSCodeProcesses

  $Selected = Select-BestLegacyBackup
  if (-not $Selected) {
    Write-Warning "No usable VS Code backup was found under: $BackupDir"
    return
  }

  Write-Host "Selected backup:" -ForegroundColor Green
  Write-Host "  $($Selected.BackupRoot)"
  Write-Host ("  Score: {0}, User pieces: {1}, Install pieces: {2}" -f $Selected.Score, $Selected.UserPieceCount, $Selected.InstallPieceCount)
  Write-Host "Current VS Code paths will be moved aside under:"
  Write-Host "  $RestoreBackupRoot"

  $Restored = 0

  foreach ($Piece in $Selected.Pieces) {
    if ($Piece.Kind -eq 'Install' -and -not $RestoreInstallFolders) {
      Write-Host "Skipping install folder by default: $($Piece.Destination)" -ForegroundColor DarkGray
      continue
    }

    Restore-PathPiece -Source $Piece.Source -Destination $Piece.Destination
    $Restored++
  }

  if ($RemoveContestArtifacts) {
    Remove-ContestVSCodeArtifacts
  }

  if ($Restored -eq 0) {
    Write-Warning 'No backup pieces were restored.'
  }
  else {
    Write-Host ''
    Write-Host "Legacy VS Code restore completed. Restored pieces: $Restored" -ForegroundColor Green
    Write-Host "Restart PowerShell and VS Code." -ForegroundColor Yellow
  }
}

try {
  Restore-LegacyVSCodeBackup
}
finally {
  if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch {}
  }
}
