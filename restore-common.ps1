# restore-common.ps1

function Get-LatestBackupRoot {
    param([Parameter(Mandatory = $true)] [string]$Prefix)
    if (-not (Test-Path $BackupDir)) { return $null }
    return Get-ChildItem -Path $BackupDir -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-BackupChildByLeaf {
    param([Parameter(Mandatory = $true)] [string]$BackupRoot, [Parameter(Mandatory = $true)] [string]$Leaf)
    $SafeLeaf = $Leaf -replace '[\\/:*?"<>|]', '_'
    return Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$SafeLeaf-*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Backup-CurrentPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    if (-not (Test-Path $Path)) { return }
    $Leaf = Split-Path -Path $Path -Leaf
    $Dest = Join-Path $RestoreBackupRoot ($Leaf -replace '[\\/:*?"<>|]', '_')
    New-Item -ItemType Directory -Force -Path $RestoreBackupRoot | Out-Null
    Copy-Item -Path $Path -Destination $Dest -Recurse -Force
    Write-Host "Current path backed up: $Dest" -ForegroundColor Green
}

function Restore-PathFromBackup {
    param([Parameter(Mandatory = $true)] [string]$Source, [Parameter(Mandatory = $true)] [string]$Destination)
    Backup-CurrentPath -Path $Destination
    if (Test-Path $Destination) { Remove-Item -Path $Destination -Recurse -Force }

    $Parent = Split-Path -Path $Destination -Parent
    # 부모 경로가 존재하지 않는 경우에만 폴더 생성 시도
    if (-not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }

    Copy-Item -Path $Source -Destination $Destination -Recurse -Force
    Write-Host "Restored: $Destination" -ForegroundColor Green
}

if (-not $RestoreBackupRoot) {
    $TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $RestoreBackupRoot = Join-Path $BackupDir "restore-current-$TimeStamp"
}
