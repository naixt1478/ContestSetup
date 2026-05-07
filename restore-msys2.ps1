# restore-msys2.ps1

function Invoke-RobocopyRestoreForMSYS2 {
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "MSYS2 restore source not found: $Source"
    }

    $Parent = Split-Path -Path $Destination -Parent
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Write-Host "Robocopy source      : $Source"
    Write-Host "Robocopy destination : $Destination"

    $Args = @(
        $Source,
        $Destination,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/XJ',
        '/R:2',
        '/W:1',
        '/NP'
    )

    & robocopy.exe @Args | Out-Host
    $ExitCode = [int]$LASTEXITCODE

    # Robocopy exit codes 0..7 are success or non-fatal copy states. 8+ means at least one copy failure.
    if ($ExitCode -ge 8) {
        throw "MSYS2 restore failed by robocopy. ExitCode=$ExitCode, Source=$Source, Destination=$Destination"
    }
}

function Ensure-RestoreBackupRootForMSYS2 {
    $Existing = Get-Variable -Name RestoreBackupRoot -Scope Script -ErrorAction SilentlyContinue

    if ((-not $Existing) -or [string]::IsNullOrWhiteSpace([string]$Existing.Value)) {
        $TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Set-Variable -Name RestoreBackupRoot -Scope Script -Value (Join-Path $BackupDir "restore-current-$TimeStamp")
    }

    return (Get-Variable -Name RestoreBackupRoot -Scope Script -ErrorAction Stop).Value
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

function Restore-MSYS2 {
    Write-Section 'Restore MSYS2'

    $BackupRoot = Get-LatestBackupRoot -Prefix 'msys2-'
    if (-not $BackupRoot) {
        Write-Warning 'No MSYS2 backup folder found.'
        return
    }

    $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf (Split-Path $MsysRoot -Leaf)
    if (-not $Source) {
        Write-Warning "No MSYS2 backup found."
        return
    }

    Write-Host "Selected MSYS2 backup root: $($BackupRoot.FullName)" -ForegroundColor Green
    Write-Host "Selected MSYS2 source     : $($Source.FullName)" -ForegroundColor Green
    Write-Host "MSYS2 destination         : $MsysRoot" -ForegroundColor Green

    Stop-MSYS2Processes

    if (Test-Path -LiteralPath $MsysRoot) {
        $RestoreRoot = Ensure-RestoreBackupRootForMSYS2

        if (Get-Command Backup-PathVerified -ErrorAction SilentlyContinue) {
            $BackupTarget = Backup-PathVerified -Path $MsysRoot -BackupRoot $RestoreRoot
            Write-Host "Current MSYS2 backed up: $BackupTarget" -ForegroundColor Green
        }
        else {
            $CurrentBackup = Join-Path $RestoreRoot 'msys64-current'
            Invoke-RobocopyRestoreForMSYS2 -Source $MsysRoot -Destination $CurrentBackup
            Write-Host "Current MSYS2 backed up: $CurrentBackup" -ForegroundColor Green
        }

        Write-Host "Removing current MSYS2: $MsysRoot" -ForegroundColor Yellow
        Remove-Item -LiteralPath $MsysRoot -Recurse -Force -ErrorAction Stop
    }

    Invoke-RobocopyRestoreForMSYS2 -Source $Source.FullName -Destination $MsysRoot

    $BashPath = Join-Path $MsysRoot 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $BashPath)) {
        throw "MSYS2 restore verification failed. Missing: $BashPath"
    }

    Write-Host "MSYS2 restored: $MsysRoot" -ForegroundColor Green
}

Restore-MSYS2
