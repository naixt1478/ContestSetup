# Setup-ContestVSCodeCurrent.ps1
# New current-style setup:
#   1. Keeps the normal VS Code installation and normal user profile untouched.
#   2. Creates an isolated contest VS Code profile under C:\CPTools\vscode-contest.
#   3. Replaces desktop/start-menu VS Code shortcuts with isolated contest shortcuts.
#   4. Creates C:\CPTools\bin\code.cmd wrapper for terminal use.
#   5. Registers a one-time Task Scheduler job that runs Restore-ContestVSCodeCurrent.ps1 at contest end.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Root = "$env:SystemDrive\CPTools",

  # Example:
  # -ContestEndTime "2026-05-09 17:10"
  [Parameter(Mandatory = $true)]
  [datetime]$ContestEndTime,

  [string]$TaskName = 'ContestSetup-Restore-VSCode',

  # If the repository already installs VS Code elsewhere, leave this off.
  # This script only uses existing VS Code by default.
  [switch]$DoNotInstallExtensions,

  [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = 'C:\CPTools'
}

$ContestVSCodeRoot = Join-Path $Root 'vscode-contest'
$ContestUserDataDir = Join-Path $ContestVSCodeRoot 'user-data'
$ContestExtensionsDir = Join-Path $ContestVSCodeRoot 'extensions'

$StateRoot = Join-Path $Root 'vscode-contest-state'
$ShortcutBackupRoot = Join-Path $StateRoot ("shortcuts-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ManifestPath = Join-Path $StateRoot 'manifest.json'
$CurrentRestoreScriptPath = Join-Path $StateRoot 'Restore-ContestVSCodeCurrent.ps1'

$ToolBin = Join-Path $Root 'bin'
$CodeWrapperPath = Join-Path $ToolBin 'code.cmd'

function Write-Section {
  param([Parameter(Mandatory = $true)] [string]$Message)

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host $Message -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
}

function Write-TextUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$Content
  )

  $Parent = Split-Path -Path $Path -Parent
  if (-not [string]::IsNullOrWhiteSpace($Parent)) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }

  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-JsonUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [object]$InputObject,
    [int]$Depth = 30
  )

  $Json = $InputObject | ConvertTo-Json -Depth $Depth
  Write-TextUtf8NoBom -Path $Path -Content ($Json + [Environment]::NewLine)
}

function Test-IsAdmin {
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell {
  $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($Pwsh) { return $Pwsh.Source }
  return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Get-VSCodeExePath {
  $Candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe')
  )

  foreach ($Candidate in $Candidates) {
    if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
      return $Candidate
    }
  }

  $CodeCmd = Get-Command code.cmd -ErrorAction SilentlyContinue
  if (-not $CodeCmd) {
    $CodeCmd = Get-Command code -ErrorAction SilentlyContinue
  }

  if ($CodeCmd) {
    $Source = $CodeCmd.Source
    $Parent = Split-Path -Path $Source -Parent
    $GrandParent = Split-Path -Path $Parent -Parent
    $PossibleExe = Join-Path $GrandParent 'Code.exe'
    if (Test-Path -LiteralPath $PossibleExe) {
      return $PossibleExe
    }
  }

  throw 'Could not find Code.exe. Install Visual Studio Code first, then run this script again.'
}

function Get-RequiredVSCodeExtensions {
  return @(
    'MS-CEINTL.vscode-language-pack-ko',
    'ms-vscode.cpptools',
    'ms-python.python',
    'ms-python.debugpy'
  )
}

function Get-BlockedVSCodeExtensions {
  return @(
    'formulahendry.code-runner',
    'github.copilot',
    'github.copilot-chat',
    'ms-vscode.vscode-ai',
    'tabnine.tabnine-vscode',
    'codeium.codeium',
    'supermaven.supermaven',
    'continue.continue',
    'sourcegraph.cody-ai',
    'amazonwebservices.amazon-q-vscode'
  )
}

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int[]]$SuccessExitCodes = @(0)
  )

  Write-Host ("{0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray
  $Output = & $FilePath @ArgumentList 2>&1
  $ExitCode = [int]$LASTEXITCODE

  if ($SuccessExitCodes -notcontains $ExitCode) {
    $OutputText = ($Output | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    throw "Native command failed with exit code ${ExitCode}: $FilePath $($ArgumentList -join ' ')" + [Environment]::NewLine + $OutputText
  }

  return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Output) }
}

