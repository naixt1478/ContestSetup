# setup-wrappers.ps1
# ContestSetup v2.0 -- Clean @setlocal Command Wrappers, Non-Shadowing PATH Precedence & End-to-End Smoke Tests

function Assert-Output
{
  param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Actual,
    [Parameter(Mandatory = $true)] [string]$Expected
  )
  $A = $Actual.Trim()
  $E = $Expected.Trim()
  if ($A -ne $E)
  {
    throw "$Name test failed. Expected: [$E], Actual: [$A]"
  }
  Write-Host "$Name test passed: $A" -ForegroundColor Green
}

function Create-CommandWrappers
{
  Write-Section 'Create command wrappers'
  New-Item -ItemType Directory -Force -Path $ToolBin | Out-Null

  $MsysUsrBin = Split-Path $MsysBash -Parent
  $MsysToolPathLine = "set `"PATH=$UcrtBin;$MsysUsrBin;%PATH%`""

  # Include @setlocal so invoking wrappers in cmd.exe never leaks or grows %PATH% in the caller's session.
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++14.cmd')   @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++14 %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++17.cmd')   @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++17 %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++20.cmd')   @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" -std=gnu++20 %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'g++.cmd')     @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\g++.exe`" %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'gcc.cmd')     @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\gcc.exe`" %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'gdb.cmd')     @('@echo off', '@setlocal', $MsysToolPathLine, "`"$UcrtBin\gdb.exe`" %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'python.cmd')  @('@echo off', '@setlocal', "`"$PythonExe`" %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'python3.cmd') @('@echo off', '@setlocal', "`"$PythonExe`" %*")
  Write-LinesUtf8NoBom (Join-Path $ToolBin 'cat.cmd')     @('@echo off', '@setlocal', "`"$MsysCat`" %*")

  Write-Host 'Wrappers created with @setlocal.' -ForegroundColor Green
}

function Configure-Path
{
  Write-Section 'Configure PATH'
  Remove-ConflictingPathEntries
  $MsysUsrBin = Split-Path $MsysBash -Parent
  # Place $PythonDir, $UcrtBin, and $MsysUsrBin before $ToolBin so native .exe binaries (g++.exe, gcc.exe, gdb.exe, python.exe, python3.exe, cat.exe)
  # are resolved directly without .cmd batch wrapper shadowing, while g++14, g++17, g++20, and code resolve from $ToolBin.
  Add-UserPathsFront @($PythonDir, $UcrtBin, $MsysUsrBin, $ToolBin)
  Write-Host 'Exposed commands: python 3.10, python3, gcc, g++, gdb, cat, g++14, g++17, g++20, code' -ForegroundColor Green
}

function Get-CachedOrInvokeToolVersion
{
  param([Parameter(Mandatory = $true)] [string]$ToolPath)
  if ((Get-Variable -Name 'ContestToolVersions' -Scope Global -ErrorAction SilentlyContinue) -and ($Global:ContestToolVersions -is [hashtable]))
  {
    if ($Global:ContestToolVersions.ContainsKey($ToolPath) -and (-not [string]::IsNullOrWhiteSpace([string]$Global:ContestToolVersions[$ToolPath])))
    {
      return [string]$Global:ContestToolVersions[$ToolPath]
    }
  }
  $OldPath = $env:Path
  try
  {
    $env:Path = "$UcrtBin;$(Split-Path $MsysBash -Parent);$OldPath"
    $VerOut = [string]((Invoke-NativeChecked -FilePath $ToolPath -ArgumentList @('--version') -Quiet).Output | Select-Object -First 1)
    if ((Get-Variable -Name 'ContestToolVersions' -Scope Global -ErrorAction SilentlyContinue) -and ($Global:ContestToolVersions -is [hashtable]) -and (-not [string]::IsNullOrWhiteSpace($VerOut)))
    {
      $Global:ContestToolVersions[$ToolPath] = $VerOut
    }
    return $VerOut
  }
  finally
  {
    $env:Path = $OldPath
  }
}

