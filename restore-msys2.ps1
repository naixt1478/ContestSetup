# restore-msys2.ps1
# Robust MSYS2 restore module for ContestSetup.
# This module is intended to be loaded after common.ps1 and restore-common.ps1.

function Get-ContestStringVariable {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [AllowNull()] [AllowEmptyString()] [string]$DefaultValue = ''
    )

    $Value = $null

    # First use normal dynamic lookup. This is important because restore-msys2.ps1 is
    # dot-sourced from restore.ps1, and $MsysRoot can live in an outer scope.
    try {
        $Var = Get-Variable -Name $Name -ErrorAction SilentlyContinue
        if ($Var -and $null -ne $Var.Value) {
            $Value = [string]$Var.Value
            if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
        }
    }
    catch {}

    # Then scan nearby scopes defensively. Older restore wrappers may dot-source modules
    # inside helper functions, so the caller's variables are not always exactly Scope 1.
    foreach ($Scope in @(0, 1, 2, 3, 4, 5, 'Script', 'Global')) {
        try {
            $Var = Get-Variable -Name $Name -Scope $Scope -ErrorAction SilentlyContinue
            if ($Var -and $null -ne $Var.Value) {
                $Value = [string]$Var.Value
                if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
            }
        }
        catch {}
    }

    return $DefaultValue
}

function Get-DefaultMSYS2Root {
    $Drive = [string]$env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($Drive)) { $Drive = 'C:' }
    return ($Drive.TrimEnd([char[]]@('\\', '/')) + '\msys64')
}

function Get-PathStringSafe {
    param([AllowNull()] [object]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.IO.FileSystemInfo]) {
        return [string]$InputObject.FullName
    }

    try {
        $FullNameProperty = $InputObject.PSObject.Properties['FullName']
        if ($FullNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$FullNameProperty.Value)) {
            return [string]$FullNameProperty.Value
        }
    }
    catch {}

    $Text = [string]$InputObject
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return $Text
}

