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
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Checking existing installation..." -PercentComplete 10

    # Check if Python 3.10.x already exists on the system
    $ExistingPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($ExistingPython) {
        $ExistingVersion = try { (& $ExistingPython.Source --version 2>&1) -replace 'Python\s*', '' } catch { '' }
        if ($ExistingVersion -match '^3\.10\.') {
            Write-Host "Python 3.10 is already installed: $($ExistingPython.Source) (version $ExistingVersion). Skipping." -ForegroundColor Green
            $Global:PythonExe = $ExistingPython.Source
            Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
            return
        } else {
            Write-Host "Python found ($ExistingVersion) but not 3.10.x. Proceeding with installation." -ForegroundColor Yellow
        }
    }

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
    Write-Host "Python installed: $PythonExe" -ForegroundColor Green
    Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
}

Reset-ManagedPython
Install-PythonDirect
