# restore-path.ps1

function Remove-KnownContestPathEntries {
    $Known = @(
        $ToolBin, $PathBin, $UcrtBin,
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin')
    ) | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ }

    $Current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($Current)) { return }
    $Parts = $Current.Split(';') | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and ($Known -notcontains (Normalize-PathForCompare $_))
    }
    [Environment]::SetEnvironmentVariable('Path', ($Parts -join ';'), 'User')
    $env:Path = ($Parts -join ';')
    Write-Host 'Known contest PATH entries removed.' -ForegroundColor Green
}

function Restore-PathEnvironment {
    Write-Section 'Restore PATH'
    $BackupRoot = Get-LatestBackupRoot -Prefix 'path-'
    if (-not $BackupRoot) {
        Write-Warning 'No PATH backup folder found. Removing known contest paths instead.'
        Remove-KnownContestPathEntries; return
    }

    $Snapshot = Join-Path $BackupRoot.FullName 'path-environment-before-cleanup.txt'
    if (-not (Test-Path $Snapshot)) {
        Write-Warning "PATH snapshot not found. Removing known contest paths instead."
        Remove-KnownContestPathEntries; return
    }

    $Lines = Get-Content -Path $Snapshot
    $UserPathIndex = [Array]::IndexOf($Lines, 'User PATH:')
    if ($UserPathIndex -ge 0 -and $Lines.Count -gt ($UserPathIndex + 1)) {
        $OriginalUserPath = $Lines[$UserPathIndex + 1]
        [Environment]::SetEnvironmentVariable('Path', $OriginalUserPath, 'User')
        $env:Path = $OriginalUserPath
        Write-Host 'User PATH restored from snapshot.' -ForegroundColor Green
    } else { Remove-KnownContestPathEntries }
}

Restore-PathEnvironment
