# lib/path-and-identity.ps1
# Student SID/profile resolution, HKU/HKLM PATH management, WM_SETTINGCHANGE broadcast, and verified backups

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Broadcast-EnvironmentChange {
  try {
    if (-not ('ContestSetupWin32EnvBroadcast' -as [type])) {
      $CSharpLines = @(
        'using System;',
        'using System.Runtime.InteropServices;',
        'public static class ContestSetupWin32EnvBroadcast {',
        '  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]',
        '  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);',
        '}'
      )
      Add-Type -TypeDefinition ($CSharpLines -join [Environment]::NewLine) -Language CSharp -ErrorAction SilentlyContinue
    }
    $ResultPtr = [UIntPtr]::Zero
    [ContestSetupWin32EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 1000, [ref]$ResultPtr) | Out-Null
  } catch {}
}

function Resolve-ContestTargetUser {
  param(
    [string]$ExplicitSid = '',
    [string]$ExplicitProfile = ''
  )
  $CurrentSid = ''
  $CurrentName = ''
  try {
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Identity -and $Identity.User) { $CurrentSid = [string]$Identity.User.Value }
    if ($Identity) { $CurrentName = [string]$Identity.Name }
  } catch {}

  $CandidateSid = ''
  if (-not [string]::IsNullOrWhiteSpace($ExplicitSid) -and $ExplicitSid.Trim() -ne 'S-1-5-18') {
    $CandidateSid = $ExplicitSid.Trim()
  } elseif (-not [string]::IsNullOrWhiteSpace($TargetUserSid) -and $TargetUserSid.Trim() -ne 'S-1-5-18') {
    $CandidateSid = $TargetUserSid.Trim()
  } elseif (Test-Path -LiteralPath $StateManifestPath) {
    try {
      $SavedManifest = Read-ContestStateManifest
      $SavedSid = [string]$SavedManifest['TargetUserSid']
      if (-not [string]::IsNullOrWhiteSpace($SavedSid) -and $SavedSid.Trim() -ne 'S-1-5-18') {
        $CandidateSid = $SavedSid.Trim()
      }
    } catch {}
  }

  # Detect active interactive console user via explorer.exe owner when running as SYSTEM or separate LabAdmin UAC
  if ([string]::IsNullOrWhiteSpace($CandidateSid)) {
    try {
      if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $ExplorerProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)
        foreach ($ExpProc in $ExplorerProcs) {
          $OwnerSidInfo = Invoke-CimMethod -InputObject $ExpProc -MethodName GetOwnerSid -ErrorAction SilentlyContinue
          if ($OwnerSidInfo -and -not [string]::IsNullOrWhiteSpace([string]$OwnerSidInfo.Sid) -and ([string]$OwnerSidInfo.Sid -match '^S-1-5-21-')) {
            $CandidateSid = [string]$OwnerSidInfo.Sid
            break
          }
        }
      }
    } catch {}
  }

  if ([string]::IsNullOrWhiteSpace($CandidateSid)) {
    $CandidateSid = $CurrentSid
  }

  $IsSystemAccount = ([string]::IsNullOrWhiteSpace($CandidateSid) -or ($CandidateSid -eq 'S-1-5-18') -or ($CandidateSid -in @('S-1-5-19', 'S-1-5-20')))

  $ResolvedProfile = ''
  if (-not $IsSystemAccount) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile) -and (Test-Path -LiteralPath $ExplicitProfile)) {
      $ResolvedProfile = Normalize-ContestDirectoryPath $ExplicitProfile
    } elseif (-not [string]::IsNullOrWhiteSpace($TargetUserProfile) -and (Test-Path -LiteralPath $TargetUserProfile) -and ($CandidateSid -eq $TargetUserSid -or [string]::IsNullOrWhiteSpace($TargetUserSid))) {
      $ResolvedProfile = Normalize-ContestDirectoryPath $TargetUserProfile
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and (Test-Path -LiteralPath $StateManifestPath)) {
      try {
        $SavedManifest = Read-ContestStateManifest
        $SavedProfile = [string]$SavedManifest['TargetUserProfile']
        if (-not [string]::IsNullOrWhiteSpace($SavedProfile) -and (Test-Path -LiteralPath $SavedProfile) -and ([string]$SavedManifest['TargetUserSid'] -eq $CandidateSid)) {
          $ResolvedProfile = Normalize-ContestDirectoryPath $SavedProfile
        }
      } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and -not [string]::IsNullOrWhiteSpace($CandidateSid)) {
      $ProfileListReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CandidateSid"
      try {
        if (Test-Path -LiteralPath $ProfileListReg) {
          $ProfProps = Get-ItemProperty -LiteralPath $ProfileListReg -ErrorAction SilentlyContinue
          if ($ProfProps -and -not [string]::IsNullOrWhiteSpace([string]$ProfProps.ProfileImagePath)) {
            $ExpandedProf = [Environment]::ExpandEnvironmentVariables([string]$ProfProps.ProfileImagePath)
            $ResolvedProfile = Normalize-ContestDirectoryPath $ExpandedProf
          }
        }
      } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedProfile) -and ($CandidateSid -eq $CurrentSid) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
      $ResolvedProfile = Normalize-ContestDirectoryPath $env:USERPROFILE
    }
  }

  $ResolvedUserName = $CurrentName
  if (-not [string]::IsNullOrWhiteSpace($CandidateSid)) {
    try {
      $SecId = New-Object System.Security.Principal.SecurityIdentifier($CandidateSid)
      $ResolvedUserName = $SecId.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
      if (-not [string]::IsNullOrWhiteSpace($ResolvedProfile)) {
        $ResolvedUserName = Split-Path -Path $ResolvedProfile -Leaf
      }
    }
  }

  return [pscustomobject]@{
    Sid         = $CandidateSid
    UserName    = $ResolvedUserName
    ProfilePath = $ResolvedProfile
    IsSystem    = $IsSystemAccount
  }
}

