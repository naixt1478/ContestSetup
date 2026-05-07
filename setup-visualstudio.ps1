# setup-visualstudio.ps1

Write-Section 'Setup Visual Studio'

$VSPath = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe'
if (Test-Path -Path $VSPath) {
    Write-Host 'Visual Studio Community 2022 is already installed (found devenv.exe). Skipping.' -ForegroundColor Green
} else {
    $WingetCheck = try { (& winget list --id Microsoft.VisualStudio.2022.Community --exact 2>$null) -join "`n" } catch { "" }
    if ($WingetCheck -match [regex]::Escape('Microsoft.VisualStudio.2022.Community')) {
        Write-Host 'Visual Studio Community 2022 is already installed (found via winget). Skipping.' -ForegroundColor Green
    } else {
        $VSInstalled = Install-ByWinget -Id 'Microsoft.VisualStudio.2022.Community' -NameForLog 'Visual Studio Community 2022'
        if (-not $VSInstalled) {
            Write-Warning 'Visual Studio Community 2022 winget install failed or skipped. You can manually install it if needed.'
        }
    }
}
