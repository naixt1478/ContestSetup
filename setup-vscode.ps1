# setup-vscode.ps1
# ContestSetup v2.0 -- Isolated Portable VS Code, Batched Idempotent Extensions, Marketplace Backup/Lock & C++ IntelliSense
# - Keeps the user's normal VS Code installation and profile intact.
# - Uses an isolated user-data-dir and extensions-dir under $Root\vscode-contest (plus portable $Root\vscode\data).
# - Replaces existing VS Code .lnk shortcuts so they launch the isolated contest profile in Korean (--locale ko).

if (-not (Get-Command Import-ContestLibraryModule -ErrorAction SilentlyContinue))
{
  function Import-ContestLibraryModule
  {
    param(
      [Parameter(Mandatory = $true)] [string]$ModuleName,
      [switch]$Optional
    )
    $Candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot))
    {
      $Candidates.Add((Join-Path (Join-Path $PSScriptRoot 'lib') $ModuleName)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath))
    {
      $CmdParent = Split-Path -Parent $PSCommandPath
      if (-not [string]::IsNullOrWhiteSpace($CmdParent))
      {
        $Candidates.Add((Join-Path (Join-Path $CmdParent 'lib') $ModuleName)) | Out-Null
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_LIB_DIR))
    {
      $Candidates.Add((Join-Path $env:CONTEST_LIB_DIR $ModuleName)) | Out-Null
    }
    $StageVar = Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue
    if ($null -ne $StageVar -and -not [string]::IsNullOrWhiteSpace([string]$StageVar.Value))
    {
      $Candidates.Add((Join-Path (Join-Path ([string]$StageVar.Value) 'lib') $ModuleName)) | Out-Null
    }
    try
    {
      $CurLoc = (Get-Location).Path
      if (-not [string]::IsNullOrWhiteSpace($CurLoc))
      {
        $Candidates.Add((Join-Path (Join-Path $CurLoc 'lib') $ModuleName)) | Out-Null
      }
    }
    catch {}

    foreach ($Candidate in $Candidates)
    {
      if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate))
      {
        . $Candidate
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Candidate, [ref]$Tokens, [ref]$Errors)
        if ($null -ne $Ast -and $null -ne $Ast.EndBlock)
        {
          foreach ($Stmt in $Ast.EndBlock.Statements)
          {
            if ($Stmt -is [System.Management.Automation.Language.FunctionDefinitionAst])
            {
              $FnItem = Get-Item -LiteralPath "Function:\$($Stmt.Name)" -ErrorAction SilentlyContinue
              if ($null -ne $FnItem)
              {
                Set-Item -Path "Function:\script:$($Stmt.Name)" -Value $FnItem.ScriptBlock
              }
            }
          }
        }
        return
      }
    }
    if (-not $Optional)
    {
      throw "Required ContestSetup library module not found: lib/$ModuleName"
    }
  }
}

Import-ContestLibraryModule -ModuleName 'core-primitives.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'download-and-archive.ps1' -Optional
Import-ContestLibraryModule -ModuleName 'vscode-workspace.ps1'

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
  return ([string]$ConfiguredRoot).TrimEnd('\', '/')
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

function Get-PortableVSCodeDataDir
{
  return (Join-Path (Get-ContestRootPath) 'vscode\data')
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
  $ContestFallback = Join-Path (Get-ContestVSCodeRoot) 'bin\code.cmd'
  if (Test-Path -LiteralPath $ContestFallback) { return $ContestFallback }
  return $null
}

function Get-VSCodeExePath
{
  $Standalone = Join-Path (Get-ContestRootPath) 'vscode\Code.exe'
  if (Test-Path -LiteralPath $Standalone) { return $Standalone }
  $ContestFallback = Join-Path (Get-ContestVSCodeRoot) 'Code.exe'
  if (Test-Path -LiteralPath $ContestFallback) { return $ContestFallback }
  return $null
}

function Get-VSCodeProductJsonPath
{
  $VSCodeRoot = Join-Path (Get-ContestRootPath) 'vscode'
  $Resolved = Resolve-VSCodeProductJsonPath -VSCodeRoot $VSCodeRoot
  if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }
  return (Resolve-VSCodeProductJsonPath -VSCodeRoot (Get-ContestVSCodeRoot))
}