function Get-RawMachinePath {
  try {
    $EnvKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    if ($null -ne $EnvKey) {
      try {
        $RawVal = $EnvKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [string]$RawVal
      } finally {
        $EnvKey.Dispose()
      }
    }
  } catch {}
  return [string]([Environment]::GetEnvironmentVariable('Path', 'Machine'))
}

function Set-RawMachinePath {
  param([AllowEmptyString()] [string]$PathValue)
  $EnvKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
  if ($null -eq $EnvKey) {
    throw 'Could not open HKLM Environment registry key with write access.'
  }
  try {
    $ExistingKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try { $ExistingKind = $EnvKey.GetValueKind('Path') } catch {}
    $TargetKind = if ($PathValue -match '%' -or $ExistingKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
      [Microsoft.Win32.RegistryValueKind]::ExpandString
    } else {
      [Microsoft.Win32.RegistryValueKind]::String
    }
    $EnvKey.SetValue('Path', $PathValue, $TargetKind)
  } finally {
    $EnvKey.Dispose()
  }
  Broadcast-EnvironmentChange
}

function Get-UserPathForTargetUser {
  param(
    [string]$TargetUserSid = '',
    [string]$TargetUserProfile = ''
  )
  $Resolved = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
  if ($Resolved.IsSystem -or [string]::IsNullOrWhiteSpace($Resolved.Sid) -or $Resolved.Sid -eq 'S-1-5-18') {
    return ''
  }

  $Sid = $Resolved.Sid
  $TempHiveName = $null
  $HiveLoadedByUs = $false
  try {
    $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid, $false)
    if ($null -eq $UserRootKey -and -not [string]::IsNullOrWhiteSpace($Resolved.ProfilePath) -and (Test-IsAdmin)) {
      $NtUserDat = Join-Path $Resolved.ProfilePath 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat) {
        $SafeSidToken = $Sid -replace '[^A-Za-z0-9_-]', '_'
        $TempHiveName = "ContestSetupHive_$SafeSidToken"
        $LoadRes = Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('load', "HKU\$TempHiveName", $NtUserDat) -Quiet
        if ($LoadRes.ExitCode -eq 0) {
          $HiveLoadedByUs = $true
          $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($TempHiveName, $false)
        }
      }
    }

    if ($null -ne $UserRootKey) {
      try {
        $EnvSubKey = $UserRootKey.OpenSubKey('Environment', $false)
        if ($null -ne $EnvSubKey) {
          try {
            $RawVal = $EnvSubKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [string]$RawVal
          } finally {
            $EnvSubKey.Dispose()
          }
        }
        return ''
      } finally {
        $UserRootKey.Dispose()
      }
    }
  } catch {}
  finally {
    if ($HiveLoadedByUs -and $TempHiveName) {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKU\$TempHiveName") -Quiet | Out-Null } catch {}
    }
  }

  $CurrentIdentitySid = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
  if ($CurrentIdentitySid -eq $Sid -and $Sid -ne 'S-1-5-18') {
    return [string]([Environment]::GetEnvironmentVariable('Path', 'User'))
  }
  return ''
}

