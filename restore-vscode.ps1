# restore-vscode.ps1

function Stop-VSCodeProcesses {
    foreach ($Name in @('Code', 'Code - Insiders', 'VSCodium')) {
        try { Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Restore-VSCode {
    Write-Section 'Restore VS Code'
    Stop-VSCodeProcesses
    $BackupRoot = Get-LatestBackupRoot -Prefix 'vscode-'
    if (-not $BackupRoot) { Write-Warning 'No VS Code backup folder found.'; return }

    $Targets = @(
        @{ Leaf = 'Code'; Destination = (Join-Path $env:APPDATA 'Code') },
        @{ Leaf = 'Code'; Destination = (Join-Path $env:LOCALAPPDATA 'Code') },
        @{ Leaf = '.vscode'; Destination = (Join-Path $env:USERPROFILE '.vscode') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path $env:ProgramFiles 'Microsoft VS Code') },
        @{ Leaf = 'Microsoft VS Code'; Destination = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code') }
    )
    foreach ($Target in $Targets) {
        $Source = Get-BackupChildByLeaf -BackupRoot $BackupRoot.FullName -Leaf $Target.Leaf
        if ($Source) { Restore-PathFromBackup -Source $Source.FullName -Destination $Target.Destination }
    }
}

Restore-VSCode