function Test-VSCodeStandaloneComplete
{
  return ($null -ne (Get-VSCodeCommandPath)) -and ($null -ne (Get-VSCodeExePath)) -and ($null -ne (Get-VSCodeProductJsonPath))
}

function Stop-VSCodeProcesses
{
  param([switch]$ContestOnly)
  Write-Host 'Closing VS Code processes if running...'
  $TargetRoot = Join-Path (Get-ContestRootPath) 'vscode'
  foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium'))
  {
    try
    {
      Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object {
        if (-not $ContestOnly) { return $true }
        try { $_.Path -and (Test-PathInside -ChildPath $_.Path -ParentPath $TargetRoot) } catch { $false }
      } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {}
  }
  Start-Sleep -Seconds 1
}

$Script:ContestVSCodeInitializedRoot = ''
$Script:InstalledVSCodeExtensionsCache = $null

function Initialize-ContestVSCodeIsolated
{
  $ContestRoot = Get-ContestVSCodeRoot
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir
  $StandaloneCodeExe = Get-VSCodeExePath
  $PortableDataDir = Get-PortableVSCodeDataDir

  $AlreadyReady = ($Script:ContestVSCodeInitializedRoot -ieq $ContestRoot) -and
                  (Test-Path -LiteralPath $UserDataDir) -and
                  (Test-Path -LiteralPath $ExtensionsDir) -and
                  (($null -eq $StandaloneCodeExe) -or (Test-Path -LiteralPath (Join-Path $PortableDataDir 'extensions')))
  if ($AlreadyReady)
  {
    return
  }

  Write-Section 'Prepare isolated VS Code for contest'

  New-Item -ItemType Directory -Force -Path $ContestRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null

  # Also create VS Code Portable Mode trap directory ($Root\vscode\data) once Code.exe exists so
  # launching Code.exe directly in File Explorer never loads %USERPROFILE%\.vscode\extensions or %APPDATA%\Code.
  if ($null -ne $StandaloneCodeExe)
  {
    New-Item -ItemType Directory -Force -Path (Join-Path $PortableDataDir 'user-data\User') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $PortableDataDir 'extensions') | Out-Null
  }

  $Script:ContestVSCodeInitializedRoot = $ContestRoot

  Write-Host 'Contest VS Code profile:' -ForegroundColor Green
  Write-Host "  User data:  $UserDataDir"
  Write-Host "  Extensions: $ExtensionsDir"
}

function Reset-VSCodeCompletely
{
  # Backward-compatible name: avoids touching %APPDATA%\Code, %LOCALAPPDATA%\Code, and %USERPROFILE%\.vscode.
  Initialize-ContestVSCodeIsolated
  Write-Host 'Existing VS Code installation/profile was left untouched.' -ForegroundColor Green
}