function ConvertTo-FullPathSafe {
    param([AllowNull()] [AllowEmptyString()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($Expanded)) { return $null }

    try {
        return [System.IO.Path]::GetFullPath($Expanded)
    }
    catch {
        throw "Invalid path format: $Path. $($_.Exception.Message)"
    }
}

function Normalize-PathForCompare {
    param([AllowNull()] [AllowEmptyString()] [string]$Path)

    $FullPath = ConvertTo-FullPathSafe -Path $Path
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
    return $FullPath.TrimEnd([char[]]@('\\', '/')).ToUpperInvariant()
}

function Get-LeafNameSafe {
    param([AllowNull()] [AllowEmptyString()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Cannot determine leaf name because the path is empty.'
    }

    $Trimmed = $Path.TrimEnd([char[]]@('\\', '/'))
    if ([string]::IsNullOrWhiteSpace($Trimmed)) {
        throw "Cannot determine leaf name from path: $Path"
    }

    $Leaf = $null

    try { $Leaf = Split-Path -Path $Trimmed -Leaf } catch {}
    if ([string]::IsNullOrWhiteSpace($Leaf)) {
        try { $Leaf = [System.IO.Path]::GetFileName($Trimmed) } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($Leaf)) {
        throw "Cannot determine leaf name from path: $Path"
    }

    return $Leaf
}

function ConvertTo-SafeBackupLeaf {
    param([AllowNull()] [AllowEmptyString()] [string]$Leaf)
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return $null }
    return ($Leaf -replace '[\\/:*?"<>|]', '_')
}

function Stop-MSYS2Processes {
    foreach ($Name in @('pacman', 'bash', 'mintty', 'g++', 'gcc', 'gdb', 'make', 'cc1', 'cc1plus')) {
        try {
            Get-Process -Name $Name -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Get-MSYS2SourceFromManifest {
    param(
        [AllowNull()] [AllowEmptyString()] [string]$BackupRootPath,
        [AllowNull()] [AllowEmptyString()] [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($BackupRootPath)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Destination)) { return $null }

    $ManifestPath = Join-Path $BackupRootPath 'backup-manifest.tsv'
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }

    $DestinationNorm = Normalize-PathForCompare -Path $Destination
    foreach ($Line in (Get-Content -LiteralPath $ManifestPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }

        $Parts = $Line -split "`t", 2
        if ($Parts.Count -ne 2) { continue }

        $SourcePath = [string]$Parts[0]
        $OriginalDestination = [string]$Parts[1]

        if ((Normalize-PathForCompare -Path $OriginalDestination) -eq $DestinationNorm -and
            -not [string]::IsNullOrWhiteSpace($SourcePath) -and
            (Test-Path -LiteralPath $SourcePath)) {
            return Get-Item -LiteralPath $SourcePath -Force
        }
    }

    return $null
}

function Find-MSYS2BackupSource {
    param(
        [AllowNull()] [AllowEmptyString()] [string]$BackupRootPath,
        [AllowNull()] [AllowEmptyString()] [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($BackupRootPath)) { throw 'BackupRootPath is empty.' }
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'MSYS2 destination path is empty.' }
    if (-not (Test-Path -LiteralPath $BackupRootPath)) { throw "Backup root not found: $BackupRootPath" }

    # 1) Prefer the manifest when present. It is the safest way to match an old backup to its original destination.
    $ManifestSource = Get-MSYS2SourceFromManifest -BackupRootPath $BackupRootPath -Destination $Destination
    if ($ManifestSource) { return $ManifestSource }

    $Leaf = Get-LeafNameSafe -Path $Destination
    $SafeLeaf = ConvertTo-SafeBackupLeaf -Leaf $Leaf

    # 2) Use the shared helper if it exists, but normalize the return value because older helpers may return a string.
    if (Get-Command Get-BackupChildByLeaf -ErrorAction SilentlyContinue) {
        try {
            $SharedSource = Get-BackupChildByLeaf -BackupRoot $BackupRootPath -Leaf $Leaf
            $SharedSourcePath = ConvertTo-FullPathSafe -Path (Get-PathStringSafe -InputObject $SharedSource)
            if (-not [string]::IsNullOrWhiteSpace($SharedSourcePath) -and (Test-Path -LiteralPath $SharedSourcePath)) {
                return Get-Item -LiteralPath $SharedSourcePath -Force
            }
        }
        catch {
            Write-Warning "Get-BackupChildByLeaf failed. Falling back to manual MSYS2 backup search. Reason: $($_.Exception.Message)"
        }
    }

    # 3) Manual fallback for both current and older backup folder names.
    $Candidates = @()
    try {
        $Candidates = Get-ChildItem -LiteralPath $BackupRootPath -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq $Leaf -or
                $_.Name -eq $SafeLeaf -or
                $_.Name -like "$Leaf-*" -or
                $_.Name -like "$SafeLeaf-*"
            } |
            Sort-Object LastWriteTime -Descending
    }
    catch {}

    if ($Candidates -and @($Candidates).Count -gt 0) { return @($Candidates)[0] }

    # 4) Last fallback: detect a directory that actually looks like an MSYS2 root.
    try {
        $MsysLike = Get-ChildItem -LiteralPath $BackupRootPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'usr\bin\bash.exe') } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($MsysLike) { return $MsysLike }
    }
    catch {}

    if (Test-Path -LiteralPath (Join-Path $BackupRootPath 'usr\bin\bash.exe')) {
        return Get-Item -LiteralPath $BackupRootPath -Force
    }

    return $null
}

