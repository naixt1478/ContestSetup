# restore-hosts.ps1

$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsBackupPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.bak'
$BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
$EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
$AiTaskName = 'ContestSetupRestoreAiHostsBlock'

function Remove-ManagedHostsSectionFromText {
    param([Parameter(Mandatory = $true)] [string]$HostsText)
    $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
    return ([regex]::Replace($HostsText, $Pattern, "`r`n")).TrimEnd()
}

function Restore-Hosts {
    Write-Section 'Restore hosts'
    if (-not (Test-Path $HostsPath)) { Write-Warning "hosts file not found."; return }

    Backup-CurrentPath -Path $HostsPath
    if (Test-Path $HostsBackupPath) { Write-Host "Full hosts backup kept untouched: $HostsBackupPath" -ForegroundColor Yellow }

    $CurrentHosts = Get-Content -Path $HostsPath -Raw
    $NewHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($HostsPath, ($NewHosts + "`r`n"), $Encoding)
    ipconfig.exe /flushdns | Out-Null
    Write-Host 'Managed AI hosts section removed.' -ForegroundColor Green

    try { schtasks.exe /Delete /TN $AiTaskName /F | Out-Null } catch {}
}

Restore-Hosts