function Install-VSCodeStandalone
{
  Write-Section 'Install Standalone VS Code'
  if (Test-VSCodeStandaloneComplete)
  {
    Write-Host 'Standalone VS Code already installed and verified (Code.exe, code.cmd, product.json).' -ForegroundColor Green
    return
  }

  $ExtractPath = Join-Path (Get-ContestRootPath) 'vscode'
  if (Test-Path -LiteralPath $ExtractPath)
  {
    Write-Warning "Incomplete Standalone VS Code installation detected at $ExtractPath. Cleaning and re-extracting..."
    Stop-VSCodeProcesses -ContestOnly
    Remove-Item -LiteralPath $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  $VSCodeArchiveUrl = 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable'
  $VSCodeArchivePath = Join-Path (Get-ContestRootPath) 'downloads\vscode-win32-x64-archive.zip'

  Download-VerifiedFile -Url $VSCodeArchiveUrl -OutFile $VSCodeArchivePath -AllowedPublisherKeywords @() -MinValidBytes 50MB

  Write-Host "Extracting VS Code to $ExtractPath ..."
  Expand-ArchiveFast -ArchivePath $VSCodeArchivePath -DestinationPath $ExtractPath

  if (-not (Test-VSCodeStandaloneComplete))
  {
    throw 'Standalone VS Code extraction incomplete: Code.exe, bin\code.cmd, or product.json (resources\app\product.json or <commit>\resources\app\product.json) is missing.'
  }
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

function Get-AllowedVSCodeExtensions
{
  return @(
    'ms-ceintl.vscode-language-pack-ko',
    'ms-vscode.cpptools',
    'ms-vscode.cpptools-themes',
    'ms-vscode.cpptools-extension-pack',
    'ms-python.python',
    'ms-python.debugpy',
    'ms-python.vscode-pylance',
    'ms-python.vscode-python-envs'
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
    'amazonwebservices.amazon-q-vscode',
    'saoudrizwan.claude-dev',
    'rooveterinaryinc.roo-cline',
    'kilocode.kilo-code',
    'openai.chatgpt',
    'anthropic.claude-code',
    'google.geminicodeassist',
    'blackboxapp.blackbox',
    'twinnydotdev.twinny',
    'aminer.codegeex',
    'marscode.marscode-extension',
    'bito.bito'
  )
}

function Restore-VSCodeMarketplace
{
  $ProductPath = Get-VSCodeProductJsonPath
  if (-not $ProductPath) { return }

  $OrigBackupPath = "$ProductPath.contest-orig"
  $AltBackupPath = "$ProductPath.contest-backup"

  if (Test-Path -LiteralPath $OrigBackupPath)
  {
    Copy-Item -LiteralPath $OrigBackupPath -Destination $ProductPath -Force
    Write-Host "Restored original VS Code Marketplace configuration from $OrigBackupPath" -ForegroundColor Gray
    return
  }
  elseif (Test-Path -LiteralPath $AltBackupPath)
  {
    Copy-Item -LiteralPath $AltBackupPath -Destination $ProductPath -Force
    Copy-Item -LiteralPath $AltBackupPath -Destination $OrigBackupPath -Force
    return
  }

  try
  {
    $Content = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $ProductPath)
    if ($null -eq $Content) { return }
    $GalleryProp = $Content.PSObject.Properties['extensionsGallery']
    if ($null -ne $GalleryProp -and $null -ne $GalleryProp.Value)
    {
      $Gallery = $GalleryProp.Value
      $SvcProp = $Gallery.PSObject.Properties['serviceUrl']
      if ($null -ne $SvcProp -and ([string]$SvcProp.Value -match '127\.0\.0\.1'))
      {
        Set-ObjectProperty -Object $Gallery -Name 'serviceUrl' -Value 'https://marketplace.visualstudio.com/_apis/public/gallery'
        Set-ObjectProperty -Object $Gallery -Name 'itemUrl' -Value 'https://marketplace.visualstudio.com/items'
        if ($null -ne $Gallery.PSObject.Properties['cacheUrl'])
        {
          Set-ObjectProperty -Object $Gallery -Name 'cacheUrl' -Value 'https://vscode.blob.core.windows.net/gallery/index'
        }
        if ($null -ne $Gallery.PSObject.Properties['controlUrl'])
        {
          Set-ObjectProperty -Object $Gallery -Name 'controlUrl' -Value ''
        }
        Write-JsonUtf8NoBom -Path $ProductPath -InputObject $Content -Depth 15
        Copy-Item -LiteralPath $ProductPath -Destination $OrigBackupPath -Force
        Write-Host "Unlocked VS Code Marketplace in $ProductPath for extension installation." -ForegroundColor Gray
      }
      elseif (-not (Test-Path -LiteralPath $OrigBackupPath))
      {
        Copy-Item -LiteralPath $ProductPath -Destination $OrigBackupPath -Force
      }
    }
    elseif (-not (Test-Path -LiteralPath $OrigBackupPath))
    {
      Copy-Item -LiteralPath $ProductPath -Destination $OrigBackupPath -Force
    }
  }
  catch
  {
    Write-Warning "Failed to inspect/restore product.json before extension install: $($_.Exception.Message)"
  }
}

function Disable-VSCodeMarketplace
{
  Write-Section 'Disable VS Code Marketplace'
  $Path = Get-VSCodeProductJsonPath
  if (-not $Path)
  {
    throw 'Could not find VS Code product.json to disable the extension Marketplace.'
  }

  $OrigBackupPath = "$Path.contest-orig"
  $Content = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $Path)
  if ($null -eq $Content)
  {
    throw "Failed to parse VS Code product.json at $Path"
  }

  $GalleryProp = $Content.PSObject.Properties['extensionsGallery']
  if ($null -eq $GalleryProp -or $null -eq $GalleryProp.Value)
  {
    if (-not (Test-Path -LiteralPath $OrigBackupPath))
    {
      Copy-Item -LiteralPath $Path -Destination $OrigBackupPath -Force
    }
    Set-ObjectProperty -Object $Content -Name 'extensionsGallery' -Value ([pscustomobject]@{})
  }
  else
  {
    $ExistingSvcProp = $GalleryProp.Value.PSObject.Properties['serviceUrl']
    $ExistingSvcVal = if ($null -ne $ExistingSvcProp) { [string]$ExistingSvcProp.Value } else { '' }
    if ((-not (Test-Path -LiteralPath $OrigBackupPath)) -and ($ExistingSvcVal -notmatch '127\.0\.0\.1'))
    {
      Copy-Item -LiteralPath $Path -Destination $OrigBackupPath -Force
    }
  }

  $Gallery = $Content.extensionsGallery
  $GalleryEndpointsToLock = @(
    'serviceUrl',
    'cacheUrl',
    'itemUrl',
    'controlUrl',
    'resourceUrlTemplate',
    'extensionUrlTemplate',
    'nlsBaseUrl',
    'publisherUrl'
  )
  foreach ($EndpointName in $GalleryEndpointsToLock)
  {
    Set-ObjectProperty -Object $Gallery -Name $EndpointName -Value 'https://127.0.0.1'
  }
  foreach ($ExistingProp in @($Gallery.PSObject.Properties))
  {
    if ($null -ne $ExistingProp.Value -and ($ExistingProp.Value -is [string]) -and ([string]$ExistingProp.Value -match '^https?://'))
    {
      Set-ObjectProperty -Object $Gallery -Name $ExistingProp.Name -Value 'https://127.0.0.1'
    }
  }

  Write-JsonUtf8NoBom -Path $Path -InputObject $Content -Depth 15

  # Post-write verification: re-read and confirm extensionsGallery.serviceUrl & itemUrl are locked to https://127.0.0.1
  $VerifiedObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $Path)
  $VerifiedGalleryProp = if ($null -ne $VerifiedObj) { $VerifiedObj.PSObject.Properties['extensionsGallery'] } else { $null }
  $VerifiedSvcProp = if ($null -ne $VerifiedGalleryProp -and $null -ne $VerifiedGalleryProp.Value) { $VerifiedGalleryProp.Value.PSObject.Properties['serviceUrl'] } else { $null }
  $VerifiedItemProp = if ($null -ne $VerifiedGalleryProp -and $null -ne $VerifiedGalleryProp.Value) { $VerifiedGalleryProp.Value.PSObject.Properties['itemUrl'] } else { $null }
  if ($null -eq $VerifiedSvcProp -or ([string]$VerifiedSvcProp.Value -ne 'https://127.0.0.1') -or $null -eq $VerifiedItemProp -or ([string]$VerifiedItemProp.Value -ne 'https://127.0.0.1'))
  {
    throw "Marketplace lock verification failed in $Path (serviceUrl is not https://127.0.0.1)."
  }

  Write-Host "VS Code Marketplace locked and verified in $Path (backup at $OrigBackupPath)" -ForegroundColor Green
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
      $Raw = Read-TextUtf8 -Path $SettingsPath
      if (-not [string]::IsNullOrWhiteSpace($Raw))
      {
        $ParsedSettings = ConvertFrom-JsonSafe -Json $Raw
        if ($null -ne $ParsedSettings) { $Settings = $ParsedSettings }
      }
    }
    catch
    {
      Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak" -ErrorAction SilentlyContinue
      $Settings = [pscustomobject]@{}
    }
  }

  $CopilotEnable = [ordered]@{
    '*'       = $false
    plaintext = $false
    markdown  = $false
    scminput  = $false
    cpp       = $false
    c         = $false
    python    = $false
  }

  $SettingsToApply = [ordered]@{
    'locale'                                                            = 'ko'
    'workbench.startupEditor'                                           = 'none'
    'workbench.welcomePage.walkthroughs.openOnInstall'                  = $false
    'workbench.tips.enabled'                                            = $false
    'workbench.enableExperiments'                                       = $false
    'update.showReleaseNotes'                                           = $false
    'update.mode'                                                       = 'none'
    'telemetry.telemetryLevel'                                          = 'off'
    'window.commandCenter'                                              = $false
    'editor.inlineSuggest.enabled'                                      = $false
    'chat.commandCenter.enabled'                                        = $false
    'chat.disableAIFeatures'                                            = $true
    'chat.agent.enabled'                                                = $false
    'chat.edits.enabled'                                                = $false
    'chat.mcp.enabled'                                                  = $false
    'chat.detectParticipant.enabled'                                    = $false
    'chat.extensionUnification.enabled'                                 = $false
    'inlineChat.enabled'                                                = $false
    'inlineChat.accessibleDiffView'                                     = 'off'
    'workbench.commandPalette.experimental.enableNaturalLanguageSearch' = $false
    'workbench.settings.enableNaturalLanguageSearch'                    = $false
    'github.copilot.enable'                                             = $CopilotEnable
    'github.copilot.chat.enabled'                                       = $false
    'github.copilot.chat.agent.enabled'                                 = $false
    'github.copilot.chat.edits.enabled'                                 = $false
    'github.copilot.editor.enableAutoCompletions'                       = $false
    'github.copilot.nextEditSuggestions.enabled'                        = $false
    'github.copilot.inlineSuggest.enable'                               = $false
    'extensions.ignoreRecommendations'                                  = $true
    'extensions.showRecommendationsOnlyOnDemand'                        = $true
    'extensions.autoCheckUpdates'                                       = $false
    'extensions.autoUpdate'                                             = $false
    'python.terminal.activateEnvironment'                               = $false
  }

  $PythonExeValue = Get-ConfiguredValue -Name 'PythonExe' -DefaultValue $null
  if (-not [string]::IsNullOrWhiteSpace([string]$PythonExeValue))
  {
    $SettingsToApply['python.defaultInterpreterPath'] = [string]$PythonExeValue

    # Hide other global Python environments
    $SettingsToApply['python.locator'] = 'none'
    $SettingsToApply['python.experiments.optOutFrom'] = @('pythonDiscoveryModule')
    $SettingsToApply['python.globalModuleSearchPaths'] = @()
  }

  $PythonDirValue = if (-not [string]::IsNullOrWhiteSpace([string]$PythonExeValue)) { Split-Path -Path ([string]$PythonExeValue) -Parent } else { Join-Path (Get-ContestRootPath) 'Python310' }
  $ToolBinValue = Join-Path (Get-ContestRootPath) 'bin'
  $MsysRootValue = Get-ConfiguredValue -Name 'MsysRoot' -DefaultValue "$env:SystemDrive\msys64"
  $UcrtBinValue = Join-Path ([string]$MsysRootValue) 'ucrt64\bin'
  $MsysUsrBinValue = Join-Path ([string]$MsysRootValue) 'usr\bin'
  $SettingsToApply['terminal.integrated.env.windows'] = [ordered]@{
    Path = "$PythonDirValue;$UcrtBinValue;$MsysUsrBinValue;$ToolBinValue;`${env:Path}"
  }

  foreach ($Key in $SettingsToApply.Keys)
  {
    Set-ObjectProperty -Object $Settings -Name $Key -Value $SettingsToApply[$Key]
  }

  Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 30

  # Mirror hardened AI/locale settings into Portable Mode directory ($Root\vscode\data) so direct Code.exe launches are equally locked down
  if ($null -ne (Get-VSCodeExePath))
  {
    $PortableSettingsPath = Join-Path (Get-PortableVSCodeDataDir) 'user-data\User\settings.json'
    Write-JsonUtf8NoBom -Path $PortableSettingsPath -InputObject $Settings -Depth 30
  }

  Write-Host "Contest VS Code settings applied: $SettingsPath" -ForegroundColor Green
}

