# setup-visualstudio.ps1

Write-Section 'Setup Visual Studio'
$VSInstalled = Install-ByWinget -Id 'Microsoft.VisualStudio.2022.Community' -NameForLog 'Visual Studio Community 2022'
if (-not $VSInstalled) {
    Write-Warning 'Visual Studio Community 2022 winget install failed or skipped. You can manually install it if needed.'
}