function Write-VersionReport
{
  Write-Section 'Version report'
  New-Item -ItemType Directory -Force -Path $TestDir | Out-Null
  $VersionReport = @(
    'Contest commands',
    '----------------',
    'C++      : g++ (g++14, g++17, g++20)',
    'C        : gcc',
    'Debugger : gdb',
    'Text     : cat',
    'Python   : python, python3',
    'Editor   : code',
    '',
    'Managed Python interpreter:',
    $PythonExe,
    '',
    'g++ version:',
    (Get-CachedOrInvokeToolVersion -ToolPath (Join-Path $UcrtBin 'g++.exe')),
    '',
    'gcc version:',
    (Get-CachedOrInvokeToolVersion -ToolPath (Join-Path $UcrtBin 'gcc.exe')),
    '',
    'gdb version:',
    (Get-CachedOrInvokeToolVersion -ToolPath (Join-Path $UcrtBin 'gdb.exe')),
    '',
    'python version:',
    (Get-CachedOrInvokeToolVersion -ToolPath $PythonExe),
    '',
    'cat version:',
    (Get-CachedOrInvokeToolVersion -ToolPath $MsysCat)
  )

  Write-LinesUtf8NoBom -Path (Join-Path $TestDir 'version-report.txt') -Lines ([string[]]$VersionReport)
  $VersionReport | ForEach-Object { Write-Host $_ }
}

function Invoke-WithMsysRuntimeChecked
{
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int[]]$SuccessExitCodes = @(0),
    [switch]$Quiet
  )
  $OldPath = $env:Path
  try
  {
    $env:Path = "$UcrtBin;$(Split-Path $MsysBash -Parent);$OldPath"
    return Invoke-NativeChecked -FilePath $FilePath -ArgumentList $ArgumentList -SuccessExitCodes $SuccessExitCodes -Quiet:$Quiet
  }
  finally
  {
    $env:Path = $OldPath
  }
}