function Set-VSCodeDisplayLanguageKorean
{
  Write-Section 'Set VS Code display language to Korean'

  $SettingsPath = Get-ContestVSCodeSettingsPath
  if (-not (Test-Path -LiteralPath $SettingsPath))
  {
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath -Parent) | Out-Null
    $Settings = [pscustomobject]@{ locale = 'ko' }
    Write-JsonUtf8NoBom -Path $SettingsPath -InputObject $Settings -Depth 10
  }

  # Set Korean locale via argv.json in BOTH contest user-data and portable vscode\data
  $ArgvTargets = @((Join-Path (Get-ContestVSCodeUserDataDir) 'argv.json'))
  if ($null -ne (Get-VSCodeExePath))
  {
    $ArgvTargets += (Join-Path (Get-PortableVSCodeDataDir) 'argv.json')
  }

  foreach ($ArgvPath in $ArgvTargets)
  {
    $ArgvObj = [pscustomobject]@{}
    if (Test-Path -LiteralPath $ArgvPath)
    {
      try
      {
        $Content = Read-TextUtf8 -Path $ArgvPath
        if (-not [string]::IsNullOrWhiteSpace($Content))
        {
          $ParsedArgv = ConvertFrom-JsonSafe -Json $Content
          if ($null -ne $ParsedArgv) { $ArgvObj = $ParsedArgv }
        }
      }
      catch { $ArgvObj = [pscustomobject]@{} }
    }
    Set-ObjectProperty -Object $ArgvObj -Name 'locale' -Value 'ko'
    Write-JsonUtf8NoBom -Path $ArgvPath -InputObject $ArgvObj -Depth 10
  }

  Write-Host "VS Code locale set to Korean (ko) via argv.json ($($ArgvTargets -join ', '))" -ForegroundColor Green
}

