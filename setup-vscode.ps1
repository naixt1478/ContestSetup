# setup-vscode.ps1
# VS Code setup for contest environment
# - Keeps the user's normal VS Code installation and profile intact.
# - Uses an isolated user-data-dir and extensions-dir under $Root\vscode-contest.
# - Replaces existing VS Code .lnk shortcuts so they launch the isolated contest profile.

function Join-PathIfRoot
{
  param([string]$RootPath, [string]$ChildPath)
  if ([string]::IsNullOrWhiteSpace($RootPath)) { return $null }
  return (Join-Path $RootPath $ChildPath)
}

function Get-ConfiguredValue
{
  param([string]$Name, [object]$DefaultValue = $null)
  $Variable = Get-Variable -Name $Name -ErrorAction SilentlyContinue
  if ($Variable) { return $Variable.Value }
  return $DefaultValue
}

function Get-ContestRootPath
{
  $ConfiguredRoot = Get-ConfiguredValue -Name 'Root' -DefaultValue 'C:\CPTools'
  if ([string]::IsNullOrWhiteSpace([string]$ConfiguredRoot)) { return 'C:\CPTools' }
  return [string]$ConfiguredRoot
}

function Get-ContestBackupRootPath
{
  $ConfiguredBackupDir = Get-ConfiguredValue -Name 'BackupDir' -DefaultValue $null
  if (-not [string]::IsNullOrWhiteSpace([string]$ConfiguredBackupDir)) { return [string]$ConfiguredBackupDir }
  return (Join-Path (Get-ContestRootPath) 'backup')
}