function Set-ObjectProperty {
  param([object]$Object, [string]$Name, [object]$Value)

  $Property = $Object.PSObject.Properties[$Name]
  if ($Property) {
    $Property.Value = $Value
  }
  else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Initialize-ContestVSCodeDirectories {
  Write-Section 'Initialize isolated contest VS Code directories'

  New-Item -ItemType Directory -Force -Path $ContestUserDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ContestExtensionsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $ToolBin | Out-Null

  Write-Host "Contest user data : $ContestUserDataDir"
  Write-Host "Contest extensions: $ContestExtensionsDir"
}

function Install-ContestVSCodeExtensions {
  param([Parameter(Mandatory = $true)] [string]$CodeExe)

  if ($DoNotInstallExtensions) {
    Write-Host 'Skipping extension installation by -DoNotInstallExtensions.' -ForegroundColor Yellow
    return
  }

  Write-Section 'Install contest VS Code extensions'

  foreach ($Extension in Get-RequiredVSCodeExtensions) {
    Write-Host "Installing contest extension: $Extension" -ForegroundColor Yellow
    Invoke-NativeChecked -FilePath $CodeExe -ArgumentList @(
      '--user-data-dir', $ContestUserDataDir,
      '--extensions-dir', $ContestExtensionsDir,
      '--install-extension', $Extension,
      '--force'
    ) | Out-Null
  }

  $Installed = @(
    (Invoke-NativeChecked -FilePath $CodeExe -ArgumentList @(
      '--user-data-dir', $ContestUserDataDir,
      '--extensions-dir', $ContestExtensionsDir,
      '--list-extensions'
    )).Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }
  )

  foreach ($Extension in Get-BlockedVSCodeExtensions) {
    if ($Installed -contains $Extension.ToLowerInvariant()) {
      Write-Host "Removing blocked contest extension: $Extension" -ForegroundColor Yellow
      Invoke-NativeChecked -FilePath $CodeExe -ArgumentList @(
        '--user-data-dir', $ContestUserDataDir,
        '--extensions-dir', $ContestExtensionsDir,
        '--uninstall-extension', $Extension
      ) | Out-Null
    }
  }
}

function Set-ContestVSCodeSettings {
  Write-Section 'Apply isolated contest VS Code settings'

  $SettingsPath = Join-Path $ContestUserDataDir 'User\settings.json'
  New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath -Parent) | Out-Null

  $Settings = [pscustomobject]@{}
  if (Test-Path -LiteralPath $SettingsPath) {
    try {
      $Raw = Get-Content -LiteralPath $SettingsPath -Raw
      if (-not [string]::IsNullOrWhiteSpace($Raw)) {
        $Settings = $Raw | ConvertFrom-Json
      }
    }
    catch {
      Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak" -Force -ErrorAction SilentlyContinue
      $Settings = [pscustomobject]@{}
    }
  }

  $CopilotEnable = [ordered]@{
    '*' = $false
    plaintext = $false
    markdown = $false
    scminput = $false
    cpp = $false
    c = $false
    python = $false
  }

  $SettingsToApply = [ordered]@{
    'workbench.startupEditor' = 'none'
    'workbench.welcomePage.walkthroughs.openOnInstall' = $false
    'workbench.tips.enabled' = $false
    'workbench.enableExperiments' = $false
    'update.showReleaseNotes' = $false
    'window.commandCenter' = $false
    'chat.commandCenter.enabled' = $false
    'chat.disableAIFeatures' = $true
    'chat.agent.enabled' = $false
    'chat.edits.enabled' = $false
    'chat.mcp.enabled' = $false
    'inlineChat.enabled' = $false
    'inlineChat.accessibleDiffView' = 'off'
    'workbench.commandPalette.experimental.enableNaturalLanguageSearch' = $false
    'workbench.settings.enableNaturalLanguageSearch' = $false
    'github.copilot.enable' = $CopilotEnable
    'github.copilot.chat.enabled' = $false
    'github.copilot.chat.agent.enabled' = $false
    'github.copilot.chat.edits.enabled' = $false
    'github.copilot.editor.enableAutoCompletions' = $false
    'github.copilot.nextEditSuggestions.enabled' = $false
    'github.copilot.inlineSuggest.enable' = $false
    'extensions.ignoreRecommendations' = $true
    'extensions.showRecommendationsOnlyOnDemand' = $true
    'python.terminal.activateEnvironment' = $false
  }

  foreach ($Key in $SettingsToApply.Keys) {
    Set-ObjectProperty -Object $Settings -Name $Key -Value $SettingsToApply[$Key]
  }

  Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 30
  Write-Host "Settings applied: $SettingsPath" -ForegroundColor Green
}

