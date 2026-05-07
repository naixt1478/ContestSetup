# setup-visualstudio.ps1

Write-Section 'Setup Visual Studio'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Visual Studio Setup"
Write-Progress -Activity $PA -Status "Checking installation..." -PercentComplete 10

$VSPath = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe'
if (Test-Path -Path $VSPath) {
    Write-Host 'Visual Studio Community 2022 is already installed (found devenv.exe). Skipping.' -ForegroundColor Green
    Write-Progress -Activity $PA -Completed
} else {
    $WingetCheck = try { (& winget list --id Microsoft.VisualStudio.2022.Community --exact --accept-source-agreements 2>$null) -join "`n" } catch { "" }
    if ($WingetCheck -match [regex]::Escape('Microsoft.VisualStudio.2022.Community')) {
        Write-Host 'Visual Studio Community 2022 is already installed (found via winget). Skipping.' -ForegroundColor Green
        Write-Progress -Activity $PA -Completed
    } else {
        Write-Progress -Activity $PA -Status "Installing via winget..." -PercentComplete 50
        $VSInstalled = Install-ByWinget -Id 'Microsoft.VisualStudio.2022.Community' -NameForLog 'Visual Studio Community 2022'
        if (-not $VSInstalled) {
            Write-Warning 'Visual Studio Community 2022 winget install failed or skipped. You can manually install it if needed.'
        }
        Write-Progress -Activity $PA -Completed
    }
}
