# setup-visualstudio.ps1

Write-Section 'Setup Visual Studio'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Visual Studio Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Checking installation..." -PercentComplete 10

$VSPath = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe'
if (Test-Path -Path $VSPath) {
    Write-Host 'Visual Studio Community 2022 is already installed (found devenv.exe). Skipping.' -ForegroundColor Green
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
} else {
    $WingetCheck = try { (& winget list --id Microsoft.VisualStudio.2022.Community --exact --accept-source-agreements 2>$null) -join "`n" } catch { "" }
    if ($WingetCheck -match [regex]::Escape('Microsoft.VisualStudio.2022.Community')) {
        Write-Host 'Visual Studio Community 2022 is already installed (found via winget). Skipping.' -ForegroundColor Green
        Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
    } else {
        Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Installing via winget (with C++ workload)..." -PercentComplete 50
        # Installing with C++ workload to make it useful for competitive programming
        $VSArgs = @('install', '--id', 'Microsoft.VisualStudio.2022.Community', '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--override', '"--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive"')
        
        $ExitCode = (Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList $VSArgs).ExitCode
        if ($ExitCode -eq 0) {
            Write-Host 'Visual Studio Community 2022 (C++ Workload) installed successfully.' -ForegroundColor Green
        } else {
            Write-Warning "Visual Studio installation via winget returned exit code $ExitCode. It might require manual attention or reboot."
        }
        Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
    }
}
