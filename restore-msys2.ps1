# restore-msys2.ps1

function Restore-MSYS2 {
    Write-Section 'Restore MSYS2'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'msys2-'
    if (-not $BackupRoot) { Write-Warning 'No MSYS2 backup folder found.'; return }
    $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf (Split-Path $MsysRoot -Leaf)
    if (-not $Source) { Write-Warning "No MSYS2 backup found."; return }
    Restore-PathFromBackup -Source $Source.FullName -Destination $MsysRoot
}

Restore-MSYS2
