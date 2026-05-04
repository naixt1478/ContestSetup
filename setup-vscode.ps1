# setup-vscode.ps1

function Get-VSCodeCommandPath {
    $Candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd'))
    foreach ($Candidate in $Candidates) { if ($Candidate -and (Test-Path $Candidate)) { return $Candidate } }
    $Cmd = Get-Command code.cmd -ErrorAction SilentlyContinue; if ($Cmd) { return $Cmd.Source }
    $Cmd = Get-Command code -ErrorAction SilentlyContinue; if ($Cmd) { return $Cmd.Source }
    return $null
}

function Stop-VSCodeProcesses {
    Write-Host 'Closing VS Code processes if running...'
    foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium')) {
        try { Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
}

function Reset-VSCodeCompletely {
    Write-Section 'Reset existing VS Code'
    Stop-VSCodeProcesses
    $BackupRoot = Join-Path $BackupDir ("vscode-$TimeStamp")
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    
    $CodeCmdBeforeReset = Get-VSCodeCommandPath
    if ($CodeCmdBeforeReset) {
        try {
            $ExtPath = Join-Path $BackupRoot 'extensions-before-reset.txt'
            $ExtOutput = Invoke-NativeCommand -FilePath $CodeCmdBeforeReset -ArgumentList @('--list-extensions') -Quiet
            Write-LinesUtf8NoBom -Path $ExtPath -Lines ([string[]]$ExtOutput.Output)
        } catch {}
    }
    foreach ($Path in @((Join-Path $env:APPDATA 'Code'), (Join-Path $env:LOCALAPPDATA 'Code'), (Join-Path $env:USERPROFILE '.vscode'))) { Backup-And-RemovePathSafe -Path $Path -BackupRoot $BackupRoot }
    foreach ($Folder in @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'), (Join-Path $env:ProgramFiles 'Microsoft VS Code'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code'))) {
        if ($Folder -and (Test-Path $Folder)) { Backup-PathVerified -Path $Folder -BackupRoot $BackupRoot | Out-Null }
    }
    Uninstall-WingetPackageIfExists -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code'
    foreach ($Folder in @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'), (Join-Path $env:ProgramFiles 'Microsoft VS Code'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code'))) {
        if ($Folder -and (Test-Path $Folder)) { Backup-And-RemovePathSafe -Path $Folder -BackupRoot $BackupRoot }
    }
    Write-Host 'VS Code reset completed.' -ForegroundColor Green
}

function Install-VSCodeDirect {
    Write-Section 'Install VS Code directly'
    if (Get-VSCodeCommandPath) { Write-Host 'VS Code already installed.'; return }
    Download-VerifiedFile -Url $VSCodeInstallerUrl -OutFile $VSCodeInstallerPath -AllowedPublisherKeywords @('Microsoft')
    $Process = Start-Process -FilePath $VSCodeInstallerPath -ArgumentList @('/VERYSILENT', '/NORESTART', '/MERGETASKS=addcontextmenufiles,addcontextmenufolders,addtopath') -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "VS Code direct installer failed. Exit code: $($Process.ExitCode)" }
    $WaitCount = 0; while (-not (Get-VSCodeCommandPath) -and $WaitCount -lt 60) { Start-Sleep -Seconds 2; $WaitCount++ }
    if (-not (Get-VSCodeCommandPath)) { throw 'code.cmd was not found.' }
    Write-Host 'VS Code direct install completed.' -ForegroundColor Green
}

