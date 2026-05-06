$BackupBase = 'C:\CPTools\backup'

function Get-DirSizeMB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Measure-Object -Property Length -Sum
    return [math]::Round(($sum.Sum / 1MB), 2)
}

Get-ChildItem -LiteralPath $BackupBase -Directory -Filter 'vscode-*' |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host $_.FullName -ForegroundColor Yellow
        Write-Host "LastWriteTime: $($_.LastWriteTime)"

        Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $size = Get-DirSizeMB $_.FullName
                $hasSettings = Test-Path -LiteralPath (Join-Path $_.FullName 'User\settings.json')
                $hasKeybindings = Test-Path -LiteralPath (Join-Path $_.FullName 'User\keybindings.json')
                $hasExtensions = Test-Path -LiteralPath (Join-Path $_.FullName 'extensions')

                [pscustomobject]@{
                    Piece = $_.Name
                    SizeMB = $size
                    HasSettings = $hasSettings
                    HasKeybindings = $hasKeybindings
                    HasExtensionsDir = $hasExtensions
                    Path = $_.FullName
                }
            } | Format-Table -AutoSize
    }