function Set-UserPathForTargetUser {
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$PathValue,
    [string]$TargetUserSid = '',
    [string]$TargetUserProfile = ''
  )
  $Resolved = Resolve-ContestTargetUser -ExplicitSid $TargetUserSid -ExplicitProfile $TargetUserProfile
  if ($Resolved.IsSystem -or [string]::IsNullOrWhiteSpace($Resolved.Sid) -or $Resolved.Sid -eq 'S-1-5-18') {
    Write-Host 'Skipping HKU\.DEFAULT User PATH write because current target identity is SYSTEM (S-1-5-18) with no interactive student SID.' -ForegroundColor Gray
    return
  }

  $Sid = $Resolved.Sid
  $TempHiveName = $null
  $HiveLoadedByUs = $false
  $WroteRegistry = $false
  try {
    $TargetSubKeyName = $Sid
    $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid, $true)
    if ($null -eq $UserRootKey -and -not [string]::IsNullOrWhiteSpace($Resolved.ProfilePath) -and (Test-IsAdmin)) {
      $NtUserDat = Join-Path $Resolved.ProfilePath 'NTUSER.DAT'
      if (Test-Path -LiteralPath $NtUserDat) {
        $SafeSidToken = $Sid -replace '[^A-Za-z0-9_-]', '_'
        $TempHiveName = "ContestSetupHive_$SafeSidToken"
        $LoadRes = Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('load', "HKU\$TempHiveName", $NtUserDat) -Quiet
        if ($LoadRes.ExitCode -eq 0) {
          $HiveLoadedByUs = $true
          $TargetSubKeyName = $TempHiveName
          $UserRootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($TargetSubKeyName, $true)
        }
      }
    }

    if ($null -ne $UserRootKey) {
      try {
        $EnvSubKey = $UserRootKey.CreateSubKey('Environment')
        if ($null -ne $EnvSubKey) {
          try {
            $ExistingKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
            try { $ExistingKind = $EnvSubKey.GetValueKind('Path') } catch {}
            $TargetKind = if ($PathValue -match '%' -or $ExistingKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
              [Microsoft.Win32.RegistryValueKind]::ExpandString
            } else {
              [Microsoft.Win32.RegistryValueKind]::String
            }
            $EnvSubKey.SetValue('Path', $PathValue, $TargetKind)
            $WroteRegistry = $true
          } finally {
            $EnvSubKey.Dispose()
          }
        }
      } finally {
        $UserRootKey.Dispose()
      }
    }
  } catch {
    Write-Warning "Could not write HKU\$Sid\Environment\Path directly: $($_.Exception.Message)"
  } finally {
    if ($HiveLoadedByUs -and $TempHiveName) {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      try { Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @('unload', "HKU\$TempHiveName") -Quiet | Out-Null } catch {}
    }
  }

  if (-not $WroteRegistry) {
    $CurrentIdentitySid = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { '' }
    if ($CurrentIdentitySid -eq $Sid -and $Sid -ne 'S-1-5-18') {
      [Environment]::SetEnvironmentVariable('Path', $PathValue, 'User')
      $WroteRegistry = $true
    }
  }

  if ($WroteRegistry) {
    Broadcast-EnvironmentChange
  }
}

function Add-UserPathFront {
  param([Parameter(Mandatory = $true)] [string]$PathToAdd)
  Add-UserPathsFront -PathsToAdd @($PathToAdd)
}