function Start-SmokeProcessAsync
{
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @()
  )
  $Ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
  $Psi = New-Object System.Diagnostics.ProcessStartInfo
  $Psi.UseShellExecute = $false
  $Psi.CreateNoWindow = $true
  $Psi.RedirectStandardOutput = $true
  $Psi.RedirectStandardError = $true
  try
  {
    $Psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  }
  catch {}

  if (($Ext -in @('.cmd', '.bat')) -and (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) -and (Test-Path -LiteralPath $env:ComSpec))
  {
    $Parts = @((Quote-ProcessArgument $FilePath))
    foreach ($ArgItem in $ArgumentList) { $Parts += (Quote-ProcessArgument $ArgItem) }
    $InnerCmd = $Parts -join ' '
    $Psi.FileName = $env:ComSpec
    $Psi.Arguments = "/d /s /c `"$InnerCmd`""
  }
  else
  {
    $Psi.FileName = $FilePath
    $Psi.Arguments = (($ArgumentList | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
  }

  $Proc = [System.Diagnostics.Process]::Start($Psi)
  $OutTask = $Proc.StandardOutput.ReadToEndAsync()
  $ErrTask = $Proc.StandardError.ReadToEndAsync()
  return [pscustomobject]@{
    Process  = $Proc
    OutTask  = $OutTask
    ErrTask  = $ErrTask
    FilePath = $FilePath
    Args     = $ArgumentList
  }
}

function Wait-SmokeProcessChecked
{
  param([Parameter(Mandatory = $true)] [object]$Handle)
  try
  {
    $Handle.Process.WaitForExit()
    $OutText = $Handle.OutTask.GetAwaiter().GetResult()
    $ErrText = $Handle.ErrTask.GetAwaiter().GetResult()
    $Code = [int]$Handle.Process.ExitCode
    if ($Code -ne 0)
    {
      throw "Smoke command failed (exit $Code): $($Handle.FilePath) $($Handle.Args -join ' ')`n$OutText`n$ErrText"
    }
    return [string]$OutText
  }
  finally
  {
    if ($Handle.Process) { $Handle.Process.Dispose() }
  }
}

function Assert-ContestCommandResolution
{
  Write-Section 'Verify PATH command resolution (Get-Command)'
  $CommandsToVerify = @('g++', 'g++14', 'g++17', 'g++20', 'gcc', 'gdb', 'python', 'python3', 'cat', 'code')
  $RootNorm = Normalize-PathForCompare $Root
  $MsysNorm = Normalize-PathForCompare $MsysRoot

  foreach ($CmdName in $CommandsToVerify)
  {
    $Resolved = Get-Command $CmdName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Resolved -or [string]::IsNullOrWhiteSpace($Resolved.Source))
    {
      throw "Command '$CmdName' could not be resolved from PATH."
    }
    $SourceNorm = Normalize-PathForCompare $Resolved.Source
    if (-not ($SourceNorm.StartsWith("$RootNorm\") -or $SourceNorm.StartsWith("$MsysNorm\")))
    {
      throw "Command '$CmdName' resolved to unexpected non-contest path: $($Resolved.Source)"
    }
    Write-Host ("Resolved {0,-8} -> {1}" -f $CmdName, $Resolved.Source) -ForegroundColor Green
  }
}

function Run-SmokeTests
{
  Write-Section 'Compile and run smoke tests'
  New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

  Assert-ContestCommandResolution

  $Cpp14Src = Join-Path $TestDir 'cpp14.cpp'
  $Cpp14Exe = Join-Path $TestDir 'cpp14.exe'
  $Cpp20Src = Join-Path $TestDir 'cpp20.cpp'
  $Cpp20Exe = Join-Path $TestDir 'cpp20.exe'
  $Py3Src = Join-Path $TestDir 'python3_test.py'

  Write-LinesUtf8NoBom $Cpp14Src @(
    '#include <iostream>',
    'int main() { auto f = [](auto x) { return x + 14; }; std::cout << "CPP14 OK " << f(0) << "\n"; return 0; }'
  )
  Write-LinesUtf8NoBom $Cpp20Src @(
    '#include <concepts>',
    '#include <iostream>',
    'template <std::integral T> T twice(T x) { return x * 2; }',
    'int main() { std::cout << "CPP20 OK " << twice(10) << "\n"; return 0; }'
  )
  Write-LinesUtf8NoBom $Py3Src @('print("PYTHON3 OK 6")')

  $Python3TestExe = if (Test-Path -LiteralPath $Python3Exe) { $Python3Exe } else { (Join-Path $ToolBin 'python3.cmd') }

  # Launch C++14 (-O0), C++20 (-O0), and Python3 smoke checks concurrently to cut cold/warm smoke latency
  $Cpp14BuildJob = Start-SmokeProcessAsync -FilePath (Join-Path $ToolBin 'g++14.cmd') -ArgumentList @($Cpp14Src, '-O0', '-o', $Cpp14Exe)
  $Cpp20BuildJob = Start-SmokeProcessAsync -FilePath (Join-Path $ToolBin 'g++20.cmd') -ArgumentList @($Cpp20Src, '-O0', '-o', $Cpp20Exe)
  $Py3RunJob = Start-SmokeProcessAsync -FilePath $Python3TestExe -ArgumentList @($Py3Src)

  Wait-SmokeProcessChecked -Handle $Cpp14BuildJob | Out-Null
  Wait-SmokeProcessChecked -Handle $Cpp20BuildJob | Out-Null
  $Py3Actual = Wait-SmokeProcessChecked -Handle $Py3RunJob

  Assert-Output -Name 'C++14' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath $Cpp14Exe -Quiet).Output) -join "`n") -Expected 'CPP14 OK 14'
  Assert-Output -Name 'C++20' -Actual (((Invoke-WithMsysRuntimeChecked -FilePath $Cpp20Exe -Quiet).Output) -join "`n") -Expected 'CPP20 OK 20'
  Assert-Output -Name 'Python3' -Actual $Py3Actual -Expected 'PYTHON3 OK 6'
}

$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] Finalizing Setup"
Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Creating Wrappers...' -PercentComplete 10
Create-CommandWrappers

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Configuring PATH...' -PercentComplete 40
Configure-Path

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Generating Version Report...' -PercentComplete 70
Write-VersionReport

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Status 'Running Smoke Tests...' -PercentComplete 90
Run-SmokeTests

Write-Progress -Id $Global:ProgressIdInner -ParentId $Global:ProgressIdOuter -Activity $PA -Completed
