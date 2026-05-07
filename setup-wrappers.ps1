# setup-wrappers.ps1

function Assert-Output {
    param([Parameter(Mandatory = $true)] [string]$Name, [Parameter(Mandatory = $true)] [string]$Actual, [Parameter(Mandatory = $true)] [string]$Expected)
    $A = $Actual.Trim(); $E = $Expected.Trim()
    if ($A -ne $E) { throw "$Name test failed. Expected: [$E], Actual: [$A]" }
    Write-Host "$Name test passed: $A" -ForegroundColor Green
}

function Create-CommandWrappers {
    Write-Section 'Create command wrappers'
    New-Item -ItemType Directory -Force -Path $ToolBin, $PathBin | Out-Null
    Remove-Item -Path (Join-Path $PathBin '*') -Recurse -Force -ErrorAction SilentlyContinue

    $MsysUsrBin = Split-Path $MsysBash -Parent
    $MsysToolPathLine = "set `"PATH=$UcrtBin;$MsysUsrBin;%PATH%`""

    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++14.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++14 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++17.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++17 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++20.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++20 %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++.cmd')  @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'gcc.cmd')  @('@echo off', $MsysToolPathLine, "`"$UcrtBin\gcc.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'gdb.cmd')  @('@echo off', $MsysToolPathLine, "`"$UcrtBin\gdb.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'python.cmd') @('@echo off', "`"$PythonExe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'python3.cmd') @('@echo off', "`"$PythonExe`" %*")
    Write-LinesUtf8NoBom (Join-Path $ToolBin 'cat.cmd') @('@echo off', "`"$MsysCat`" %*")

    Write-LinesUtf8NoBom (Join-Path $PathBin 'g++.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $PathBin 'gcc.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\gcc.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $PathBin 'gdb.cmd') @('@echo off', $MsysToolPathLine, "`"$UcrtBin\gdb.exe`" %*")
    Write-LinesUtf8NoBom (Join-Path $PathBin 'cat.cmd') @('@echo off', $MsysToolPathLine, "`"$MsysCat`" %*")

    Get-ChildItem -Path $UcrtBin -Filter '*.dll' -File -ErrorAction SilentlyContinue | Copy-Item -Destination $PathBin -Force
    Write-Host 'Wrappers created.' -ForegroundColor Green
}

function Configure-Path {
    Write-Section 'Configure PATH'
    Add-UserPathFront $PathBin
    Write-Host "Exposed commands: gcc, g++, gdb, cat" -ForegroundColor Green
}

function Write-VersionReport {
    Write-Section 'Version report'
    New-Item -ItemType Directory -Force -Path $TestDir | Out-Null
    $VersionReport = @('Contest commands', '----------------', 'C++      : g++', 'C        : gcc', 'Debugger : gdb', 'Text     : cat', '', 'Managed Python interpreter:', $PythonExe, '', 'g++ version:')
    $VersionReport += [string]((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'g++.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += ''
    $VersionReport += 'gcc version:'
    $VersionReport += [string]((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'gcc.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += ''
    $VersionReport += 'gdb version:'
    $VersionReport += [string]((Invoke-NativeChecked -FilePath (Join-Path $UcrtBin 'gdb.exe') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += ''
    $VersionReport += 'python version:'
    $VersionReport += [string]((Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'python.cmd') -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    $VersionReport += ''
    $VersionReport += 'cat version:'
    $VersionReport += [string]((Invoke-NativeChecked -FilePath $MsysCat -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)

    Write-LinesUtf8NoBom -Path (Join-Path $TestDir 'version-report.txt') -Lines ([string[]]$VersionReport)
    $VersionReport | ForEach-Object { Write-Host $_ }
}

function Invoke-WithMsysRuntimeChecked {
    param([Parameter(Mandatory = $true)] [string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$SuccessExitCodes = @(0), [switch]$Quiet)
    $OldPath = $env:Path
    try {
        $env:Path = "$UcrtBin;$(Split-Path $MsysBash -Parent);$OldPath"
        return Invoke-NativeChecked -FilePath $FilePath -ArgumentList $ArgumentList -SuccessExitCodes $SuccessExitCodes -Quiet:$Quiet
    } finally { $env:Path = $OldPath }
}

function Run-SmokeTests {
    Write-Section 'Compile and run tests'
    New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

    Write-LinesUtf8NoBom (Join-Path $TestDir 'cpp14.cpp') @('#include <iostream>', 'int main() { auto f = [](auto x) { return x + 14; }; std::cout << "CPP14 OK " << f(0) << "\n"; return 0; }')
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'g++14.cmd') -ArgumentList @((Join-Path $TestDir 'cpp14.cpp'), '-O2', '-o', (Join-Path $TestDir 'cpp14.exe')) -Quiet | Out-Null
    Assert-Output -Name 'C++14' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'cpp14.exe') -Quiet).Output) -join "`n") -Expected 'CPP14 OK 14'

    Write-LinesUtf8NoBom (Join-Path $TestDir 'cpp20.cpp') @('#include <concepts>', '#include <iostream>', 'template <std::integral T> T twice(T x) { return x * 2; }', 'int main() { std::cout << "CPP20 OK " << twice(10) << "\n"; return 0; }')
    Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'g++20.cmd') -ArgumentList @((Join-Path $TestDir 'cpp20.cpp'), '-O2', '-o', (Join-Path $TestDir 'cpp20.exe')) -Quiet | Out-Null
    Assert-Output -Name 'C++20' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath (Join-Path $TestDir 'cpp20.exe') -Quiet).Output) -join "`n") -Expected 'CPP20 OK 20'

    Write-LinesUtf8NoBom (Join-Path $TestDir 'python3_test.py') @('print("PYTHON3 OK 6")')
    Assert-Output -Name 'Python3' -Actual (((Invoke-NativeChecked -FilePath (Join-Path $ToolBin 'python3.cmd') -ArgumentList @((Join-Path $TestDir 'python3_test.py')) -Quiet).Output) -join "`n") -Expected 'PYTHON3 OK 6'
}

$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Finalizing Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Creating Wrappers..." -PercentComplete 10
Create-CommandWrappers

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Configuring PATH..." -PercentComplete 40
Configure-Path

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Generating Version Report..." -PercentComplete 70
Write-VersionReport

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status "Running Smoke Tests..." -PercentComplete 90
Run-SmokeTests

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
