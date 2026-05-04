# restore-python.ps1

function Restore-Python {
    Write-Section 'Restore managed Python'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'python-'
    if (-not $BackupRoot) { Write-Warning 'No Python backup folder found.'; return }
    $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf (Split-Path $PythonDir -Leaf)
    if (-not $Source) { Write-Warning "No Python backup found."; return }
    Restore-PathFromBackup -Source $Source.FullName -Destination $PythonDir
}

Restore-Python