function Get-ContestVSCodeShortcutArguments
{
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir
  $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
  return "--locale ko --user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`" `"$ContestWorkspace`""
}

function Test-ContestVSCodeShortcut
{
  param([Parameter(Mandatory = $true)] [object]$Shortcut, [Parameter(Mandatory = $true)] [string]$CodeExe)
  $UserDataDir = Get-ContestVSCodeUserDataDir
  $ExtensionsDir = Get-ContestVSCodeExtensionsDir
  $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
  $ExpectedArgs = Get-ContestVSCodeShortcutArguments
  $LegacyExpectedArgs = "--user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`" `"$ContestWorkspace`""
  return (
    ([string]$Shortcut.TargetPath) -ieq ([string]$CodeExe) -and
    (([string]$Shortcut.Arguments) -eq $ExpectedArgs -or ([string]$Shortcut.Arguments) -eq $LegacyExpectedArgs)
  )
}

function Get-InstalledContestVSCodeExtensions
{
  param([switch]$Refresh)
  if ((-not $Refresh) -and ($null -ne $Script:InstalledVSCodeExtensionsCache))
  {
    return @($Script:InstalledVSCodeExtensionsCache)
  }

  $CodeCmd = Get-VSCodeCommandPath
  if (-not $CodeCmd) { return @() }

  $Output = @()
  try
  {
    $Output = @(Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--list-extensions')) -Quiet).Output
  }
  catch
  {
    return @()
  }
  $NormalizedList = @($Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -and ($_ -match '^[a-z0-9-]+(\.[a-z0-9-]+)+$') })
  $Script:InstalledVSCodeExtensionsCache = $NormalizedList
  return @($NormalizedList)
}