function Get-RequiredVSCodeExtensions { return @('MS-CEINTL.vscode-language-pack-ko', 'ms-vscode.cpptools', 'ms-python.python', 'ms-python.debugpy') }
function Get-BlockedVSCodeExtensions { return @('formulahendry.code-runner', 'github.copilot', 'github.copilot-chat', 'ms-vscode.vscode-ai', 'tabnine.tabnine-vscode', 'codeium.codeium', 'supermaven.supermaven', 'continue.continue', 'sourcegraph.cody-ai', 'amazonwebservices.amazon-q-vscode') }

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    $Property = $Object.PSObject.Properties[$Name]
    if ($Property) { $Property.Value = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-VSCodeAiHiddenSettings {
    Write-Section 'Apply VS Code AI hiding settings'
    $SettingsPath = (Join-Path $env:APPDATA 'Code\User\settings.json')
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath -Parent) | Out-Null
    $Settings = [pscustomobject]@{}
    if (Test-Path $SettingsPath) {
        try { $Raw = Get-Content -Path $SettingsPath -Raw; if ($Raw) { $Settings = $Raw | ConvertFrom-Json } }
        catch { Copy-Item $SettingsPath "$SettingsPath.bak" -ErrorAction SilentlyContinue; $Settings = [pscustomobject]@{} }
    }
    $CopilotEnable = [ordered]@{ '*' = $false; plaintext = $false; markdown = $false; scminput = $false; cpp = $false; c = $false; python = $false }
    $SettingsToApply = [ordered]@{ 'workbench.startupEditor' = 'none'; 'workbench.welcomePage.walkthroughs.openOnInstall' = $false; 'workbench.tips.enabled' = $false; 'workbench.enableExperiments' = $false; 'update.showReleaseNotes' = $false; 'window.commandCenter' = $false; 'chat.commandCenter.enabled' = $false; 'chat.disableAIFeatures' = $true; 'chat.agent.enabled' = $false; 'chat.edits.enabled' = $false; 'chat.mcp.enabled' = $false; 'inlineChat.enabled' = $false; 'inlineChat.accessibleDiffView' = 'off'; 'workbench.commandPalette.experimental.enableNaturalLanguageSearch' = $false; 'workbench.settings.enableNaturalLanguageSearch' = $false; 'github.copilot.enable' = $CopilotEnable; 'github.copilot.chat.enabled' = $false; 'github.copilot.chat.agent.enabled' = $false; 'github.copilot.chat.edits.enabled' = $false; 'github.copilot.editor.enableAutoCompletions' = $false; 'github.copilot.nextEditSuggestions.enabled' = $false; 'github.copilot.inlineSuggest.enable' = $false; 'extensions.ignoreRecommendations' = $true; 'extensions.showRecommendationsOnlyOnDemand' = $true; 'python.defaultInterpreterPath' = $PythonExe; 'python.terminal.activateEnvironment' = $false }
    foreach ($Key in $SettingsToApply.Keys) { Set-ObjectProperty -Object $Settings -Name $Key -Value $SettingsToApply[$Key] }
    Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 30
    Write-Host "Settings applied." -ForegroundColor Green
}

function Remove-BlockedVSCodeExtensions {
    Write-Section 'Remove VS Code AI extensions'
    $CodeCmd = Get-VSCodeCommandPath; if (-not $CodeCmd) { return }
    $Installed = @((Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList @('--list-extensions') -Quiet).Output | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() })
    foreach ($Extension in Get-BlockedVSCodeExtensions) {
        if ($Installed -contains $Extension.ToLowerInvariant()) {
            Write-Host "Removing: $Extension"
            Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList @('--uninstall-extension', $Extension) | Out-Null
        }
    }
}

function Warn-IfRequiredVSCodeExtensionsMissing {
    $CodeCmd = Get-VSCodeCommandPath; if (-not $CodeCmd) { return }
    $Installed = @((Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList @('--list-extensions') -Quiet).Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $Missing = @()
    foreach ($Extension in Get-RequiredVSCodeExtensions) { if ($Installed -notcontains $Extension.ToLowerInvariant()) { $Missing += $Extension } }
    if ($Missing.Count -gt 0) { Write-Warning ('Missing: ' + ($Missing -join ', ')) } else { Write-Host 'All required extensions installed.' -ForegroundColor Green }
}

function Install-VSCodeExtensions {
    Write-Section 'Install VS Code extensions'
    $CodeCmd = $null; $WaitCount = 0
    while (-not $CodeCmd -and $WaitCount -lt 60) { $CodeCmd = Get-VSCodeCommandPath; if (-not $CodeCmd) { Start-Sleep -Seconds 2; $WaitCount++ } }
    if (-not $CodeCmd) { throw 'code.cmd not found.' }
    foreach ($Extension in Get-RequiredVSCodeExtensions) {
        Write-Host "Installing: $Extension"
        Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList @('--install-extension', $Extension, '--force') | Out-Null
    }
}

Write-Section 'Setup VS Code'
if ($KeepVSCode) {
    if (-not (Get-VSCodeCommandPath)) {
        if (-not (Install-ByWinget -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code')) { Install-VSCodeDirect }
        Install-VSCodeExtensions
    } else { Warn-IfRequiredVSCodeExtensionsMissing }
} else {
    Reset-VSCodeCompletely
    if (-not (Install-ByWinget -Id 'Microsoft.VisualStudioCode' -NameForLog 'Visual Studio Code')) { Install-VSCodeDirect }
    Install-VSCodeExtensions
}
Remove-BlockedVSCodeExtensions
Set-VSCodeAiHiddenSettings