function Get-ShortcutTargets {
  $Targets = New-Object System.Collections.Generic.List[string]

  $Desktop = [Environment]::GetFolderPath('Desktop')
  $StartMenu = [Environment]::GetFolderPath('StartMenu')
  $CommonStartMenu = [Environment]::GetFolderPath('CommonStartMenu')

  if (-not [string]::IsNullOrWhiteSpace($Desktop)) {
    $Targets.Add((Join-Path $Desktop 'Visual Studio Code.lnk')) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace($StartMenu)) {
    $Targets.Add((Join-Path $StartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk')) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace($CommonStartMenu)) {
    $Targets.Add((Join-Path $CommonStartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk')) | Out-Null
  }

  return $Targets.ToArray() | Select-Object -Unique
}

function Set-ContestVSCodeShortcuts {
  param([Parameter(Mandatory = $true)] [string]$CodeExe)

  Write-Section 'Replace VS Code shortcuts with contest shortcuts'

  New-Item -ItemType Directory -Force -Path $ShortcutBackupRoot | Out-Null

  $Shell = New-Object -ComObject WScript.Shell
  $Entries = New-Object System.Collections.Generic.List[object]

  foreach ($ShortcutPath in Get-ShortcutTargets) {
    $ShortcutDir = Split-Path -Path $ShortcutPath -Parent
    New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null

    $Existed = Test-Path -LiteralPath $ShortcutPath
    $BackupPath = ''

    if ($Existed) {
      $BackupName = ((Split-Path -Path $ShortcutPath -Leaf) -replace '[\\/:*?"<>|]', '_') + '-' + ([Guid]::NewGuid().ToString('N')) + '.bak.lnk'
      $BackupPath = Join-Path $ShortcutBackupRoot $BackupName
      Copy-Item -LiteralPath $ShortcutPath -Destination $BackupPath -Force
    }

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'replace with contest VS Code shortcut')) {
      $Shortcut = $Shell.CreateShortcut($ShortcutPath)
      $Shortcut.TargetPath = $CodeExe
      $Shortcut.Arguments = ('--user-data-dir "{0}" --extensions-dir "{1}"' -f $ContestUserDataDir, $ContestExtensionsDir)
      $Shortcut.WorkingDirectory = $Root
      $Shortcut.IconLocation = "$CodeExe,0"
      $Shortcut.Description = 'Contest isolated Visual Studio Code'
      $Shortcut.Save()

      Write-Host "Updated shortcut: $ShortcutPath" -ForegroundColor Green
    }

    $Entries.Add([pscustomobject]@{
      Path = $ShortcutPath
      Existed = $Existed
      BackupPath = $BackupPath
    }) | Out-Null
  }

  return $Entries.ToArray()
}

function Set-ContestCodeWrapper {
  param([Parameter(Mandatory = $true)] [string]$CodeExe)

  Write-Section 'Create terminal code.cmd wrapper'

  $Content = @"
@echo off
rem CONTEST_VSCODE_WRAPPER
"$CodeExe" --user-data-dir "$ContestUserDataDir" --extensions-dir "$ContestExtensionsDir" %*
"@

  if ($PSCmdlet.ShouldProcess($CodeWrapperPath, 'create contest code.cmd wrapper')) {
    Write-TextUtf8NoBom -Path $CodeWrapperPath -Content $Content
    Write-Host "Created: $CodeWrapperPath" -ForegroundColor Green
  }
}

function Write-CurrentRestoreScript {
  Write-Section 'Write scheduled restore script'

  $RestoreScriptContent = @'
# Restore-ContestVSCodeCurrent.ps1
# Generated by Setup-ContestVSCodeCurrent.ps1.

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
'@

  Write-TextUtf8NoBom -Path $CurrentRestoreScriptPath -Content $RestoreScriptContent
  Write-Host "Restore script written: $CurrentRestoreScriptPath" -ForegroundColor Green
}

function Register-ContestRestoreTask {
  Write-Section 'Register scheduled restore task'

  if ($ContestEndTime -le (Get-Date)) {
    throw "ContestEndTime must be in the future. Given: $ContestEndTime"
  }

  if (-not (Test-IsAdmin)) {
    Write-Warning 'Not running as administrator. Task registration with RunLevel Highest may fail.'
  }

  $PowerShellExe = Get-PreferredPowerShell
  $Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -ManifestPath "{2}" -NoPause' -f $CurrentRestoreScriptPath, $Root, $ManifestPath)

  $Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $Arguments -WorkingDirectory $Root
  $Trigger = New-ScheduledTaskTrigger -Once -At $ContestEndTime
  $Principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
  $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

  if ($PSCmdlet.ShouldProcess($TaskName, "register scheduled task at $ContestEndTime")) {
    $Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Existing) {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Restore ContestSetup isolated VS Code after contest end.' | Out-Null
    Write-Host "Scheduled task registered: $TaskName" -ForegroundColor Green
    Write-Host "Restore time: $ContestEndTime"
  }
}

function Save-Manifest {
  param(
    [Parameter(Mandatory = $true)] [string]$CodeExe,
    [Parameter(Mandatory = $true)] [object[]]$ShortcutEntries
  )

  Write-Section 'Save contest VS Code manifest'

  $Manifest = [ordered]@{
    CreatedAt = (Get-Date).ToString('o')
    Root = $Root
    CodeExe = $CodeExe
    ContestVSCodeRoot = $ContestVSCodeRoot
    ContestUserDataDir = $ContestUserDataDir
    ContestExtensionsDir = $ContestExtensionsDir
    StateRoot = $StateRoot
    ShortcutBackupRoot = $ShortcutBackupRoot
    CodeWrapperPath = $CodeWrapperPath
    RestoreScriptPath = $CurrentRestoreScriptPath
    TaskName = $TaskName
    ContestEndTime = $ContestEndTime.ToString('o')
    Shortcuts = $ShortcutEntries
  }

  Write-JsonUtf8NoBom -Path $ManifestPath -InputObject $Manifest -Depth 30
  Write-Host "Manifest saved: $ManifestPath" -ForegroundColor Green
}

function Setup-ContestVSCodeCurrent {
  Write-Section 'Setup current isolated contest VS Code'

  $CodeExe = Get-VSCodeExePath
  Write-Host "VS Code executable: $CodeExe"

  Initialize-ContestVSCodeDirectories
  Install-ContestVSCodeExtensions -CodeExe $CodeExe
  Set-ContestVSCodeSettings
  $ShortcutEntries = Set-ContestVSCodeShortcuts -CodeExe $CodeExe
  Set-ContestCodeWrapper -CodeExe $CodeExe
  Write-CurrentRestoreScript
  Save-Manifest -CodeExe $CodeExe -ShortcutEntries $ShortcutEntries
  Register-ContestRestoreTask

  Write-Host ''
  Write-Host 'Current contest VS Code setup completed.' -ForegroundColor Green
  Write-Host "Contest VS Code data : $ContestVSCodeRoot"
  Write-Host "Restore task         : $TaskName"
  Write-Host "Restore time         : $ContestEndTime"
  Write-Host "Manual restore       : powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$CurrentRestoreScriptPath`" -Root `"$Root`" -ManifestPath `"$ManifestPath`""
}

try {
  Setup-ContestVSCodeCurrent
}
finally {
  if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch {}
  }
}
