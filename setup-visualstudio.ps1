# setup-visualstudio.ps1
# ContestSetup v2.0 -- Smart Visual Studio Detection (vswhere.exe) & Opt-In Installation (-IncludeVisualStudio)

function Test-MsvcClCompilerPresent
{
  param([Parameter(Mandatory = $true)] [string]$VsInstallRoot)
  $MsvcToolsDir = Join-Path $VsInstallRoot 'VC\Tools\MSVC'
  if (-not (Test-Path -LiteralPath $MsvcToolsDir)) { return $false }
  $ClCandidates = @(Get-ChildItem -Path (Join-Path $MsvcToolsDir '*\bin\Hostx64\x64\cl.exe') -File -ErrorAction SilentlyContinue)
  if ($ClCandidates.Count -gt 0) { return $true }
  $ClX86Candidates = @(Get-ChildItem -Path (Join-Path $MsvcToolsDir '*\bin\Hostx86\x86\cl.exe') -File -ErrorAction SilentlyContinue)
  return ($ClX86Candidates.Count -gt 0)
}

function Find-VisualStudioWithCppTools
{
  $VsWherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if ($VsWherePath -and (Test-Path -LiteralPath $VsWherePath))
  {
    try
    {
      $InstallPath = (& $VsWherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
      if (-not [string]::IsNullOrWhiteSpace([string]$InstallPath))
      {
        $TrimmedInstallPath = ([string]$InstallPath).Trim()
        if ((Test-Path -LiteralPath $TrimmedInstallPath) -and (Test-MsvcClCompilerPresent -VsInstallRoot $TrimmedInstallPath))
        {
          return $TrimmedInstallPath
        }
      }
    }
    catch {}
  }

  foreach ($BaseProg in @($env:ProgramFiles, ${env:ProgramFiles(x86)}))
  {
    if ([string]::IsNullOrWhiteSpace($BaseProg)) { continue }
    foreach ($Year in @('2026', '2022', '2019'))
    {
      foreach ($Edition in @('Community', 'Professional', 'Enterprise', 'BuildTools'))
      {
        $RootCandidate = Join-Path $BaseProg "Microsoft Visual Studio\$Year\$Edition"
        if ((Test-Path -LiteralPath $RootCandidate) -and (Test-MsvcClCompilerPresent -VsInstallRoot $RootCandidate))
        {
          return $RootCandidate
        }
      }
    }
  }
  return $null
}

Write-Section 'Setup Visual Studio'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Visual Studio Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Detecting existing Visual Studio...' -PercentComplete 10

$DetectedVS = Find-VisualStudioWithCppTools
if (-not [string]::IsNullOrWhiteSpace($DetectedVS))
{
  Write-Host "Visual Studio with C++ compiler (cl.exe) is already installed at '$DetectedVS'. Skipping." -ForegroundColor Green
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}
elseif (-not $IncludeVisualStudio)
{
  Write-Host 'Skipping Visual Studio 2022 Community installation by default for fast contest setup (MSYS2 UCRT64 GCC/GDB + VS Code is primary). Pass -IncludeVisualStudio to install.' -ForegroundColor Yellow
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}
elseif (-not (Test-CommandExists 'winget'))
{
  Write-Warning 'winget was not found. Skipping Visual Studio Community installation.'
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}
else
{
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Installing Visual Studio 2022 Community (core C++ workload)...' -PercentComplete 50
  # Drop --includeRecommended to avoid unnecessary multi-GB optional components; use --quiet --wait --norestart for zero UI prompts
  $VSArgs = @(
    'install',
    '--id', 'Microsoft.VisualStudio.2022.Community',
    '--exact',
    '--source', 'winget',
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--override', '--add Microsoft.VisualStudio.Workload.NativeDesktop --quiet --wait --norestart'
  )
  if (Test-WingetHelpSupports -Command 'install' -Option '--disable-interactivity')
  {
    $VSArgs += '--disable-interactivity'
  }

  $ExitCode = (Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList $VSArgs).ExitCode

  # If VS 2022 Community base IDE was already present without C++ workload, winget may skip --override; run vs_installer.exe modify if needed
  if ([string]::IsNullOrWhiteSpace((Find-VisualStudioWithCppTools)))
  {
    $VsInstallerExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vs_installer.exe'
    $ExistingVs2022Base = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community'
    if ((Test-Path -LiteralPath $VsInstallerExe) -and (Test-Path -LiteralPath $ExistingVs2022Base))
    {
      Write-Host 'Visual Studio 2022 base IDE detected without cl.exe; invoking vs_installer.exe modify for NativeDesktop workload...' -ForegroundColor Cyan
      $ModifyArgs = @('modify', '--installPath', $ExistingVs2022Base, '--add', 'Microsoft.VisualStudio.Workload.NativeDesktop', '--quiet', '--norestart')
      $ExitCode = (Invoke-NativeCommand -FilePath $VsInstallerExe -ArgumentList $ModifyArgs).ExitCode
    }
  }

  # Exit code 0 = success, 3010 = ERROR_SUCCESS_REBOOT_REQUIRED
  if ($ExitCode -in @(0, 3010))
  {
    if ($ExitCode -eq 3010)
    {
      Write-Host 'Visual Studio Community 2022 (C++ Workload) installed successfully (exit code 3010: reboot recommended before MSVC use).' -ForegroundColor Yellow
    }
    else
    {
      Write-Host "Visual Studio Community 2022 (C++ Workload) installed successfully (exit code $ExitCode)." -ForegroundColor Green
    }
  }
  else
  {
    Write-Warning "Visual Studio installation returned exit code $ExitCode. It might require manual attention or reboot."
  }
  Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}