function Remove-BlockedVSCodeExtensions
{
  Write-Section 'Enforce strict VS Code extension allowlist & remove blocked extensions'

  $CodeCmd = Get-VSCodeCommandPath
  if (-not $CodeCmd) { return }

  $AllowedSet = @((Get-AllowedVSCodeExtensions) | ForEach-Object { $_.ToLowerInvariant() })
  $BlockedSet = @((Get-BlockedVSCodeExtensions) | ForEach-Object { $_.ToLowerInvariant() })

  $Installed = @(Get-InstalledContestVSCodeExtensions)
  $ToUninstall = @($Installed | Where-Object { ($BlockedSet -contains $_) -or ($AllowedSet -notcontains $_) } | Select-Object -Unique)

  foreach ($ExtId in $ToUninstall)
  {
    Write-Host "Removing non-allowlisted/blocked extension from contest profile: $ExtId" -ForegroundColor Yellow
    try
    {
      Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--uninstall-extension', $ExtId)) | Out-Null
    }
    catch {}
    $Script:InstalledVSCodeExtensionsCache = $null
  }

  # Also purge any sideloaded non-allowlisted extension folders directly from contest & portable extensions directories
  $ExtDirsToSweep = @((Get-ContestVSCodeExtensionsDir))
  if ($null -ne (Get-VSCodeExePath))
  {
    $ExtDirsToSweep += (Join-Path (Get-PortableVSCodeDataDir) 'extensions')
  }
  foreach ($SweepDir in $ExtDirsToSweep)
  {
    if (-not (Test-Path -LiteralPath $SweepDir)) { continue }
    foreach ($SubFolder in @(Get-ChildItem -LiteralPath $SweepDir -Directory -ErrorAction SilentlyContinue))
    {
      $LowerDir = $SubFolder.Name.ToLowerInvariant()
      if ($LowerDir.StartsWith('.')) { continue }
      $IsAllowedDir = $false
      foreach ($AllowedId in $AllowedSet)
      {
        if (($LowerDir -eq $AllowedId) -or $LowerDir.StartsWith("$AllowedId-"))
        {
          $IsAllowedDir = $true
          break
        }
      }
      if (-not $IsAllowedDir)
      {
        Write-Host "Purging unauthorized extension directory: $($SubFolder.FullName)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $SubFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $Script:InstalledVSCodeExtensionsCache = $null
      }
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
    throw ('Required VS Code extensions are missing in contest profile: ' + ($Missing -join ', '))
  }
  else
  {
    Write-Host 'All required extensions are installed in the contest profile.' -ForegroundColor Green
  }
}

function Seed-VSCodeExtensionsFromCacheDir
{
  param([Parameter(Mandatory = $true)] [string]$CodeCmd)
  $ConfiguredCache = [string](Get-ConfiguredValue -Name 'CacheDir' -DefaultValue '')
  if ([string]::IsNullOrWhiteSpace($ConfiguredCache) -or (-not (Test-Path -LiteralPath $ConfiguredCache)))
  {
    return $false
  }

  $Seeded = $false
  $ExtDestDir = Get-ContestVSCodeExtensionsDir
  $CachedExtFolder = Join-Path $ConfiguredCache 'vscode-extensions'
  if (Test-Path -LiteralPath $CachedExtFolder)
  {
    $CachedSubDirs = @(Get-ChildItem -LiteralPath $CachedExtFolder -Directory -ErrorAction SilentlyContinue)
    if ($CachedSubDirs.Count -gt 0)
    {
      Write-Host "Seeding pre-extracted VS Code extensions from CacheDir: $CachedExtFolder" -ForegroundColor Cyan
      New-Item -ItemType Directory -Force -Path $ExtDestDir | Out-Null
      & robocopy.exe $CachedExtFolder $ExtDestDir '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' '/MT:16' | Out-Null
      if ($LASTEXITCODE -lt 8)
      {
        $Seeded = $true
        $Script:InstalledVSCodeExtensionsCache = $null
      }
    }
  }

  $VsixDirs = @($ConfiguredCache, (Join-Path $ConfiguredCache 'vsix'))
  foreach ($VsixSearchDir in $VsixDirs)
  {
    if (-not (Test-Path -LiteralPath $VsixSearchDir)) { continue }
    foreach ($VsixFile in @(Get-ChildItem -Path $VsixSearchDir -Filter '*.vsix' -File -ErrorAction SilentlyContinue))
    {
      Write-Host "Installing cached VSIX from CacheDir: $($VsixFile.FullName)" -ForegroundColor Cyan
      $VsixRes = Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--install-extension', $VsixFile.FullName)) -Quiet
      if ($VsixRes.ExitCode -eq 0)
      {
        $Seeded = $true
        $Script:InstalledVSCodeExtensionsCache = $null
      }
    }
  }

  return $Seeded
}

function Install-VSCodeExtensions
{
  Write-Section 'Install VS Code extensions into contest profile'

  $CodeCmd = $null
  $WaitCount = 0
  while (-not $CodeCmd -and $WaitCount -lt 30)
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

  $ForceExtUpdate = [bool](Get-ConfiguredValue -Name 'ForceUpdate' -DefaultValue $false)
  $RequiredExtensions = @(Get-RequiredVSCodeExtensions)
  $Installed = @(Get-InstalledContestVSCodeExtensions -Refresh)
  $Missing = @($RequiredExtensions | Where-Object { $Installed -notcontains $_.ToLowerInvariant() })

  if (($Missing.Count -gt 0) -and (-not $ForceExtUpdate))
  {
    if (Seed-VSCodeExtensionsFromCacheDir -CodeCmd $CodeCmd)
    {
      $Installed = @(Get-InstalledContestVSCodeExtensions -Refresh)
      $Missing = @($RequiredExtensions | Where-Object { $Installed -notcontains $_.ToLowerInvariant() })
    }
  }

  if (($Missing.Count -eq 0) -and (-not $ForceExtUpdate))
  {
    Write-Host 'All required VS Code extensions are already installed in the contest profile. Skipping download.' -ForegroundColor Green
    return
  }

  # Unlock product.json Marketplace before installing any missing extensions
  Restore-VSCodeMarketplace

  $ExtensionsToInstall = @(if ($ForceExtUpdate) { $RequiredExtensions } else { $Missing })
  Write-Host ("Installing {0} VS Code extension(s) in batch: {1}" -f $ExtensionsToInstall.Count, ($ExtensionsToInstall -join ', ')) -ForegroundColor Cyan

  $BatchExtArgs = @()
  foreach ($Ext in $ExtensionsToInstall)
  {
    $BatchExtArgs += @('--install-extension', $Ext)
  }
  if ($ForceExtUpdate) { $BatchExtArgs += '--force' }

  $BatchSucceeded = $false
  try
  {
    Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs $BatchExtArgs) | Out-Null
    $BatchSucceeded = $true
    $Script:InstalledVSCodeExtensionsCache = $null
  }
  catch
  {
    $Script:InstalledVSCodeExtensionsCache = $null
    Write-Warning "Batched extension installation failed ($($_.Exception.Message)). Falling back to per-extension retry..."
  }

  if (-not $BatchSucceeded)
  {
    $InstalledAfterBatch = @(Get-InstalledContestVSCodeExtensions -Refresh)
    foreach ($Extension in $ExtensionsToInstall)
    {
      if ((-not $ForceExtUpdate) -and ($InstalledAfterBatch -contains $Extension.ToLowerInvariant()))
      {
        continue
      }
      Write-Host "Installing into contest profile: $Extension"
      $InstallSuccess = $false
      for ($Attempt = 1; $Attempt -le 3; $Attempt++)
      {
        try
        {
          $SingleArgs = @('--install-extension', $Extension)
          if ($ForceExtUpdate) { $SingleArgs += '--force' }
          Invoke-NativeChecked -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs $SingleArgs) | Out-Null
          $InstallSuccess = $true
          $Script:InstalledVSCodeExtensionsCache = $null
          break
        }
        catch
        {
          Write-Warning "Attempt $Attempt failed to install $Extension. Retrying in 2 seconds..."
          Start-Sleep -Seconds 2
        }
      }
      if (-not $InstallSuccess)
      {
        throw "Failed to install required VS Code extension '$Extension' after 3 attempts."
      }
    }
  }
}

Write-Section 'Setup VS Code'

$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] VS Code Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Checking Standalone Installation...' -PercentComplete 10
if (-not (Test-VSCodeStandaloneComplete))
{
  Install-VSCodeStandalone
}
else
{
  Write-Host 'Standalone VS Code is already installed and verified.' -ForegroundColor Green
}

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Initializing Profile...' -PercentComplete 25
Initialize-ContestVSCodeIsolated

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Installing Extensions...' -PercentComplete 40
Install-VSCodeExtensions
Remove-BlockedVSCodeExtensions

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Configuring Settings & Shortcuts...' -PercentComplete 60
Set-VSCodeAiHiddenSettings
Set-VSCodeDisplayLanguageKorean
Set-ContestVSCodeShortcut

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Creating Wrappers & Workspace Configs...' -PercentComplete 75
New-ContestVSCodeLauncher
New-ContestVSCodeCliWrapper
Set-ContestVSCodeWorkspaceDefaults

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Locking Extension Marketplace...' -PercentComplete 90
Disable-VSCodeMarketplace

Warn-IfRequiredVSCodeExtensionsMissing

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
