# setup-python.ps1

function Reset-ManagedPython {
    Write-Section "Reset managed Python $PythonVersion"
    if (Test-Path $PythonDir) {
        $BackupRoot = Join-Path $BackupDir ("python-$TimeStamp")
        Backup-And-RemovePathSafe -Path $PythonDir -BackupRoot $BackupRoot
    }
}

function Install-PythonDirect {
    Write-Section "Install Python $PythonVersion"
    $PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Python Setup"
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Checking managed installation..." -PercentComplete 10

    if (-not (Test-Path $PythonExe)) {
        if (-not (Test-Path $PythonInstaller)) {
            Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Downloading Python..." -PercentComplete 30
            Download-VerifiedFile -Url $PythonUrl -OutFile $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation')
        } else {
            Assert-AuthenticodeValid -Path $PythonInstaller -AllowedPublisherKeywords @('Python', 'Python Software Foundation')
        }
        Write-Host "Installing Python $PythonVersion..."
        Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Installing Python..." -PercentComplete 60
        $Args = "/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 TargetDir=`"$PythonDir`""
        $PythonProcess = Start-Process -FilePath $PythonInstaller -ArgumentList $Args -Wait -PassThru
        if ($PythonProcess.ExitCode -ne 0) { throw "Python installer failed. Exit code: $($PythonProcess.ExitCode)" }
    }
    if (-not (Test-Path $PythonExe)) { throw "Python install failed or python.exe not found: $PythonExe" }
    Invoke-NativeChecked -FilePath $PythonExe -ArgumentList @('--version') | Out-Null
    $Global:PythonExe = $PythonExe
    Write-Host "Python installed: $PythonExe" -ForegroundColor Green
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}

if (Test-Path $PythonDir) {
    if (-not (Test-Path $PythonExe)) {
        Reset-ManagedPython
    } else {
        Write-Host "Managed Python $PythonVersion is already installed at $PythonExe. Skipping download/install." -ForegroundColor Green
        $Global:PythonExe = $PythonExe
    }
}
$ConfiguredPythonExe = Get-Variable -Name 'PythonExe' -Scope Global -ErrorAction SilentlyContinue
$ConfiguredPythonExeValue = if ($ConfiguredPythonExe) { [string]$ConfiguredPythonExe.Value } else { '' }
if ([string]::IsNullOrWhiteSpace($ConfiguredPythonExeValue) -or -not (Test-Path -LiteralPath $ConfiguredPythonExeValue)) {
    Install-PythonDirect
}