function Get-ContestTimeStamp
{
  $ConfiguredTimeStamp = Get-ConfiguredValue -Name 'TimeStamp' -DefaultValue $null
  if (-not [string]::IsNullOrWhiteSpace([string]$ConfiguredTimeStamp)) { return [string]$ConfiguredTimeStamp }
  return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Get-ContestVSCodeRoot
{
  return (Join-Path (Get-ContestRootPath) 'vscode-contest')
}

function Get-ContestVSCodeUserDataDir
{
  return (Join-Path (Get-ContestVSCodeRoot) 'user-data')
}

function Get-ContestVSCodeExtensionsDir
{
  return (Join-Path (Get-ContestVSCodeRoot) 'extensions')
}

function Get-ContestVSCodeSettingsPath
{
  return (Join-Path (Get-ContestVSCodeUserDataDir) 'User\settings.json')
}

function Get-ContestVSCodeCliArgs
{
  param([string[]]$ExtraArgs = @())
  return @(
    '--user-data-dir', (Get-ContestVSCodeUserDataDir),
    '--extensions-dir', (Get-ContestVSCodeExtensionsDir)
  ) + $ExtraArgs
}

function Get-VSCodeCommandPath
{
  $Standalone = Join-Path (Get-ContestRootPath) 'vscode\bin\code.cmd'
  if (Test-Path -LiteralPath $Standalone) { return $Standalone }
  return $null
}

function Get-VSCodeExePath
{
  $Standalone = Join-Path (Get-ContestRootPath) 'vscode\Code.exe'
  if (Test-Path -LiteralPath $Standalone) { return $Standalone }
  return $null
}

function Stop-VSCodeProcesses
{
  Write-Host 'Closing VS Code processes if running...'
  foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium'))
  {
    try { Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
  Start-Sleep -Seconds 2
}

function Initialize-ContestVSCodeIsolated
{
  Write-Section 'Prepare isolated VS Code for contest'

  $ContestRoot = Get-ContestVSCodeRoot
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir

  New-Item -ItemType Directory -Force -Path $ContestRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null

  Write-Host 'Contest VS Code profile:' -ForegroundColor Green
  Write-Host "  User data:  $UserDataDir"
  Write-Host "  Extensions: $ExtensionsDir"
}

function Reset-VSCodeCompletely
{
  # Backward-compatible name: this function used to backup/remove the real VS Code profile.
  # The contest setup now avoids touching %APPDATA%\Code, %LOCALAPPDATA%\Code, and %USERPROFILE%\.vscode.
  Initialize-ContestVSCodeIsolated
  Write-Host 'Existing VS Code installation/profile was left untouched.' -ForegroundColor Green
}

function Install-VSCodeStandalone
{
  Write-Section 'Install Standalone VS Code'
  if (Get-VSCodeCommandPath) { Write-Host 'Standalone VS Code already installed.'; return }

  $VSCodeArchiveUrl = 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable'
  $VSCodeArchivePath = Join-Path (Get-ContestRootPath) 'downloads\vscode-win32-x64-archive.zip'
  
  Download-VerifiedFile -Url $VSCodeArchiveUrl -OutFile $VSCodeArchivePath -AllowedPublisherKeywords @()
  
  $ExtractPath = Join-Path (Get-ContestRootPath) 'vscode'
  Write-Host "Extracting VS Code to $ExtractPath ..."
  Expand-Archive -Path $VSCodeArchivePath -DestinationPath $ExtractPath -Force
  
  if (-not (Get-VSCodeCommandPath)) { throw 'code.cmd was not found after extraction.' }
  Write-Host 'Standalone VS Code install completed.' -ForegroundColor Green
}

function Get-RequiredVSCodeExtensions
{
  return @(
    'MS-CEINTL.vscode-language-pack-ko',
    'ms-vscode.cpptools',
    'ms-python.python',
    'ms-python.debugpy'
  )
}

function Get-BlockedVSCodeExtensions
{
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

function Set-ObjectProperty
{
  param([object]$Object, [string]$Name, [object]$Value)
  $Property = $Object.PSObject.Properties[$Name]
  if ($Property) { $Property.Value = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-VSCodeAiHiddenSettings
{
  Write-Section 'Apply contest VS Code AI hiding settings'

  $SettingsPath = Get-ContestVSCodeSettingsPath
  New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath -Parent) | Out-Null

  $Settings = [pscustomobject]@{}
  if (Test-Path -LiteralPath $SettingsPath)
  {
    try
    {
      $Raw = Get-Content -LiteralPath $SettingsPath -Raw
      if ($Raw) { $Settings = $Raw | ConvertFrom-Json }
    }
    catch
    {
      Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak" -ErrorAction SilentlyContinue
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
    'update.mode' = 'none'
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
    'extensions.autoCheckUpdates' = $false
    'extensions.autoUpdate' = $false
    'python.terminal.activateEnvironment' = $false
  }

  $PythonExeValue = Get-ConfiguredValue -Name 'PythonExe' -DefaultValue $null
  if (-not [string]::IsNullOrWhiteSpace([string]$PythonExeValue))
  {
    $SettingsToApply['python.defaultInterpreterPath'] = [string]$PythonExeValue
  }

  foreach ($Key in $SettingsToApply.Keys)
  {
    Set-ObjectProperty -Object $Settings -Name $Key -Value $SettingsToApply[$Key]
  }

  Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 30
  Write-Host "Contest VS Code settings applied: $SettingsPath" -ForegroundColor Green
}

function Get-InstalledContestVSCodeExtensions
{
  $CodeCmd = Get-VSCodeCommandPath
  if (-not $CodeCmd) { return @() }

  $Output = @(Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--list-extensions')) -Quiet).Output
  return @($Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function Remove-BlockedVSCodeExtensions
{
  Write-Section 'Remove blocked VS Code extensions from contest profile'

  $CodeCmd = Get-VSCodeCommandPath
  if (-not $CodeCmd) { return }

  $Installed = @(Get-InstalledContestVSCodeExtensions)
  foreach ($Extension in Get-BlockedVSCodeExtensions)
  {
    if ($Installed -contains $Extension.ToLowerInvariant())
    {
      Write-Host "Removing from contest profile: $Extension"
      Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--uninstall-extension', $Extension)) | Out-Null
    }
  }
}

function Warn-IfRequiredVSCodeExtensionsMissing
{
  $Installed = @(Get-InstalledContestVSCodeExtensions)
  $Missing = @()

  foreach ($Extension in Get-RequiredVSCodeExtensions)
  {
    if ($Installed -notcontains $Extension.ToLowerInvariant()) { $Missing += $Extension }
  }

  if ($Missing.Count -gt 0)
  {
    Write-Warning ('Missing in contest profile: ' + ($Missing -join ', '))
  }
  else
  {
    Write-Host 'All required extensions are installed in the contest profile.' -ForegroundColor Green
  }
}

function Install-VSCodeExtensions
{
  Write-Section 'Install VS Code extensions into contest profile'

  $CodeCmd = $null
  $WaitCount = 0
  while (-not $CodeCmd -and $WaitCount -lt 60)
  {
    $CodeCmd = Get-VSCodeCommandPath
    if (-not $CodeCmd)
    {
      Start-Sleep -Seconds 2
      $WaitCount++
    }
  }

  if (-not $CodeCmd) { throw 'code.cmd not found.' }

  Initialize-ContestVSCodeIsolated

  foreach ($Extension in Get-RequiredVSCodeExtensions)
  {
    Write-Host "Installing into contest profile: $Extension"
    Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--install-extension', $Extension, '--force')) | Out-Null
  }
}

function Convert-PathToSafeFileName
{
  param([string]$Path)
  $Safe = [string]$Path
  $Safe = $Safe -replace ':', ''
  $Safe = $Safe -replace '[\\/*?"<>|]', '_'
  $Safe = $Safe -replace '\s+', '_'
  return $Safe
}

function Get-StandardVSCodeShortcutCandidates
{
  $Candidates = @()

  $Desktop = [Environment]::GetFolderPath('Desktop')
  $CommonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
  $StartMenu = [Environment]::GetFolderPath('StartMenu')
  $CommonStartMenu = [Environment]::GetFolderPath('CommonStartMenu')

  if ($Desktop) { $Candidates += (Join-Path $Desktop 'Visual Studio Code.lnk') }
  if ($CommonDesktop) { $Candidates += (Join-Path $CommonDesktop 'Visual Studio Code.lnk') }
  if ($StartMenu) { $Candidates += (Join-Path $StartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk') }
  if ($CommonStartMenu) { $Candidates += (Join-Path $CommonStartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk') }

  return @($Candidates | Select-Object -Unique)
}

function Get-VSCodeShortcutTargets
{
  $Candidates = @(Get-StandardVSCodeShortcutCandidates)
  $Existing = @($Candidates | Where-Object { Test-Path -LiteralPath $_ })

  if ($Existing.Count -gt 0) { return $Existing }

  $Desktop = [Environment]::GetFolderPath('Desktop')
  $StartMenu = [Environment]::GetFolderPath('StartMenu')
  $Targets = @()
  if ($Desktop) { $Targets += (Join-Path $Desktop 'Visual Studio Code.lnk') }
  if ($StartMenu) { $Targets += (Join-Path $StartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk') }

  return @($Targets | Select-Object -Unique)
}

function Set-ContestVSCodeShortcut
{
  Write-Section 'Replace VS Code shortcuts with contest launcher'

  $CodeExe = Get-VSCodeExePath
  if (-not $CodeExe) { throw 'Could not find Code.exe for Visual Studio Code.' }

  Initialize-ContestVSCodeIsolated

  $ContestRoot = Get-ContestVSCodeRoot
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir
  $ShortcutBackupRoot = Join-Path (Get-ContestBackupRootPath) ('vscode-shortcuts-' + (Get-ContestTimeStamp))
  New-Item -ItemType Directory -Force -Path $ShortcutBackupRoot | Out-Null

  $Shell = New-Object -ComObject WScript.Shell
  $Manifest = @()

  foreach ($ShortcutPath in Get-VSCodeShortcutTargets)
  {
    try
    {
      $ShortcutDir = Split-Path -LiteralPath $ShortcutPath -Parent
      New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null

      $Existed = Test-Path -LiteralPath $ShortcutPath
      $BackupPath = $null

      if ($Existed)
      {
        $BackupName = (Convert-PathToSafeFileName -Path $ShortcutPath) + '.bak.lnk'
        $BackupPath = Join-Path $ShortcutBackupRoot $BackupName
        Copy-Item -LiteralPath $ShortcutPath -Destination $BackupPath -Force
      }

      $Shortcut = $Shell.CreateShortcut($ShortcutPath)
      $Shortcut.TargetPath = $CodeExe
      $Shortcut.Arguments = @(
        '--user-data-dir', ('"' + $UserDataDir + '"'),
        '--extensions-dir', ('"' + $ExtensionsDir + '"')
      ) -join ' '
      $Shortcut.WorkingDirectory = (Get-ContestRootPath)
      $Shortcut.IconLocation = "$CodeExe,0"
      $Shortcut.Description = 'Contest isolated Visual Studio Code'
      $Shortcut.Save()

      $Manifest += [pscustomobject]@{
        ShortcutPath = $ShortcutPath
        Existed = $Existed
        BackupPath = $BackupPath
      }

      Write-Host "Updated shortcut: $ShortcutPath" -ForegroundColor Green
    }
    catch
    {
      Write-Warning "Failed to update shortcut: $ShortcutPath - $($_.Exception.Message)"
    }
  }

  $ManifestPath = Join-Path $ContestRoot 'shortcut-manifest.json'
  Write-JsonUtf8NoBom -Path $ManifestPath -InputObject $Manifest -Depth 10
  Write-LinesUtf8NoBom -Path (Join-Path $ContestRoot 'shortcut-backup-root.txt') -Lines @($ShortcutBackupRoot)

  Write-Host "Shortcut manifest: $ManifestPath" -ForegroundColor Green
}

function New-ContestVSCodeLauncher
{
  Write-Section 'Create contest VS Code launcher'

  $CodeExe = Get-VSCodeExePath
  if (-not $CodeExe) { throw 'Could not find Code.exe for Visual Studio Code.' }

  Initialize-ContestVSCodeIsolated

  $ContestRoot = Get-ContestVSCodeRoot
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir
  $LauncherPath = Join-Path $ContestRoot 'Start-Contest-VSCode.ps1'

  $Launcher = @"
param(
  [string]`$Path = (Get-Location).Path
)

`$CodeExe = '$CodeExe'
`$UserDataDir = '$UserDataDir'
`$ExtensionsDir = '$ExtensionsDir'

& `$CodeExe --user-data-dir `$UserDataDir --extensions-dir `$ExtensionsDir `$Path
"@

  Write-TextUtf8NoBom -Path $LauncherPath -Text $Launcher
  Write-Host "Contest VS Code launcher created: $LauncherPath" -ForegroundColor Green
}

function New-ContestVSCodeCliWrapper
{
  Write-Section 'Create contest code.cmd wrapper'

  $CodeCmd = Get-VSCodeCommandPath
  if (-not $CodeCmd) { throw 'Could not find code.cmd for Visual Studio Code.' }

  Initialize-ContestVSCodeIsolated

  $BinDir = Join-Path (Get-ContestRootPath) 'bin'
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  $WrapperPath = Join-Path $BinDir 'code.cmd'
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir

  $Wrapper = @"
@echo off
"$CodeCmd" --user-data-dir "$UserDataDir" --extensions-dir "$ExtensionsDir" %*
"@

  Write-TextUtf8NoBom -Path $WrapperPath -Text $Wrapper
  Write-Host "Contest code.cmd wrapper created: $WrapperPath" -ForegroundColor Green
  Write-Host 'Make sure this directory is before the normal VS Code bin directory in PATH if you want `code` to open the contest profile.' -ForegroundColor Yellow
}

function Restore-NormalVSCodeShortcut
{
  param([switch]$RemoveContestData)

  Write-Section 'Restore normal VS Code shortcuts'

  $ContestRoot = Get-ContestVSCodeRoot
  $ManifestPath = Join-Path $ContestRoot 'shortcut-manifest.json'

  if (Test-Path -LiteralPath $ManifestPath)
  {
    $Manifest = @(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json)
    foreach ($Item in $Manifest)
    {
      try
      {
        if ($Item.Existed -and $Item.BackupPath -and (Test-Path -LiteralPath $Item.BackupPath))
        {
          New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath $Item.ShortcutPath -Parent) | Out-Null
          Copy-Item -LiteralPath $Item.BackupPath -Destination $Item.ShortcutPath -Force
          Write-Host "Restored shortcut: $($Item.ShortcutPath)" -ForegroundColor Green
        }
        elseif (Test-Path -LiteralPath $Item.ShortcutPath)
        {
          Remove-Item -LiteralPath $Item.ShortcutPath -Force
          Write-Host "Removed contest shortcut: $($Item.ShortcutPath)" -ForegroundColor Green
        }
      }
      catch
      {
        Write-Warning "Failed to restore shortcut: $($Item.ShortcutPath) - $($_.Exception.Message)"
      }
    }
  }
  else
  {
    Write-Host "No shortcut manifest found at $ManifestPath. Skipping shortcut restoration." -ForegroundColor Yellow
  }

  if ($RemoveContestData -and (Test-Path -LiteralPath $ContestRoot))
  {
    Stop-VSCodeProcesses
    Remove-Item -LiteralPath $ContestRoot -Recurse -Force
    Write-Host "Removed isolated contest VS Code data: $ContestRoot" -ForegroundColor Green
  }
}

Write-Section 'Setup VS Code'

if (-not (Get-VSCodeCommandPath))
{
  Install-VSCodeStandalone
}
else
{
  Write-Host 'Standalone VS Code is already installed.' -ForegroundColor Green
}

Initialize-ContestVSCodeIsolated
Install-VSCodeExtensions
Remove-BlockedVSCodeExtensions
Set-VSCodeAiHiddenSettings
Set-ContestVSCodeShortcut
New-ContestVSCodeLauncher
New-ContestVSCodeCliWrapper
Warn-IfRequiredVSCodeExtensionsMissing
