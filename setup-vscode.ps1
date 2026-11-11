# setup-vscode.ps1
# ContestSetup v2.0 -- Isolated Portable VS Code, Batched Idempotent Extensions, Marketplace Backup/Lock & C++ IntelliSense
# - Keeps the user's normal VS Code installation and profile intact.
# - Uses an isolated user-data-dir and extensions-dir under $Root\vscode-contest (plus portable $Root\vscode\data).
# - Replaces existing VS Code .lnk shortcuts so they launch the isolated contest profile in Korean (--locale ko).

if (-not (Get-Command Read-TextUtf8 -ErrorAction SilentlyContinue))
{
  function Read-TextUtf8
  {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  }
}

if (-not (Get-Command Read-LinesUtf8 -ErrorAction SilentlyContinue))
{
  function Read-LinesUtf8
  {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
  }
}

if (-not (Get-Command Strip-JsonComments -ErrorAction SilentlyContinue))
{
  function Strip-JsonComments
  {
    param([AllowNull()] [AllowEmptyString()] [string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    $Text = $Json.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $Out = New-Object System.Text.StringBuilder ($Text.Length)
    $InStr = $false
    $I = 0
    $N = $Text.Length
    while ($I -lt $N)
    {
      $C = $Text[$I]
      if ($InStr)
      {
        [void]$Out.Append($C)
        if ($C -eq '\' -and ($I + 1) -lt $N) { [void]$Out.Append($Text[$I + 1]); $I += 2; continue }
        if ($C -eq '"') { $InStr = $false }
        $I++; continue
      }
      if ($C -eq '"') { $InStr = $true; [void]$Out.Append($C); $I++; continue }
      if ($C -eq '/' -and ($I + 1) -lt $N -and $Text[$I + 1] -eq '/')
      {
        $I += 2
        while ($I -lt $N -and $Text[$I] -ne "`n" -and $Text[$I] -ne "`r") { $I++ }
        continue
      }
      if ($C -eq '/' -and ($I + 1) -lt $N -and $Text[$I + 1] -eq '*')
      {
        $I += 2
        while ($I -lt $N) { if ($Text[$I] -eq '*' -and ($I + 1) -lt $N -and $Text[$I + 1] -eq '/') { $I += 2; break }; $I++ }
        continue
      }
      [void]$Out.Append($C)
      $I++
    }
    $Pass1 = $Out.ToString()
    $Clean = New-Object System.Text.StringBuilder ($Pass1.Length)
    $InStr = $false
    $I = 0
    $N = $Pass1.Length
    while ($I -lt $N)
    {
      $C = $Pass1[$I]
      if ($InStr)
      {
        [void]$Clean.Append($C)
        if ($C -eq '\' -and ($I + 1) -lt $N) { [void]$Clean.Append($Pass1[$I + 1]); $I += 2; continue }
        if ($C -eq '"') { $InStr = $false }
        $I++; continue
      }
      if ($C -eq '"') { $InStr = $true; [void]$Clean.Append($C); $I++; continue }
      if ($C -eq ',')
      {
        $K = $I + 1
        while ($K -lt $N -and ($Pass1[$K] -eq ' ' -or $Pass1[$K] -eq "`t" -or $Pass1[$K] -eq "`r" -or $Pass1[$K] -eq "`n")) { $K++ }
        if ($K -lt $N -and ($Pass1[$K] -eq ([char]125) -or $Pass1[$K] -eq ']')) { $I++; continue }
      }
      [void]$Clean.Append($C)
      $I++
    }
    return $Clean.ToString()
  }
}

if (-not (Get-Command ConvertFrom-JsonSafe -ErrorAction SilentlyContinue))
{
  function ConvertFrom-JsonSafe
  {
    param([Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    $Clean = (Strip-JsonComments -Json $Json).Trim()
    if ([string]::IsNullOrWhiteSpace($Clean)) { return $null }
    return (ConvertFrom-Json -InputObject $Clean -ErrorAction Stop)
  }
}

if (-not (Get-Command ConvertFrom-JsonArray -ErrorAction SilentlyContinue))
{
  function ConvertFrom-JsonArray
  {
    param([Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    $Parsed = ConvertFrom-JsonSafe -Json $Json
    if ($null -eq $Parsed) { return @() }
    if ($Parsed -is [System.Array]) { return $Parsed }
    return @($Parsed)
  }
}

if (-not (Get-Command Set-ObjectProperty -ErrorAction SilentlyContinue))
{
  function Set-ObjectProperty
  {
    param([object]$Object, [string]$Name, [AllowNull()] [object]$Value)
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -ne $Property)
    {
      $Property.Value = $Value
    }
    else
    {
      Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
  }
}

if (-not (Get-Command Test-PathInside -ErrorAction SilentlyContinue))
{
  function Test-PathInside
  {
    param([string]$ChildPath, [string]$ParentPath)
    if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath)) { return $false }
    $ChildNorm = ($ChildPath -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
    $ParentNorm = ($ParentPath -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
    return ($ChildNorm -eq $ParentNorm) -or $ChildNorm.StartsWith("$ParentNorm\", [System.StringComparison]::OrdinalIgnoreCase)
  }
}

if (-not (Get-Command Expand-ArchiveFast -ErrorAction SilentlyContinue))
{
  function Expand-ArchiveFast
  {
    param([Parameter(Mandatory = $true)] [string]$ArchivePath, [Parameter(Mandatory = $true)] [string]$DestinationPath)
    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
  }
}

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
  return $null
}

function Get-VSCodeExePath
{
  $Standalone = Join-Path (Get-ContestRootPath) 'vscode\Code.exe'
  if (Test-Path -LiteralPath $Standalone) { return $Standalone }
  return $null
}

function Get-VSCodeProductJsonPath
{
  $VSCodeRoot = Join-Path (Get-ContestRootPath) 'vscode'
  if (Get-Command Resolve-VSCodeProductJsonPath -ErrorAction SilentlyContinue)
  {
    return (Resolve-VSCodeProductJsonPath -VSCodeRoot $VSCodeRoot)
  }
  if (-not (Test-Path -LiteralPath $VSCodeRoot))
  {
    return $null
  }

  $LegacyFlat = Join-Path $VSCodeRoot 'resources\app\product.json'
  if (Test-Path -LiteralPath $LegacyFlat) { return $LegacyFlat }

  $CodeCmdFile = Join-Path $VSCodeRoot 'bin\code.cmd'
  if (Test-Path -LiteralPath $CodeCmdFile)
  {
    try
    {
      $CmdText = Read-TextUtf8 -Path $CodeCmdFile
      if (-not [string]::IsNullOrWhiteSpace($CmdText))
      {
        $CliMatch = [regex]::Match($CmdText, '(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js')
        if ($CliMatch.Success)
        {
          $RefSubDir = $CliMatch.Groups[1].Value
          $RefProductJson = Join-Path (Join-Path $VSCodeRoot $RefSubDir) 'resources\app\product.json'
          if (Test-Path -LiteralPath $RefProductJson) { return $RefProductJson }
        }
      }
    }
    catch {}
  }

  $ExcludedChildNames = @('data', 'bin', 'tools', 'policies', 'appx')
  foreach ($ChildDir in @(Get-ChildItem -LiteralPath $VSCodeRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending))
  {
    if ($ExcludedChildNames -contains $ChildDir.Name.ToLowerInvariant()) { continue }
    $CandidateProductJson = Join-Path $ChildDir.FullName 'resources\app\product.json'
    if (Test-Path -LiteralPath $CandidateProductJson) { return $CandidateProductJson }
  }

  $RootProductJson = Join-Path $VSCodeRoot 'product.json'
  if (Test-Path -LiteralPath $RootProductJson) { return $RootProductJson }

  return $null
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

function Read-VSCodeShortcutManifest
{
  param([Parameter(Mandatory = $true)] [string]$ManifestPath)
  if (-not (Test-Path -LiteralPath $ManifestPath)) { return @() }
  try
  {
    $Raw = Read-TextUtf8 -Path $ManifestPath
    $ParsedItems = @(ConvertFrom-JsonArray -Json $Raw)
    if ($ParsedItems.Count -eq 0) { return @() }
    return $ParsedItems
  }
  catch
  {
    return @()
  }
}

function Write-VSCodeShortcutManifest
{
  param(
    [Parameter(Mandatory = $true)] [string]$ManifestPath,
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Manifest
  )
  $Deduped = @(
    $Manifest |
      Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['ShortcutPath'] -and (-not [string]::IsNullOrWhiteSpace([string]$_.ShortcutPath)) } |
      Group-Object -Property ShortcutPath |
      ForEach-Object { $_.Group | Select-Object -Last 1 }
  )
  Write-JsonUtf8NoBom -Path $ManifestPath -InputObject $Deduped -Depth 10
}

function Get-VSCodeShortcutManifestItem
{
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Manifest,
    [Parameter(Mandatory = $true)] [string]$ShortcutPath
  )
  $MatchesList = @(
    $Manifest |
      Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['ShortcutPath'] -and ([string]$_.ShortcutPath) -ieq $ShortcutPath }
  )
  if ($MatchesList.Count -gt 0) { return $MatchesList[0] }
  return $null
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

  $Output = @(Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--list-extensions')) -Quiet).Output
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
    Invoke-NativeCommand -FilePath $CodeCmd -ArgumentList (Get-ContestVSCodeCliArgs @('--uninstall-extension', $ExtId)) | Out-Null
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

function Convert-PathToSafeFileName
{
  param([string]$Path)
  $Safe = [string]$Path
  $Safe = $Safe -replace ':', ''
  $Safe = $Safe -replace '[\\/*?"<>|]', '_'
  $Safe = $Safe -replace '\s+', '_'
  return $Safe
}

function Get-TargetStudentShortcutFolders
{
  $TargetDesktop = ''
  $TargetStartMenu = ''
  $TargetTaskbarPinned = ''
  $IsSystemOrCrossUser = $false

  if (Get-Command Resolve-ContestTargetUser -ErrorAction SilentlyContinue)
  {
    try
    {
      $TargetUser = Resolve-ContestTargetUser
      if ($TargetUser.IsSystem)
      {
        $IsSystemOrCrossUser = $true
      }
      elseif (-not [string]::IsNullOrWhiteSpace($TargetUser.ProfilePath) -and (Test-Path -LiteralPath $TargetUser.ProfilePath))
      {
        $CurrentSid = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
        if ($CurrentSid -ne $TargetUser.Sid) { $IsSystemOrCrossUser = $true }
        $ProfDesktop = Join-Path $TargetUser.ProfilePath 'Desktop'
        $ProfStartMenu = Join-Path $TargetUser.ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu'
        $ProfTaskbar = Join-Path $TargetUser.ProfilePath 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
        $TargetDesktop = $ProfDesktop
        $TargetStartMenu = $ProfStartMenu
        $TargetTaskbarPinned = $ProfTaskbar
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($TargetDesktop) -and (-not $IsSystemOrCrossUser))
  {
    $TargetDesktop = [Environment]::GetFolderPath('Desktop')
  }
  if ([string]::IsNullOrWhiteSpace($TargetStartMenu) -and (-not $IsSystemOrCrossUser))
  {
    $TargetStartMenu = [Environment]::GetFolderPath('StartMenu')
  }
  if ([string]::IsNullOrWhiteSpace($TargetTaskbarPinned) -and (-not [string]::IsNullOrWhiteSpace($env:APPDATA)))
  {
    $TargetTaskbarPinned = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
  }

  return [pscustomobject]@{
    Desktop             = $TargetDesktop
    StartMenu           = $TargetStartMenu
    TaskbarPinned       = $TargetTaskbarPinned
    CommonDesktop       = [Environment]::GetFolderPath('CommonDesktopDirectory')
    CommonStartMenu     = [Environment]::GetFolderPath('CommonStartMenu')
    IsSystemOrCrossUser = $IsSystemOrCrossUser
  }
}

function Get-StandardVSCodeShortcutCandidates
{
  $Folders = Get-TargetStudentShortcutFolders
  $Candidates = @()

  if (-not [string]::IsNullOrWhiteSpace($Folders.Desktop)) { $Candidates += (Join-Path $Folders.Desktop 'Visual Studio Code.lnk') }
  if (-not [string]::IsNullOrWhiteSpace($Folders.CommonDesktop)) { $Candidates += (Join-Path $Folders.CommonDesktop 'Visual Studio Code.lnk') }
  if (-not [string]::IsNullOrWhiteSpace($Folders.StartMenu)) { $Candidates += (Join-Path $Folders.StartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk') }
  if (-not [string]::IsNullOrWhiteSpace($Folders.CommonStartMenu)) { $Candidates += (Join-Path $Folders.CommonStartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk') }
  if (-not [string]::IsNullOrWhiteSpace($Folders.TaskbarPinned)) { $Candidates += (Join-Path $Folders.TaskbarPinned 'Visual Studio Code.lnk') }

  return @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-VSCodeShortcutTargets
{
  $Folders = Get-TargetStudentShortcutFolders
  $Candidates = @(Get-StandardVSCodeShortcutCandidates)
  $Existing = @($Candidates | Where-Object { Test-Path -LiteralPath $_ })

  $Targets = @()
  $Targets += $Existing
  if (-not [string]::IsNullOrWhiteSpace($Folders.Desktop))
  {
    $Targets += (Join-Path $Folders.Desktop 'Visual Studio Code.lnk')
  }
  if ($Folders.IsSystemOrCrossUser -and (-not [string]::IsNullOrWhiteSpace($Folders.CommonDesktop)))
  {
    $Targets += (Join-Path $Folders.CommonDesktop 'Visual Studio Code.lnk')
  }
  if ($Existing.Count -eq 0)
  {
    if (-not [string]::IsNullOrWhiteSpace($Folders.StartMenu))
    {
      $Targets += (Join-Path $Folders.StartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Folders.CommonStartMenu))
    {
      $Targets += (Join-Path $Folders.CommonStartMenu 'Programs\Visual Studio Code\Visual Studio Code.lnk')
    }
  }

  return @($Targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Set-ContestVSCodeShortcut
{
  Write-Section 'Replace VS Code shortcuts with contest launcher'

  $CodeExe = Get-VSCodeExePath
  if (-not $CodeExe) { throw 'Could not find Code.exe for Visual Studio Code.' }

  $ContestRoot = Get-ContestVSCodeRoot
  $ManifestPath = Join-Path $ContestRoot 'shortcut-manifest.json'

  Initialize-ContestVSCodeIsolated

  $ShortcutBackupRootFile = Join-Path $ContestRoot 'shortcut-backup-root.txt'
  $ShortcutBackupRoot = ''
  if (Test-Path -LiteralPath $ShortcutBackupRootFile)
  {
    try
    {
      $ShortcutBackupRoot = [string]((Read-LinesUtf8 -Path $ShortcutBackupRootFile) | Select-Object -First 1)
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace([string]$ShortcutBackupRoot))
  {
    $ShortcutBackupRoot = Join-Path (Get-ContestBackupRootPath) ('vscode-shortcuts-' + (Get-ContestTimeStamp))
  }
  New-Item -ItemType Directory -Force -Path $ShortcutBackupRoot | Out-Null

  $Shell = New-Object -ComObject WScript.Shell
  try
  {
    $Manifest = @(Read-VSCodeShortcutManifest -ManifestPath $ManifestPath)
    $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
    New-Item -ItemType Directory -Force -Path $ContestWorkspace | Out-Null
    $ShortcutArguments = Get-ContestVSCodeShortcutArguments

    foreach ($ShortcutPath in Get-VSCodeShortcutTargets)
    {
      try
      {
        $ShortcutDir = Split-Path -Path $ShortcutPath -Parent
        New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null

        $Existed = Test-Path -LiteralPath $ShortcutPath
        $BackupName = (Convert-PathToSafeFileName $ShortcutPath) + '.bak.lnk'
        $DefaultBackupPath = Join-Path $ShortcutBackupRoot $BackupName
        $BackupPath = $null
        $ManifestItem = Get-VSCodeShortcutManifestItem -Manifest $Manifest -ShortcutPath $ShortcutPath

        if ($ManifestItem)
        {
          # Preserve original Existed and BackupPath recorded on first run
          $ExistedProp = $ManifestItem.PSObject.Properties['Existed']
          $BackupPathProp = $ManifestItem.PSObject.Properties['BackupPath']
          $Existed = if ($null -ne $ExistedProp) { [bool]$ExistedProp.Value } else { $false }
          $BackupPath = if ($null -ne $BackupPathProp) { [string]$BackupPathProp.Value } else { '' }
          if ($Existed -and [string]::IsNullOrWhiteSpace($BackupPath) -and (Test-Path -LiteralPath $DefaultBackupPath))
          {
            $BackupPath = $DefaultBackupPath
          }
        }
        elseif ($Existed)
        {
          $ExistingShortcut = $Shell.CreateShortcut($ShortcutPath)
          if (-not (Test-ContestVSCodeShortcut -Shortcut $ExistingShortcut -CodeExe $CodeExe))
          {
            $BackupPath = $DefaultBackupPath
            if (-not (Test-Path -LiteralPath $BackupPath))
            {
              Copy-Item -LiteralPath $ShortcutPath -Destination $BackupPath -Force
            }
          }
          elseif (Test-Path -LiteralPath $DefaultBackupPath)
          {
            # Shortcut was already converted in a prior run and its backup file exists on disk
            $Existed = $true
            $BackupPath = $DefaultBackupPath
          }
          else
          {
            $Existed = $false
          }
        }

        $Shortcut = $Shell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $CodeExe
        $Shortcut.Arguments = $ShortcutArguments
        $Shortcut.WorkingDirectory = $ContestWorkspace
        $Shortcut.IconLocation = "$CodeExe,0"
        $Shortcut.Description = 'Contest isolated Visual Studio Code'
        $Shortcut.Save()

        if (-not $ManifestItem)
        {
          $Manifest += [pscustomobject]@{
            ShortcutPath = $ShortcutPath
            Existed      = $Existed
            BackupPath   = $BackupPath
          }
        }

        Write-Host "Updated shortcut: $ShortcutPath" -ForegroundColor Green
      }
      catch
      {
        Write-Warning "Failed to update shortcut: $ShortcutPath - $($_.Exception.Message)"
      }
    }

    Write-VSCodeShortcutManifest -ManifestPath $ManifestPath -Manifest $Manifest
    Write-LinesUtf8NoBom -Path (Join-Path $ContestRoot 'shortcut-backup-root.txt') -Lines @($ShortcutBackupRoot)

    Write-Host "Shortcut manifest: $ManifestPath" -ForegroundColor Green
  }
  finally
  {
    if ($null -ne $Shell)
    {
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Shell) } catch {}
    }
  }
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

  $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
  New-Item -ItemType Directory -Force -Path $ContestWorkspace | Out-Null

  $EscapedWorkspace = $ContestWorkspace -replace "'", "''"
  $EscapedCodeExe = $CodeExe -replace "'", "''"
  $EscapedUserData = $UserDataDir -replace "'", "''"
  $EscapedExtensions = $ExtensionsDir -replace "'", "''"

  $LauncherLines = @(
    'param(',
    "  [string]`$Path = '$EscapedWorkspace'",
    ')',
    '',
    "`$CodeExe = '$EscapedCodeExe'",
    "`$UserDataDir = '$EscapedUserData'",
    "`$ExtensionsDir = '$EscapedExtensions'",
    '',
    '& $CodeExe --locale ko --user-data-dir $UserDataDir --extensions-dir $ExtensionsDir $Path'
  )

  Write-LinesUtf8NoBom -Path $LauncherPath -Lines ([string[]]$LauncherLines)
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

  $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
  New-Item -ItemType Directory -Force -Path $ContestWorkspace | Out-Null

  # Avoid cmd.exe parenthesized ( ... ) blocks around %* so paths containing ')' never break command parsing
  $WrapperLines = @(
    '@echo off',
    '@setlocal',
    'if "%~1"=="" goto :contest_default',
    "`"$CodeCmd`" --locale ko --user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`" %*",
    'exit /b %ERRORLEVEL%',
    ':contest_default',
    "`"$CodeCmd`" --locale ko --user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`" `"$ContestWorkspace`"",
    'exit /b %ERRORLEVEL%'
  )

  Write-LinesUtf8NoBom -Path $WrapperPath -Lines ([string[]]$WrapperLines)
  Write-Host "Contest code.cmd wrapper created: $WrapperPath" -ForegroundColor Green
}

function Set-ContestVSCodeWorkspaceDefaults
{
  Write-Section 'Create contest VS Code workspace configurations (tasks, c_cpp_properties, launch)'

  $ContestWorkspace = Join-Path (Get-ContestRootPath) 'contest'
  $VSCodeDir = Join-Path $ContestWorkspace '.vscode'
  New-Item -ItemType Directory -Force -Path $VSCodeDir | Out-Null

  $MsysRootValue = Get-ConfiguredValue -Name 'MsysRoot' -DefaultValue "$env:SystemDrive\msys64"
  $UcrtBinValue = Join-Path ([string]$MsysRootValue) 'ucrt64\bin'
  $MsysUsrBinValue = Join-Path ([string]$MsysRootValue) 'usr\bin'
  $GppExeValue = Join-Path $UcrtBinValue 'g++.exe'
  $GdbExeValue = Join-Path $UcrtBinValue 'gdb.exe'
  $GppForward = Convert-ToForwardSlashPath $GppExeValue
  $GdbForward = Convert-ToForwardSlashPath $GdbExeValue

  $Tasks = [ordered]@{
    version = '2.0.0'
    tasks   = @(
      [ordered]@{
        label          = 'Build C++17'
        type           = 'process'
        command        = $GppExeValue
        args           = @(
          '-std=gnu++17',
          '-O2',
          '-Wall',
          '-Wextra',
          '-g',
          '${file}',
          '-o',
          '${fileDirname}\${fileBasenameNoExtension}.exe'
        )
        options        = [ordered]@{
          cwd = '${fileDirname}'
          env = [ordered]@{
            Path = "$UcrtBinValue;$MsysUsrBinValue;`${env:Path}"
          }
        }
        group          = [ordered]@{
          kind      = 'build'
          isDefault = $true
        }
        problemMatcher = @('$gcc')
      }
    )
  }

  $CppProperties = [ordered]@{
    configurations = @(
      [ordered]@{
        name             = 'Win32'
        includePath      = @('${workspaceFolder}/**')
        defines          = @('_DEBUG', 'UNICODE', '_UNICODE')
        compilerPath     = $GppForward
        cStandard        = 'c17'
        cppStandard      = 'c++17'
        intelliSenseMode = 'windows-gcc-x64'
      }
    )
    version        = 4
  }

  $LaunchConfig = [ordered]@{
    version        = '0.2.0'
    configurations = @(
      [ordered]@{
        name              = 'Debug C++17 (GDB)'
        type              = 'cppdbg'
        request           = 'launch'
        program           = '${fileDirname}\${fileBasenameNoExtension}.exe'
        args              = @()
        stopAtEntry       = $false
        cwd               = '${fileDirname}'
        environment       = @(
          [ordered]@{
            name  = 'PATH'
            value = "$UcrtBinValue;$MsysUsrBinValue;`${env:PATH}"
          }
        )
        externalConsole   = $false
        MIMode            = 'gdb'
        miDebuggerPath    = $GdbForward
        setupCommands     = @(
          [ordered]@{
            description    = 'Enable pretty-printing for gdb'
            text           = '-enable-pretty-printing'
            ignoreFailures = $true
          }
        )
        preLaunchTask     = 'Build C++17'
      }
    )
  }

  Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'tasks.json') -InputObject $Tasks -Depth 20
  Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'c_cpp_properties.json') -InputObject $CppProperties -Depth 20
  Write-JsonUtf8NoBom -Path (Join-Path $VSCodeDir 'launch.json') -InputObject $LaunchConfig -Depth 20
  Write-Host "Contest VS Code workspace configs created in: $VSCodeDir" -ForegroundColor Green
}

function Restore-NormalVSCodeShortcut
{
  param([switch]$RemoveContestData)

  Write-Section 'Restore normal VS Code shortcuts'

  $ContestRoot = Get-ContestVSCodeRoot
  $ManifestPath = Join-Path $ContestRoot 'shortcut-manifest.json'

  if (Test-Path -LiteralPath $ManifestPath)
  {
    $Manifest = @(Read-VSCodeShortcutManifest -ManifestPath $ManifestPath)
    foreach ($Item in $Manifest)
    {
      if ($null -eq $Item) { continue }
      $ItemShortcutProp = $Item.PSObject.Properties['ShortcutPath']
      $ItemShortcutPath = if ($null -ne $ItemShortcutProp) { [string]$ItemShortcutProp.Value } else { '' }
      if ([string]::IsNullOrWhiteSpace($ItemShortcutPath)) { continue }
      $ItemExistedProp = $Item.PSObject.Properties['Existed']
      $ItemBackupProp = $Item.PSObject.Properties['BackupPath']
      $ItemExisted = if ($null -ne $ItemExistedProp) { [bool]$ItemExistedProp.Value } else { $false }
      $ItemBackupPath = if ($null -ne $ItemBackupProp) { [string]$ItemBackupProp.Value } else { '' }
      try
      {
        if ($ItemExisted -and (-not [string]::IsNullOrWhiteSpace($ItemBackupPath)) -and (Test-Path -LiteralPath $ItemBackupPath))
        {
          New-Item -ItemType Directory -Force -Path (Split-Path -Path $ItemShortcutPath -Parent) | Out-Null
          Copy-Item -LiteralPath $ItemBackupPath -Destination $ItemShortcutPath -Force
          Write-Host "Restored shortcut: $ItemShortcutPath" -ForegroundColor Green
        }
        elseif (Test-Path -LiteralPath $ItemShortcutPath)
        {
          Remove-Item -LiteralPath $ItemShortcutPath -Force
          Write-Host "Removed contest shortcut: $ItemShortcutPath" -ForegroundColor Green
        }
      }
      catch
      {
        Write-Warning "Failed to restore shortcut: $ItemShortcutPath - $($_.Exception.Message)"
      }
    }
  }
  else
  {
    Write-Host "No shortcut manifest found at $ManifestPath. Skipping shortcut restoration." -ForegroundColor Yellow
  }

  if ($RemoveContestData)
  {
    Stop-VSCodeProcesses -ContestOnly
    if (Test-Path -LiteralPath $ContestRoot)
    {
      Remove-Item -LiteralPath $ContestRoot -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "Removed isolated contest VS Code data: $ContestRoot" -ForegroundColor Green
    }
    $PortableDataDir = Get-PortableVSCodeDataDir
    if (Test-Path -LiteralPath $PortableDataDir)
    {
      Remove-Item -LiteralPath $PortableDataDir -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "Removed portable VS Code data trap: $PortableDataDir" -ForegroundColor Green
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
