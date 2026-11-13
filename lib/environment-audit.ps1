# lib/environment-audit.ps1
# Strictly read-only 7-component environment status and executable verification audit

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Invoke-ContestEnvironmentAudit
{
  Write-Section 'ContestSetup v2.0 Environment Status & Verification'

  $RunExecutableChecks = ($Mode -eq 'Verify')
  $Checks = New-Object System.Collections.Generic.List[object]

  # 1. MSYS2 GCC/GDB/cat existence + executable health check in Verify mode
  $GppPath = Join-Path $UcrtBin 'g++.exe'
  $GccPath = Join-Path $UcrtBin 'gcc.exe'
  $GdbPath = Join-Path $UcrtBin 'gdb.exe'
  $MsysFilesOk = (Test-Path -LiteralPath $GppPath) -and (Test-Path -LiteralPath $GccPath) -and (Test-Path -LiteralPath $GdbPath) -and (Test-Path -LiteralPath $MsysCat)
  $MsysExecOk = $true
  $MsysDetail = if ($MsysFilesOk) { $UcrtBin } else { "Missing tools under $MsysRoot" }
  if ($MsysFilesOk -and $RunExecutableChecks)
  {
    $OldPath = $env:Path
    try
    {
      $env:Path = "$UcrtBin;$MsysUsrBin;$OldPath"
      foreach ($BinCheck in @($GppPath, $GccPath, $GdbPath, $MsysCat))
      {
        $VerRes = Invoke-NativeCommand -FilePath $BinCheck -ArgumentList @('--version') -Quiet
        if ($VerRes.ExitCode -ne 0)
        {
          $MsysExecOk = $false
          $MsysDetail = "Executable --version failed (exit $($VerRes.ExitCode)): $BinCheck"
          break
        }
      }
    }
    catch
    {
      $MsysExecOk = $false
      $MsysDetail = "Toolchain execution error: $($_.Exception.Message)"
    }
    finally
    {
      $env:Path = $OldPath
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'MSYS2 UCRT64 (g++, gcc, gdb, cat)'
    Ready     = ($MsysFilesOk -and $MsysExecOk)
    Detail    = $MsysDetail
  }) | Out-Null

  # 2. Python 3.10 existence + stdlib execution check in Verify mode
  $PyFilesOk = (Test-Path -LiteralPath $PythonExe) -and (Test-Path -LiteralPath $Python3Exe)
  $PyExecOk = $true
  $PyDetail = if ($PyFilesOk) { $PythonDir } else { "Missing $PythonExe or $Python3Exe" }
  if ($PyFilesOk -and $RunExecutableChecks)
  {
    try
    {
      $PyVerCheck = Invoke-NativeCommand -FilePath $PythonExe -ArgumentList @('--version') -Quiet
      $PyStdCheck = Invoke-NativeCommand -FilePath $PythonExe -ArgumentList @('-c', 'import site, encodings') -Quiet
      if ($PyVerCheck.ExitCode -ne 0 -or $PyStdCheck.ExitCode -ne 0)
      {
        $PyExecOk = $false
        $PyDetail = "Python runtime/stdlib check failed at $PythonExe"
      }
    }
    catch
    {
      $PyExecOk = $false
      $PyDetail = "Python execution error: $($_.Exception.Message)"
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = "Python $PythonVersion (python.exe & python3.exe)"
    Ready     = ($PyFilesOk -and $PyExecOk)
    Detail    = $PyDetail
  }) | Out-Null

  # 3. Standalone VS Code & Parsed Marketplace Lock
  $VSCodeAuditRoot = Join-Path $Root 'vscode'
  $CodeExePath = Join-Path $VSCodeAuditRoot 'Code.exe'
  $CodeCliPath = Join-Path $VSCodeAuditRoot 'bin\code.cmd'
  $ProductJsonPath = Resolve-VSCodeProductJsonPath -VSCodeRoot $VSCodeAuditRoot
  $VSCodeOk = (Test-Path -LiteralPath $CodeExePath) -and (Test-Path -LiteralPath $CodeCliPath) -and (-not [string]::IsNullOrWhiteSpace($ProductJsonPath)) -and (Test-Path -LiteralPath $ProductJsonPath)
  $MarketplaceLocked = $false
  if ($VSCodeOk)
  {
    try
    {
      $ProdRaw = Read-TextUtf8 -Path $ProductJsonPath
      $ProdObj = ConvertFrom-JsonSafe -Json $ProdRaw
      if ($null -ne $ProdObj)
      {
        $GalProp = $ProdObj.PSObject.Properties['extensionsGallery']
        if ($null -ne $GalProp -and $null -ne $GalProp.Value)
        {
          $SvcProp = $GalProp.Value.PSObject.Properties['serviceUrl']
          $ItmProp = $GalProp.Value.PSObject.Properties['itemUrl']
          $SvcLocked = ($null -ne $SvcProp) -and ([string]$SvcProp.Value -eq 'https://127.0.0.1')
          $ItmLocked = ($null -eq $ItmProp) -or ([string]$ItmProp.Value -eq 'https://127.0.0.1')
          $MarketplaceLocked = ($SvcLocked -and $ItmLocked)
        }
      }
    }
    catch {}
  }
  $Checks.Add([pscustomobject]@{
    Component = 'Portable VS Code & Marketplace Lock'
    Ready     = ($VSCodeOk -and $MarketplaceLocked)
    Detail    = "VSCode=$VSCodeOk, MarketplaceLocked=$MarketplaceLocked"
  }) | Out-Null

  # 4. VS Code Extensions, Korean Locale, Portable Data & AI Lockdown Settings
  $RequiredExts = @('ms-ceintl.vscode-language-pack-ko', 'ms-vscode.cpptools', 'ms-python.python', 'ms-python.debugpy')
  $AllowedExts = @(
    'ms-ceintl.vscode-language-pack-ko',
    'ms-vscode.cpptools',
    'ms-vscode.cpptools-themes',
    'ms-vscode.cpptools-extension-pack',
    'ms-python.python',
    'ms-python.debugpy',
    'ms-python.vscode-pylance',
    'ms-python.vscode-python-envs'
  )
  $ExtDir = Join-Path $Root 'vscode-contest\extensions'
  $PortableExtDir = Join-Path $Root 'vscode\data\extensions'
  $ExtFolders = if (Test-Path -LiteralPath $ExtDir) { @(Get-ChildItem -LiteralPath $ExtDir -Directory -ErrorAction SilentlyContinue) } else { @() }
  $MissingReqExts = @()
  foreach ($ReqExt in $RequiredExts)
  {
    $HasReq = @($ExtFolders | Where-Object { $_.Name.ToLowerInvariant().StartsWith("$ReqExt-") }).Count -gt 0
    if (-not $HasReq) { $MissingReqExts += $ReqExt }
  }
  $UnauthorizedExts = @()
  foreach ($ScanDir in @($ExtDir, $PortableExtDir))
  {
    if (Test-Path -LiteralPath $ScanDir)
    {
      foreach ($SubDir in @(Get-ChildItem -LiteralPath $ScanDir -Directory -ErrorAction SilentlyContinue))
      {
        $LowerName = $SubDir.Name.ToLowerInvariant()
        if ($LowerName.StartsWith('.')) { continue }
        $MatchedAllowed = $false
        foreach ($AllowId in $AllowedExts)
        {
          if ($LowerName -eq $AllowId -or $LowerName.StartsWith("$AllowId-"))
          {
            $MatchedAllowed = $true
            break
          }
        }
        if (-not $MatchedAllowed)
        {
          $UnauthorizedExts += $SubDir.Name
        }
      }
    }
  }

  $ContestArgvPath = Join-Path $Root 'vscode-contest\user-data\argv.json'
  $PortableArgvPath = Join-Path $Root 'vscode\data\argv.json'
  $ContestSettingsPath = Join-Path $Root 'vscode-contest\user-data\User\settings.json'
  $WorkspaceVscDir = Join-Path $Root 'contest\.vscode'
  $LocaleOk = $false
  $AiSettingsOk = $false
  try
  {
    if ((Test-Path -LiteralPath $ContestArgvPath) -and (Test-Path -LiteralPath $PortableArgvPath))
    {
      $ContestArgv = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $ContestArgvPath)
      $PortableArgv = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $PortableArgvPath)
      $ContestLocProp = if ($ContestArgv) { $ContestArgv.PSObject.Properties['locale'] } else { $null }
      $PortableLocProp = if ($PortableArgv) { $PortableArgv.PSObject.Properties['locale'] } else { $null }
      $LocaleOk = ($null -ne $ContestLocProp -and [string]$ContestLocProp.Value -eq 'ko') -and ($null -ne $PortableLocProp -and [string]$PortableLocProp.Value -eq 'ko')
    }
    if (Test-Path -LiteralPath $ContestSettingsPath)
    {
      $SetObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $ContestSettingsPath)
      $DisableAiProp = if ($SetObj) { $SetObj.PSObject.Properties['chat.disableAIFeatures'] } else { $null }
      $AiSettingsOk = ($null -ne $DisableAiProp -and [bool]$DisableAiProp.Value -eq $true)
    }
  }
  catch {}
  $WorkspaceCfgsOk = (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'tasks.json')) -and
                     (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'c_cpp_properties.json')) -and
                     (Test-Path -LiteralPath (Join-Path $WorkspaceVscDir 'launch.json'))
  $ProfileHardened = ($MissingReqExts.Count -eq 0) -and ($UnauthorizedExts.Count -eq 0) -and $LocaleOk -and $AiSettingsOk -and $WorkspaceCfgsOk
  $ProfileDetailParts = @()
  if ($MissingReqExts.Count -gt 0) { $ProfileDetailParts += ("MissingExts=" + ($MissingReqExts -join ',')) }
  if ($UnauthorizedExts.Count -gt 0) { $ProfileDetailParts += ("UnauthorizedExts=" + ($UnauthorizedExts -join ',')) }
  if (-not $LocaleOk) { $ProfileDetailParts += 'LocaleKo=False' }
  if (-not $AiSettingsOk) { $ProfileDetailParts += 'AiDisabled=False' }
  if (-not $WorkspaceCfgsOk) { $ProfileDetailParts += 'WorkspaceConfigs=False' }
  $ProfileDetail = if ($ProfileHardened) { "4 required exts, allowlist clean, locale=ko, AI disabled" } else { $ProfileDetailParts -join '; ' }
  $Checks.Add([pscustomobject]@{
    Component = 'VS Code Contest Profile, Allowlist & Locale'
    Ready     = $ProfileHardened
    Detail    = $ProfileDetail
  }) | Out-Null

  # 5. All 10 Command Wrappers
  $ExpectedWrappers = @('g++14.cmd', 'g++17.cmd', 'g++20.cmd', 'g++.cmd', 'gcc.cmd', 'gdb.cmd', 'python.cmd', 'python3.cmd', 'cat.cmd', 'code.cmd')
  $MissingWrappers = @($ExpectedWrappers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ToolBin $_)) })
  $WrappersOk = ($MissingWrappers.Count -eq 0)
  $Checks.Add([pscustomobject]@{
    Component = 'CLI Wrappers (10 .cmd wrappers)'
    Ready     = $WrappersOk
    Detail    = if ($WrappersOk) { $ToolBin } else { "Missing in ${ToolBin}: " + ($MissingWrappers -join ', ') }
  }) | Out-Null

  # 6. AI Hosts Block (Active entries count + IPv4 & IPv6 sentinel domains inside managed section)
  $HostsOverride = ''
  if (Get-Command Get-ContestVariableValue -ErrorAction SilentlyContinue)
  {
    $HostsOverride = [string](Get-ContestVariableValue -Name 'ContestHostsPathOverride' -DefaultValue '' -EnvVar 'CONTEST_HOSTS_PATH_OVERRIDE')
  }
  else
  {
    foreach ($ScopeName in @('Local', 'Script', 'Global'))
    {
      $OverrideVar = Get-Variable -Name 'ContestHostsPathOverride' -Scope $ScopeName -ErrorAction SilentlyContinue
      if ($null -ne $OverrideVar -and -not [string]::IsNullOrWhiteSpace([string]$OverrideVar.Value))
      {
        $HostsOverride = [string]$OverrideVar.Value
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($HostsOverride) -and -not [string]::IsNullOrWhiteSpace($env:CONTEST_HOSTS_PATH_OVERRIDE))
    {
      $HostsOverride = [string]$env:CONTEST_HOSTS_PATH_OVERRIDE
    }
  }
  $HostsPath = if (-not [string]::IsNullOrWhiteSpace($HostsOverride)) {
    $HostsOverride
  } elseif (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  } else {
    '/etc/hosts'
  }

  $HostsBlocked = $false
  $HostsDetail = $HostsPath
  if (Test-Path -LiteralPath $HostsPath)
  {
    try
    {
      $HostsContent = Read-TextUtf8 -Path $HostsPath
      $BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
      $EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
      $SectionMatch = [regex]::Match($HostsContent, '(?s)' + [regex]::Escape($BeginMarker) + '(.*?)' + [regex]::Escape($EndMarker))
      if ($SectionMatch.Success)
      {
        $ManagedSection = $SectionMatch.Groups[1].Value
        $RuleMatches = [regex]::Matches($ManagedSection, '(?m)^\s*(?:0\.0\.0\.0|::)\s+\S+')
        $RuleCount = $RuleMatches.Count
        $SentinelsOk = ($ManagedSection -match '(?m)^\s*0\.0\.0\.0\s+chatgpt\.com\s*$') -and
                       ($ManagedSection -match '(?m)^\s*::\s+chatgpt\.com\s*$') -and
                       ($ManagedSection -match '(?m)^\s*0\.0\.0\.0\s+claude\.ai\s*$') -and
                       ($ManagedSection -match '(?m)^\s*::\s+claude\.ai\s*$')
        $HostsBlocked = ($RuleCount -ge 100) -and $SentinelsOk
        $HostsDetail = "$HostsPath ($RuleCount active block entries, IPv4+IPv6 verified=$SentinelsOk)"
      }
      elseif ($DeferAiBlockUntilExamStart)
      {
        $HostsDetail = "Deferred until ExamStart ($ExamStart) by -DeferAiBlockUntilExamStart"
        if ($Mode -eq 'Status') { $HostsBlocked = $true }
      }
      else
      {
        $HostsDetail = "Managed AI blocklist markers missing in $HostsPath"
      }
    }
    catch
    {
      $HostsDetail = "Could not inspect ${HostsPath}: $($_.Exception.Message)"
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'AI Hosts Blocklist'
    Ready     = $HostsBlocked
    Detail    = $HostsDetail
  }) | Out-Null

  # 7. Scheduled Task for Auto-Restore (State + Trigger + schtasks fallback + non-admin DACL note)
  $TaskReady = $false
  $TaskDetail = "Target: $RestoreAt"
  if ($NoRestoreTask)
  {
    $TaskReady = $true
    $TaskDetail = 'Skipped by -NoRestoreTask'
  }
  else
  {
    $TaskFound = $false
    try
    {
      if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
      {
        $TaskObj = Get-ScheduledTask -TaskName 'ContestSetupRestoreAndCleanup' -ErrorAction SilentlyContinue
        if ($null -ne $TaskObj)
        {
          $TaskFound = $true
          $StateStr = [string]$TaskObj.State
          $StateOk = ($StateStr -notin @('Disabled', 'Unknown'))
          $BoundaryStr = ''
          $TriggerOk = $true
          $TriggersProp = $TaskObj.PSObject.Properties['Triggers']
          if ($null -ne $TriggersProp)
          {
            if ($TaskObj.Triggers -and @($TaskObj.Triggers).Count -gt 0)
            {
              $FirstTrigger = @($TaskObj.Triggers)[0]
              if ($FirstTrigger.PSObject.Properties['StartBoundary'] -and -not [string]::IsNullOrWhiteSpace([string]$FirstTrigger.StartBoundary))
              {
                $BoundaryStr = [string]$FirstTrigger.StartBoundary
              }
            }
            else
            {
              $TriggerOk = $false
            }
          }
          $TaskReady = ($StateOk -and $TriggerOk)
          $TaskDetail = "Registered (State: $StateStr, Trigger: $(if ($BoundaryStr) { $BoundaryStr } else { 'none' }), Target: $RestoreAt)"
        }
      }
    }
    catch {}

    if (-not $TaskFound)
    {
      try
      {
        if (Get-Command schtasks.exe -ErrorAction SilentlyContinue)
        {
          $SchRes = Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @('/Query', '/TN', 'ContestSetupRestoreAndCleanup', '/FO', 'LIST', '/V') -Quiet
          if ($SchRes.ExitCode -eq 0)
          {
            $TaskFound = $true
            $SchText = ($SchRes.Output -join "`n")
            $IsDisabled = ($SchText -imatch 'Status:\s*Disabled|Scheduled Task State:\s*Disabled')
            $TaskReady = (-not $IsDisabled)
            $TaskDetail = "Registered via schtasks (Disabled=$IsDisabled, Target: $RestoreAt)"
          }
        }
      }
      catch {}
    }

    if ((-not $TaskFound) -and (-not (Test-IsAdmin)))
    {
      $ManifestRegistered = $false
      try
      {
        if (Test-Path -LiteralPath $StateManifestPath)
        {
          $SavedMan = Read-ContestStateManifest
          $ManifestRegistered = (@($SavedMan['CompletedModules']) -contains 'setup-restore-task.ps1')
        }
      }
      catch {}

      if ($Mode -eq 'Status' -and $ManifestRegistered)
      {
        $TaskReady = $true
        $TaskDetail = "Recorded in install-manifest.json (Run elevated to inspect SYSTEM Scheduled Task DACL directly; Target: $RestoreAt)"
      }
      else
      {
        $TaskDetail = "Not visible to non-admin token (Run elevated to inspect SYSTEM Scheduled Task DACL; Target: $RestoreAt)"
      }
    }
  }
  $Checks.Add([pscustomobject]@{
    Component = 'Auto-Restore Scheduled Task'
    Ready     = $TaskReady
    Detail    = $TaskDetail
  }) | Out-Null

  $AllReady = $true
  foreach ($Check in $Checks)
  {
    $Badge = if ($Check.Ready) { '[READY]  ' } else { '[MISSING]' }
    $Color = if ($Check.Ready) { 'Green' } else { 'Yellow' }
    if (-not $Check.Ready) { $AllReady = $false }
    Write-Host ("{0} {1} -> {2}" -f $Badge, $Check.Component, $Check.Detail) -ForegroundColor $Color
  }

  return [pscustomobject]@{
    AllReady = $AllReady
    Checks   = $Checks.ToArray()
  }
}
