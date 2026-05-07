# setup-visualstudio.ps1

Write-Section 'Setup Visual Studio'
Write-Progress -Id 2 -ParentId 1 -Activity "Visual Studio Setup" -Status "Checking installation..." -PercentComplete 10

$VSPath = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe'
if (Test-Path -Path $VSPath) {
    Write-Host 'Visual Studio Community 2022 is already installed (found devenv.exe). Skipping.' -ForegroundColor Green
    Write-Progress -Id 2 -ParentId 1 -Activity "Visual Studio Setup" -Completed
} else {
    $WingetCheck = try { (& winget list --id Microsoft.VisualStudio.2022.Community --exact --accept-source-agreements 2>$null) -join "`n" } catch { "" }
    if ($WingetCheck -match [regex]::Escape('Microsoft.VisualStudio.2022.Community')) {
        Write-Host 'Visual Studio Community 2022 is already installed (found via winget). Skipping.' -ForegroundColor Green
        Write-Progress -Id 2 -ParentId 1 -Activity "Visual Studio Setup" -Completed
    } else {
        Write-Progress -Id 2 -ParentId 1 -Activity "Visual Studio Setup" -Status "Installing via winget..." -PercentComplete 50
        $VSInstalled = Install-ByWinget -Id 'Microsoft.VisualStudio.2022.Community' -NameForLog 'Visual Studio Community 2022'
        if (-not $VSInstalled) {
            Write-Warning 'Visual Studio Community 2022 winget install failed or skipped. You can manually install it if needed.'
        }
        Write-Progress -Id 2 -ParentId 1 -Activity "Visual Studio Setup" -Completed
    }
}