function Add-UserPathsFront {
  param([Parameter(Mandatory = $true)] [string[]]$PathsToAdd)
  $ValidPaths = @()
  $Seen = @{}
  foreach ($PathToAdd in $PathsToAdd) {
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) { continue }
    if (-not (Test-Path -LiteralPath $PathToAdd)) { Write-Warning "PATH target not found: $PathToAdd"; continue }
    $Normalized = Normalize-PathForCompare $PathToAdd
    if (-not $Seen.ContainsKey($Normalized)) {
      $Seen[$Normalized] = $true
      $ValidPaths += $PathToAdd
    }
  }
  if ($ValidPaths.Count -eq 0) { return }

  $TargetNormals = @($Seen.Keys)
  $Current = Get-UserPathForTargetUser
  $UserParts = @()
  if (-not [string]::IsNullOrWhiteSpace($Current)) {
    $UserParts = $Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
  }
  Set-UserPathForTargetUser -PathValue (($ValidPaths + $UserParts) -join ';').TrimEnd(';')

  # Also prepend to Machine PATH when running as Admin so Machine PATH entries never shadow contest tools in new terminals
  if (Test-IsAdmin) {
    try {
      $CurrentMachine = Get-RawMachinePath
      $MachineParts = @()
      if (-not [string]::IsNullOrWhiteSpace($CurrentMachine)) {
        $MachineParts = $CurrentMachine.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
      }
      Set-RawMachinePath -PathValue (($ValidPaths + $MachineParts) -join ';').TrimEnd(';')
    } catch {
      Write-Warning "Could not update Machine PATH: $($_.Exception.Message)"
    }
  }

  $EnvParts = @()
  if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
    $EnvParts = $env:Path.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($TargetNormals -notcontains (Normalize-PathForCompare $_)) }
  }
  $env:Path = (($ValidPaths + $EnvParts) -join ';').TrimEnd(';')

  foreach ($PathToAdd in $ValidPaths) { Write-Host "PATH added: $PathToAdd" -ForegroundColor Green }
}

