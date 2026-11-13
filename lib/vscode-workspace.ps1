# lib/vscode-workspace.ps1
# VS Code shortcut manifests, student shortcut replacement/restoration, CLI/PS1 launchers, and C++17 workspace configs

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

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
    $TargetDesktop = try { [Environment]::GetFolderPath('Desktop') } catch { '' }
  }
  if ([string]::IsNullOrWhiteSpace($TargetStartMenu) -and (-not $IsSystemOrCrossUser))
  {
    $TargetStartMenu = try { [Environment]::GetFolderPath('StartMenu') } catch { '' }
  }
  if ([string]::IsNullOrWhiteSpace($TargetTaskbarPinned) -and (-not [string]::IsNullOrWhiteSpace($env:APPDATA)))
  {
    $TargetTaskbarPinned = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
  }

  $CommonDesktop = try { [Environment]::GetFolderPath('CommonDesktopDirectory') } catch { '' }
  $CommonStartMenu = try { [Environment]::GetFolderPath('CommonStartMenu') } catch { '' }

  return [pscustomobject]@{
    Desktop             = $TargetDesktop
    StartMenu           = $TargetStartMenu
    TaskbarPinned       = $TargetTaskbarPinned
    CommonDesktop       = $CommonDesktop
    CommonStartMenu     = $CommonStartMenu
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

  $DefaultDrive = if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) { $env:SystemDrive } else { 'C:' }
  $MsysRootValue = Get-ConfiguredValue -Name 'MsysRoot' -DefaultValue "$DefaultDrive\msys64"
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