function Invoke-MSYS2RobocopyMirror {
    param(
        [AllowNull()] [AllowEmptyString()] [string]$SourcePath,
        [AllowNull()] [AllowEmptyString()] [string]$DestinationPath
    )

    $SourcePath = ConvertTo-FullPathSafe -Path $SourcePath
    $DestinationPath = ConvertTo-FullPathSafe -Path $DestinationPath

    if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'MSYS2 robocopy source path is empty.' }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { throw 'MSYS2 robocopy destination path is empty.' }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "MSYS2 robocopy source directory not found: $SourcePath"
    }
    if ((Normalize-PathForCompare -Path $SourcePath) -eq (Normalize-PathForCompare -Path $DestinationPath)) {
        throw "MSYS2 robocopy source and destination are the same path: $SourcePath"
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        throw "MSYS2 destination exists as a file, not a directory: $DestinationPath"
    }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $Robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if (-not $Robocopy) {
        throw 'robocopy.exe was not found. MSYS2 restore requires robocopy for reliable directory restore.'
    }

    $RobocopyExe = [string]$Robocopy.Source

    $Options = @(
        '/E',           # Include empty directories.
        '/PURGE',       # Remove destination entries that are not in the backup source.
        '/COPY:DAT',    # Copy data, attributes, and timestamps. Avoid ACL/owner surprises.
        '/DCOPY:DAT',   # Preserve directory data, attributes, and timestamps where supported.
        '/XJ',          # Do not traverse junctions.
        '/R:2',         # Avoid extremely long retry loops on locked files.
        '/W:2',
        '/NP'
    )

    Write-Host 'Restoring MSYS2 with robocopy...' -ForegroundColor Yellow
    Write-Host "robocopy source      : $SourcePath" -ForegroundColor DarkGray
    Write-Host "robocopy destination : $DestinationPath" -ForegroundColor DarkGray

    & $RobocopyExe $SourcePath $DestinationPath @Options
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ge 8) {
        throw "robocopy failed while restoring MSYS2. ExitCode=$ExitCode Source=$SourcePath Destination=$DestinationPath"
    }

    Write-Host "robocopy completed. ExitCode=$ExitCode" -ForegroundColor Green
}

function Restore-MSYS2 {
    Write-Section 'Restore MSYS2'

    $EffectiveMsysRoot = Get-ContestStringVariable -Name 'MsysRoot' -DefaultValue (Get-DefaultMSYS2Root)
    if ([string]::IsNullOrWhiteSpace($EffectiveMsysRoot)) {
        $EffectiveMsysRoot = Get-DefaultMSYS2Root
    }
    $EffectiveMsysRoot = ConvertTo-FullPathSafe -Path $EffectiveMsysRoot

    if ([string]::IsNullOrWhiteSpace($EffectiveMsysRoot)) {
        throw 'MsysRoot is empty after normalization.'
    }

    if (-not (Get-Command Get-LatestBackupRoot -ErrorAction SilentlyContinue)) {
        throw 'Get-LatestBackupRoot is not loaded. common.ps1 and restore-common.ps1 must run before restore-msys2.ps1.'
    }

    $BackupRootObject = Get-LatestBackupRoot -Prefix 'msys2-'
    $BackupRootPath = ConvertTo-FullPathSafe -Path (Get-PathStringSafe -InputObject $BackupRootObject)
    if ([string]::IsNullOrWhiteSpace($BackupRootPath)) {
        Write-Warning 'No MSYS2 backup folder found. Skipping MSYS2 restore.'
        return
    }

    $Source = Find-MSYS2BackupSource -BackupRootPath $BackupRootPath -Destination $EffectiveMsysRoot
    $SourcePath = ConvertTo-FullPathSafe -Path (Get-PathStringSafe -InputObject $Source)
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        Write-Warning "No MSYS2 backup found in $BackupRootPath. Skipping MSYS2 restore."
        return
    }

    if ((Normalize-PathForCompare -Path $SourcePath) -eq (Normalize-PathForCompare -Path $EffectiveMsysRoot)) {
        Write-Warning "MSYS2 source and destination are the same path. Skipping to avoid deleting the source: $SourcePath"
        return
    }

    Write-Host "Selected MSYS2 backup root: $BackupRootPath" -ForegroundColor Green
    Write-Host "Selected MSYS2 source     : $SourcePath" -ForegroundColor Green
    Write-Host "MSYS2 destination         : $EffectiveMsysRoot" -ForegroundColor Green

    Stop-MSYS2Processes

    try {
        Invoke-MSYS2RobocopyMirror -SourcePath $SourcePath -DestinationPath $EffectiveMsysRoot
    }
    catch {
        throw "MSYS2 restore failed. Source=$SourcePath Destination=$EffectiveMsysRoot Reason=$($_.Exception.Message)"
    }

    $BashPath = Join-Path $EffectiveMsysRoot 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $BashPath)) {
        throw "MSYS2 restore verification failed. Missing: $BashPath"
    }

    Write-Host "MSYS2 restored: $EffectiveMsysRoot" -ForegroundColor Green
}

Restore-MSYS2