function Remove-PathEntriesMatching {
  param([Parameter(Mandatory = $true)] [string]$Scope, [Parameter(Mandatory = $true)] [scriptblock]$ShouldRemove)
  $Current = switch ($Scope) {
    'User'    { Get-UserPathForTargetUser }
    'Machine' { Get-RawMachinePath }
    default   { [Environment]::GetEnvironmentVariable('Path', $Scope) }
  }
  if ([string]::IsNullOrWhiteSpace($Current)) { return }
  $Removed = New-Object System.Collections.Generic.List[string]
  $Kept = New-Object System.Collections.Generic.List[string]
  foreach ($Part in ($Current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $Normalized = Normalize-PathForCompare $Part
    if (& $ShouldRemove $Part $Normalized) { $Removed.Add($Part) | Out-Null } else { $Kept.Add($Part) | Out-Null }
  }
  if ($Removed.Count -gt 0) {
    $UpdatedPath = ($Kept.ToArray() -join ';')
    switch ($Scope) {
      'User'    { Set-UserPathForTargetUser -PathValue $UpdatedPath }
      'Machine' { Set-RawMachinePath -PathValue $UpdatedPath }
      default   { [Environment]::SetEnvironmentVariable('Path', $UpdatedPath, $Scope) }
    }
    foreach ($PathEntry in $Removed) { Write-Host "PATH removed ($Scope): $PathEntry" -ForegroundColor Yellow }
  }
}

function Remove-ConflictingPathEntries {
  Write-Section 'Clean conflicting PATH entries'
  $RootNorm = Normalize-PathForCompare $Root
  $MsysRootNorm = Normalize-PathForCompare $MsysRoot
  $PythonDirNorm = Normalize-PathForCompare $PythonDir
  $ToolBinNorm = Normalize-PathForCompare $ToolBin
  $PathBinNorm = Normalize-PathForCompare $PathBin

  $TargetUser = Resolve-ContestTargetUser
  $CandidateVSCodeBins = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $CandidateVSCodeBins.Add((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($TargetUser.ProfilePath)) {
    $CandidateVSCodeBins.Add((Join-Path $TargetUser.ProfilePath 'AppData\Local\Programs\Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $CandidateVSCodeBins.Add((Join-Path $env:ProgramFiles 'Microsoft VS Code\bin')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
    $CandidateVSCodeBins.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')) | Out-Null
  }
  $VSCodeBinNorms = @($CandidateVSCodeBins | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ } | Select-Object -Unique)

  $ShouldRemove = {
    param($Original, $Normalized)
    $ExpandedNorm = try { Normalize-PathForCompare ([Environment]::ExpandEnvironmentVariables($Original)) } catch { $Normalized }
    foreach ($CheckNorm in @($Normalized, $ExpandedNorm)) {
      if (
        $CheckNorm -eq $ToolBinNorm -or
        $CheckNorm -eq $PathBinNorm -or
        $CheckNorm -eq $PythonDirNorm -or
        $CheckNorm.StartsWith("$PythonDirNorm\") -or
        $CheckNorm -eq $MsysRootNorm -or
        $CheckNorm.StartsWith("$MsysRootNorm\") -or
        $CheckNorm -eq $RootNorm -or
        $CheckNorm.StartsWith("$RootNorm\") -or
        $VSCodeBinNorms -contains $CheckNorm
      ) {
        return $true
      }
    }
    return $false
  }.GetNewClosure()

  Remove-PathEntriesMatching -Scope 'User' -ShouldRemove $ShouldRemove
  if (Test-IsAdmin) {
    try { Remove-PathEntriesMatching -Scope 'Machine' -ShouldRemove $ShouldRemove } catch {}
  }
  Remove-PathEntriesMatching -Scope 'Process' -ShouldRemove $ShouldRemove
}

function Backup-PathEnvironment {
  param([Parameter(Mandatory = $true)] [string]$BackupRoot)
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  $SnapshotPath = Join-Path $BackupRoot 'path-environment-before-cleanup.txt'
  if (Test-Path -LiteralPath $SnapshotPath) {
    Write-Host "PATH snapshot already exists, preserving original state: $SnapshotPath" -ForegroundColor Gray
    return
  }
  $TargetUser = Resolve-ContestTargetUser
  $UserPathVal = [string](Get-UserPathForTargetUser -TargetUserSid $TargetUser.Sid -TargetUserProfile $TargetUser.ProfilePath)
  $MachinePathVal = [string](Get-RawMachinePath)
  $Lines = @(
    'User PATH:',
    $UserPathVal,
    '',
    'Machine PATH:',
    $MachinePathVal,
    '',
    'Process PATH:',
    [string]$env:Path,
    '',
    'TargetUserSid:',
    [string]$TargetUser.Sid
  )
  Write-LinesUtf8NoBom -Path $SnapshotPath -Lines ([string[]]$Lines)
  Write-Host "PATH snapshot saved: $SnapshotPath" -ForegroundColor Green
}

function Get-PathHashToken {
  param([Parameter(Mandatory = $true)] [string]$Path)
  $Sha = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Path)
    return [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '').Substring(0, 12)
  }
  finally { $Sha.Dispose() }
}

function Backup-PathVerified {
  param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [string]$BackupRoot)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  $SafeLeaf = (Split-Path -Path $Path -Leaf) -replace '[\\/:*?"<>|]', '_'
  $Destination = Join-Path $BackupRoot ("{0}-{1}" -f $SafeLeaf, (Get-PathHashToken -Path $Path))
  if (Test-Path -LiteralPath $Destination) {
    Write-Host "Backup already exists, preserving original copy: $Destination" -ForegroundColor Gray
    return $Destination
  }
  Write-Host "Backing up: $Path`nBackup to : $Destination"
  $Item = Get-Item -LiteralPath $Path -Force
  if ($Item.PSIsContainer) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $RoboLogPath = Join-Path (Join-Path $LogDir 'robocopy') ("backup-{0}-{1}.log" -f $SafeLeaf, $TimeStamp)
    New-Item -ItemType Directory -Force -Path (Split-Path $RoboLogPath -Parent) | Out-Null
    & robocopy.exe $Path $Destination '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/R:2' '/W:1' '/NP' '/NFL' '/NDL' '/MT:16' "/LOG+:$RoboLogPath" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backup failed by robocopy. Source=$Path, Destination=$Destination" }
  } else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Destination -Parent) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $Destination -Force
  }
  if (-not (Test-Path -LiteralPath $Destination)) { throw "Backup verification failed: $Destination" }
  return $Destination
}

function Backup-And-RemovePathSafe {
  param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [string]$BackupRoot)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $BackupTarget = Backup-PathVerified -Path $Path -BackupRoot $BackupRoot
  Write-Host "Removing after verified backup: $Path"
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
  Write-Host "Backup saved: $BackupTarget" -ForegroundColor Green
}
