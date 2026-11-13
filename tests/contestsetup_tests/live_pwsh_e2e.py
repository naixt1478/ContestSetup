#!/usr/bin/env python3
"""Tier 5 Live PowerShell 7.4+ Environment Setup E2E Suite (T5_35-T5_41)."""
from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import List

from . import EXPECTED_LIB_PS1_FILES, PS1_FILES, REPO_ROOT, TestCase, TestSkipped, find_pwsh, make_registrar
from .inspector import PowerShellInspector
from .simulator import BehavioralSimulator

# Shared PowerShell helper snippet that loads functions and top-level variable assignments
# from any target .ps1 script (plus any Import-ContestLibraryModule dependencies) via AST
# into global/script scope without executing top-level UAC elevation or destructive entrypoint logic.
PWSH_AST_FUNCTION_LOADER = r"""
$global:PSNativeCommandUseErrorActionPreference = $false
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Register-AstDefinitionsToGlobal {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$ScriptDir = '',
        [string[]]$AllowVariableNames = @()
    )
    if ($null -eq $Ast.EndBlock) { return }
    foreach ($stmt in $Ast.EndBlock.Statements) {
        if ($stmt -is [System.Management.Automation.Language.PipelineAst]) {
            $cmdText = $stmt.Extent.Text.Trim()
            if ($cmdText -match "^Import-ContestLibraryModule\s+(?:-ModuleName\s+)?['`"]([^'`"]+)['`"]") {
                $modName = $Matches[1]
                $modPath = Join-Path (Join-Path $ScriptDir 'lib') $modName
                if (Test-Path -LiteralPath $modPath) {
                    $mTokens = $null
                    $mErrors = $null
                    $mAst = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$mTokens, [ref]$mErrors)
                    if ($mErrors.Count -gt 0) {
                        throw "AST parse error in ${modPath}: $($mErrors[0].Message)"
                    }
                    Register-AstDefinitionsToGlobal -Ast $mAst -ScriptDir $ScriptDir -AllowVariableNames $AllowVariableNames
                }
            }
        } elseif ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            if ($stmt.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $varPath = $stmt.Left.VariablePath
                $varName = $varPath.UserPath
                $bareName = ($varName -replace '^(?i)(script|global|local|private):', '')
                if (($AllowVariableNames -contains $bareName) -or ($varName -match '^(?i)script:')) {
                    . ([scriptblock]::Create($stmt.Extent.Text))
                    $val = Get-Variable -Name $bareName -ErrorAction SilentlyContinue
                    if ($null -ne $val) {
                        Set-Variable -Name $bareName -Value $val.Value -Scope Global
                        Set-Variable -Name $bareName -Value $val.Value -Scope Script
                    }
                }
            }
        } elseif ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($stmt.Extent.Text))
            $fnItem = Get-Item -LiteralPath "Function:\$($stmt.Name)" -ErrorAction SilentlyContinue
            if ($null -ne $fnItem) {
                Set-Item -Path "Function:\global:$($stmt.Name)" -Value $fnItem.ScriptBlock
                Set-Item -Path "Function:\script:$($stmt.Name)" -Value $fnItem.ScriptBlock
            }
        }
    }
}

function Import-ContestScriptFunctionsAst {
    param(
        [Parameter(Mandatory = $true)] [string]$ScriptPath,
        [string[]]$AllowVariableNames = @()
    )
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "AST parse error in ${ScriptPath}: $($errors[0].Message)"
    }
    $scriptDir = Split-Path -Parent $ScriptPath
    Register-AstDefinitionsToGlobal -Ast $ast -ScriptDir $scriptDir -AllowVariableNames $AllowVariableNames
}
"""


def _run_pwsh_script(pwsh: str, ps_code: str, prefix: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
        script_file = Path(tmp) / "live_e2e_probe.ps1"
        script_file.write_text(PWSH_AST_FUNCTION_LOADER + "\n" + ps_code, encoding="utf-8")
        env = dict(os.environ, CS_REPO_ROOT=str(REPO_ROOT))
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script_file)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=180,
            env=env,
        )


def register_tests(ps: PowerShellInspector, sim: BehavioralSimulator, repo_root: Path) -> List[TestCase]:
    tests: List[TestCase] = []
    register = make_registrar(tests)

    @register("T5_35", 5, "F2+F3+F18", "Live pwsh E2E: common.ps1 + lib/ KST/UTC schedule validation, state manifest round-trip, and Invoke-ContestEnvironmentAudit Fail->Pass")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_35 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_35_root_") as tmp_root:
            root_path = Path(tmp_root) / "CPTools"
            hosts_file = Path(tmp_root) / "hosts"

            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$MsysRoot = Join-Path $Root 'msys64'
$Mode = 'Verify'
$ContestHostsPathOverride = $env:CS_TEST_HOSTS
$env:CONTEST_HOSTS_PATH_OVERRIDE = $env:CS_TEST_HOSTS

. (Join-Path $env:CS_REPO_ROOT 'common.ps1')

# Mock Get-ScheduledTask before step 3 so empty-root audit is deterministic on both Windows and Linux
$script:SimTaskReady = $false
$mockGetScheduledTask = {
    param([string]$TaskName, $ErrorAction)
    if ($script:SimTaskReady -and $TaskName -eq 'ContestSetupRestoreAndCleanup') {
        return [pscustomobject]@{
            TaskName = $TaskName
            State    = 'Ready'
            Triggers = @([pscustomobject]@{ StartBoundary = '2026-11-23T20:30:00+09:00' })
        }
    }
    return $null
}
Set-Item -Path 'Function:\global:Get-ScheduledTask' -Value $mockGetScheduledTask
Set-Item -Path 'Function:\script:Get-ScheduledTask' -Value $mockGetScheduledTask

# 1. Verify Test-ExamScheduleConfiguration with KST (+09:00) and UTC (Z)
$schedKst = Test-ExamScheduleConfiguration -StartText '2026-11-23T19:00:00+09:00' -EndText '2026-11-23T20:30:00+09:00' -RestoreText '2026-11-23T20:30:00+09:00'
$schedUtc = Test-ExamScheduleConfiguration -StartText '2026-11-23T10:00:00Z' -EndText '2026-11-23T11:30:00Z' -RestoreText '2026-11-23T11:30:00Z'
if ([int][math]::Round($schedKst.DurationMinutes) -ne 90) { throw "Unexpected KST duration: $($schedKst.DurationMinutes)" }
if ($schedKst.ExamStartDto.ToUniversalTime() -ne $schedUtc.ExamStartDto.ToUniversalTime()) { throw "KST vs UTC instant mismatch" }

$invertedCaught = $false
try {
    Test-ExamScheduleConfiguration -StartText '2026-11-23T20:30:00+09:00' -EndText '2026-11-23T19:00:00+09:00' -RestoreText '2026-11-23T20:30:00+09:00' | Out-Null
} catch {
    $invertedCaught = $true
}
if (-not $invertedCaught) { throw "Expected Test-ExamScheduleConfiguration to reject ExamEnd <= ExamStart" }

# 2. Verify Update-ContestStateManifest & Read-ContestStateManifest round-trip
Update-ContestStateManifest -CompletedModule 'setup-msys2.ps1' -ExtraFields @{ PythonInstalledByContestSetup = $true; CustomMarker = 'E2E_OK' }
Update-ContestStateManifest -CompletedModule 'setup-vscode.ps1'
$man = Read-ContestStateManifest
$mods = @($man['CompletedModules'])
if (($mods -notcontains 'setup-msys2.ps1') -or ($mods -notcontains 'setup-vscode.ps1') -or ([bool]$man['PythonInstalledByContestSetup'] -ne $true) -or ([string]$man['CustomMarker'] -ne 'E2E_OK')) {
    throw "State manifest round-trip failed: $($man | ConvertTo-Json -Compress)"
}

# 3. Audit on empty root MUST return AllReady = $false
$auditEmpty = Invoke-ContestEnvironmentAudit
if ($auditEmpty.AllReady -ne $false) { throw "Expected AllReady=$false on unprovisioned root" }
$emptyReadyCount = @($auditEmpty.Checks | Where-Object { $_.Ready }).Count

# 4. Seed complete 7-component contest environment and verify AllReady = $true under -Mode Verify
New-Item -ItemType Directory -Force -Path $UcrtBin, $MsysUsrBin, $PythonDir, $ToolBin | Out-Null
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    $stubExe = Join-Path $Root 'ok_stub.exe'
    $stubCs = Join-Path $Root 'ok_stub.cs'
    Write-TextUtf8NoBom -Path $stubCs -Content 'public static class P { public static int Main(string[] a) { System.Console.WriteLine("ContestSetup Stub 1.0"); return 0; } }'
    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $cscExe = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($null -ne $cscExe) {
        & $cscExe /nologo /target:exe "/out:$stubExe" $stubCs | Out-Null
    } else {
        $stubCpp = Join-Path $Root 'ok_stub.cpp'
        Write-TextUtf8NoBom -Path $stubCpp -Content '#include <stdio.h>`nint main(){puts("ContestSetup Stub 1.0");return 0;}'
        & g++ -O2 -static $stubCpp -o $stubExe | Out-Null
    }
    if (-not (Test-Path -LiteralPath $stubExe)) {
        throw "Failed to build Windows ok_stub.exe for T5_35"
    }
    foreach ($destBin in @(
        (Join-Path $UcrtBin 'g++.exe'),
        (Join-Path $UcrtBin 'gcc.exe'),
        (Join-Path $UcrtBin 'gdb.exe'),
        $MsysCat,
        $PythonExe,
        $Python3Exe
    )) {
        Copy-Item -LiteralPath $stubExe -Destination $destBin -Force
    }
} else {
    $hostGpp = (Get-Command g++ -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $hostGcc = (Get-Command gcc -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $hostCat = (Get-Command cat -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $hostPy3 = (Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Write-TextUtf8NoBom -Path (Join-Path $UcrtBin 'g++.exe') -Content "#!/bin/sh`nexec `"$hostGpp`" `"`$@`"`n"
    Write-TextUtf8NoBom -Path (Join-Path $UcrtBin 'gcc.exe') -Content "#!/bin/sh`nexec `"$hostGcc`" `"`$@`"`n"
    Write-TextUtf8NoBom -Path (Join-Path $UcrtBin 'gdb.exe') -Content "#!/bin/sh`necho 'GNU gdb (ContestSetup E2E) 14.2'`nexit 0`n"
    Write-TextUtf8NoBom -Path $MsysCat -Content "#!/bin/sh`nexec `"$hostCat`" `"`$@`"`n"
    Write-TextUtf8NoBom -Path $PythonExe -Content "#!/bin/sh`nexec `"$hostPy3`" `"`$@`"`n"
    Write-TextUtf8NoBom -Path $Python3Exe -Content "#!/bin/sh`nexec `"$hostPy3`" `"`$@`"`n"
    & chmod +x (Join-Path $UcrtBin 'g++.exe') (Join-Path $UcrtBin 'gcc.exe') (Join-Path $UcrtBin 'gdb.exe') $MsysCat $PythonExe $Python3Exe
}

# VS Code 1.97+ layout & locked Marketplace product.json
$vscCommitDir = Join-Path $Root 'vscode/e54c774e0add60467559eb0d1e229c6452cf8447/resources/app'
New-Item -ItemType Directory -Force -Path $vscCommitDir, (Join-Path $Root 'vscode/bin') | Out-Null
Write-TextUtf8NoBom -Path (Join-Path $Root 'vscode/Code.exe') -Content 'stub'
Write-TextUtf8NoBom -Path (Join-Path $Root 'vscode/bin/code.cmd') -Content '@echo off'
Write-JsonUtf8NoBom -Path (Join-Path $vscCommitDir 'product.json') -InputObject @{
    nameShort = 'Code'
    extensionsGallery = @{
        serviceUrl = 'https://127.0.0.1'
        itemUrl    = 'https://127.0.0.1'
    }
}

# VS Code extensions, locale=ko, AI settings, and workspace configs
foreach ($extFolder in @(
    'ms-ceintl.vscode-language-pack-ko-1.95.0',
    'ms-vscode.cpptools-1.22.10',
    'ms-python.python-2024.20.0',
    'ms-python.debugpy-2024.12.0'
)) {
    New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $Root 'vscode-contest/extensions') $extFolder) | Out-Null
}
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'vscode/data/extensions') | Out-Null
Write-JsonUtf8NoBom -Path (Join-Path $Root 'vscode-contest/user-data/argv.json') -InputObject @{ locale = 'ko' }
Write-JsonUtf8NoBom -Path (Join-Path $Root 'vscode/data/argv.json') -InputObject @{ locale = 'ko' }
Write-JsonUtf8NoBom -Path (Join-Path $Root 'vscode-contest/user-data/User/settings.json') -InputObject @{ 'chat.disableAIFeatures' = $true }
foreach ($cfg in @('tasks.json', 'c_cpp_properties.json', 'launch.json')) {
    Write-JsonUtf8NoBom -Path (Join-Path (Join-Path $Root 'contest/.vscode') $cfg) -InputObject @{ version = '2.0.0' }
}

# 10 CLI wrappers
foreach ($w in @('g++14.cmd', 'g++17.cmd', 'g++20.cmd', 'g++.cmd', 'gcc.cmd', 'gdb.cmd', 'python.cmd', 'python3.cmd', 'cat.cmd', 'code.cmd')) {
    Write-TextUtf8NoBom -Path (Join-Path $ToolBin $w) -Content '@echo off'
}

# Hosts file with >=100 active rules + IPv4/IPv6 sentinels
$hostLines = @('127.0.0.1 localhost', '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN', '0.0.0.0 chatgpt.com', ':: chatgpt.com', '0.0.0.0 claude.ai', ':: claude.ai')
for ($i = 1; $i -le 60; $i++) {
    $hostLines += "0.0.0.0 ai-model-$i.example.com"
    $hostLines += ":: ai-model-$i.example.com"
}
$hostLines += '# <<< CP_CONTEST_AI_BLOCKLIST_END'
Write-LinesUtf8NoBom -Path $env:CS_TEST_HOSTS -Lines ([string[]]$hostLines)

$script:SimTaskReady = $true

$auditReady = Invoke-ContestEnvironmentAudit
$readyCount = @($auditReady.Checks | Where-Object { $_.Ready }).Count
if (-not $auditReady.AllReady -or $readyCount -ne 7) {
    $failedDetails = @($auditReady.Checks | Where-Object { -not $_.Ready } | ForEach-Object { "$($_.Component): $($_.Detail)" }) -join ' | '
    throw "Expected AllReady=$true (7/7), got AllReady=$($auditReady.AllReady) ($readyCount/7): $failedDetails"
}
Write-Output "T5_35_OK:EMPTY_READY=$emptyReadyCount|FULL_READY=$readyCount|ALL_READY=$($auditReady.AllReady)"
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_35_",
                extra_env={
                    "CS_TEST_ROOT": str(root_path),
                    "CS_TEST_HOSTS": str(hosts_file),
                },
            )
            assert res.returncode == 0, f"T5_35 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "T5_35_OK:EMPTY_READY=0|FULL_READY=7|ALL_READY=True" in res.stdout, f"Unexpected T5_35 output: {res.stdout}"

    @register("T5_36", 5, "F9+F19", "Live pwsh E2E: setup-vscode.ps1 isolated profile, AI lockdown, Korean locale, extension purge, Marketplace lock/restore idempotency, and workspace configs")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_36 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_36_vsc_") as tmp_root:
            root_path = Path(tmp_root) / "CPTools"
            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$MsysRoot = Join-Path $Root 'msys64'
$ContestWorkspaceDir = Join-Path $Root 'contest'
. (Join-Path $env:CS_REPO_ROOT 'common.ps1')
Import-ContestScriptFunctionsAst -ScriptPath (Join-Path $env:CS_REPO_ROOT 'setup-vscode.ps1')

$vscRoot = Join-Path $Root 'vscode'
$commitId = 'deadbeef9876543210abcdef'
$commitAppDir = Join-Path $vscRoot "$commitId/resources/app"
New-Item -ItemType Directory -Force -Path $commitAppDir, (Join-Path $vscRoot 'bin'), $UcrtBin, $MsysUsrBin, $PythonDir, $ToolBin | Out-Null
Write-TextUtf8NoBom -Path (Join-Path $vscRoot 'Code.exe') -Content 'stub'
$codeCmdFile = Join-Path $vscRoot 'bin/code.cmd'
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    Write-TextUtf8NoBom -Path $codeCmdFile -Content ("@echo off`r`nrem " + '"%~dp0..\Code.exe" "%~dp0..\' + $commitId + '\resources\app\out\cli.js" %*' + "`r`nexit /b 0`r`n")
} else {
    Write-TextUtf8NoBom -Path $codeCmdFile -Content ("#!/bin/sh`n# " + '"%~dp0..\Code.exe" "%~dp0..\' + $commitId + '\resources\app\out\cli.js" %*' + "`nexit 0`n")
    & chmod +x $codeCmdFile
}

$origProduct = @{
    nameShort = 'Code'
    extensionsGallery = @{
        serviceUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery'
        itemUrl    = 'https://marketplace.visualstudio.com/items'
        cacheUrl   = 'https://vscode.blob.core.windows.net/gallery/index'
    }
}
$productJsonPath = Join-Path $commitAppDir 'product.json'
Write-JsonUtf8NoBom -Path $productJsonPath -InputObject $origProduct

# Initialize isolated contest & portable directories
Initialize-ContestVSCodeIsolated

# Seed 4 allowed extensions + decoy blocked extension github.copilot-1.200.0 in BOTH contest & portable extension dirs
$extDir = Get-ContestVSCodeExtensionsDir
$portExtDir = Join-Path (Get-PortableVSCodeDataDir) 'extensions'
foreach ($allowed in @(
    'ms-ceintl.vscode-language-pack-ko-1.95.0',
    'ms-vscode.cpptools-1.22.10',
    'ms-python.python-2024.20.0',
    'ms-python.debugpy-2024.12.0'
)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $extDir $allowed) | Out-Null
}
$blockedContest = Join-Path $extDir 'github.copilot-1.200.0'
$blockedPortable = Join-Path $portExtDir 'anthropic.claude-code-0.2.0'
New-Item -ItemType Directory -Force -Path $blockedContest, $blockedPortable | Out-Null

# Execute live setup-vscode functions
$Script:InstalledVSCodeExtensionsCache = @()
Set-VSCodeAiHiddenSettings
Set-VSCodeDisplayLanguageKorean
Remove-BlockedVSCodeExtensions

# Marketplace lock -> restore -> lock idempotency cycle
Disable-VSCodeMarketplace
Disable-VSCodeMarketplace
$lockedObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $productJsonPath)
if ($lockedObj.extensionsGallery.serviceUrl -ne 'https://127.0.0.1' -or $lockedObj.extensionsGallery.itemUrl -ne 'https://127.0.0.1') {
    throw "Marketplace lock failed"
}
if (-not (Test-Path -LiteralPath "$productJsonPath.contest-orig")) {
    throw "Missing product.json.contest-orig backup"
}
Restore-VSCodeMarketplace
$restoredObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $productJsonPath)
if ($restoredObj.extensionsGallery.serviceUrl -notmatch 'marketplace\.visualstudio\.com') {
    throw "Restore-VSCodeMarketplace failed to restore original serviceUrl"
}
Disable-VSCodeMarketplace

# Workspace defaults (.vscode/{tasks,launch,c_cpp_properties}.json)
Set-ContestVSCodeWorkspaceDefaults

# Verify blocked extensions deleted and 4 allowed kept
if ((Test-Path -LiteralPath $blockedContest) -or (Test-Path -LiteralPath $blockedPortable)) {
    throw "Blocked extensions were not purged"
}
$keptExts = @(Get-ChildItem -LiteralPath $extDir -Directory | Select-Object -ExpandProperty Name)
if ($keptExts.Count -ne 4) {
    throw "Expected 4 allowed extensions kept, got $($keptExts.Count)"
}

# Verify argv.json locale=ko in both contest & portable data dirs
$argvContest = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path (Join-Path (Get-ContestVSCodeUserDataDir) 'argv.json'))
$argvPortable = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path (Join-Path (Get-PortableVSCodeDataDir) 'argv.json'))
if ($argvContest.locale -ne 'ko' -or $argvPortable.locale -ne 'ko') {
    throw "argv.json locale != ko"
}

$wsVsc = Join-Path $ContestWorkspaceDir '.vscode'
$tasksObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path (Join-Path $wsVsc 'tasks.json'))
$launchObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path (Join-Path $wsVsc 'launch.json'))
$cppObj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path (Join-Path $wsVsc 'c_cpp_properties.json'))
if ($null -eq $tasksObj -or $null -eq $launchObj -or $null -eq $cppObj) {
    throw "Workspace .vscode JSON files failed to parse"
}

Write-Output ("T5_36_OK:KEPT={0}|LOCALE={1}/{2}|SVC={3}" -f $keptExts.Count, $argvContest.locale, $argvPortable.locale, $lockedObj.extensionsGallery.serviceUrl)
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_36_",
                extra_env={"CS_TEST_ROOT": str(root_path)},
            )
            assert res.returncode == 0, f"T5_36 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "T5_36_OK:KEPT=4|LOCALE=ko/ko|SVC=https://127.0.0.1" in res.stdout, f"Unexpected T5_36 output: {res.stdout}"

    @register("T5_37", 5, "F10", "Live pwsh E2E: setup-wrappers.ps1 generates 9 .cmd wrappers + compiles & executes real C++14, C++20, and Python3 programs")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_37 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_37_wrap_") as tmp_root:
            root_path = Path(tmp_root) / "CPTools"
            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$MsysRoot = Join-Path $Root 'msys64'
$ContestWorkspaceDir = Join-Path $Root 'contest'
. (Join-Path $env:CS_REPO_ROOT 'common.ps1')
Import-ContestScriptFunctionsAst -ScriptPath (Join-Path $env:CS_REPO_ROOT 'setup-wrappers.ps1')

New-Item -ItemType Directory -Force -Path $UcrtBin, $MsysUsrBin, $PythonDir, $ToolBin, $ContestWorkspaceDir | Out-Null
$onWin = ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
if ($onWin) {
    $gppCandidates = @(
        'C:\msys64\ucrt64\bin\g++.exe',
        'C:\msys64\mingw64\bin\g++.exe',
        'C:\mingw64\bin\g++.exe',
        (Get-Command g++ -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    $realGpp = $gppCandidates | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($realGpp)) { throw "No g++.exe found on Windows runner" }
    $realPy = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($realPy)) {
        $realPy = (Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if ([string]::IsNullOrWhiteSpace($realPy)) { throw "No python found on Windows runner" }
} else {
    Write-TextUtf8NoBom -Path (Join-Path $UcrtBin 'g++.exe') -Content "#!/bin/sh`nexec /usr/bin/g++ `"`$@`"`n"
    Write-TextUtf8NoBom -Path (Join-Path $UcrtBin 'gcc.exe') -Content "#!/bin/sh`nexec /usr/bin/gcc `"`$@`"`n"
    Write-TextUtf8NoBom -Path $MsysCat -Content "#!/bin/sh`nexec /bin/cat `"`$@`"`n"
    Write-TextUtf8NoBom -Path $PythonExe -Content "#!/bin/sh`nexec /usr/bin/python3 `"`$@`"`n"
    Write-TextUtf8NoBom -Path $Python3Exe -Content "#!/bin/sh`nexec /usr/bin/python3 `"`$@`"`n"
    & chmod +x (Join-Path $UcrtBin 'g++.exe') (Join-Path $UcrtBin 'gcc.exe') $MsysCat $PythonExe $Python3Exe
    $realGpp = Join-Path $UcrtBin 'g++.exe'
    $realPy = $Python3Exe
}

Create-CommandWrappers

$expectedCmds = @('g++14.cmd', 'g++17.cmd', 'g++20.cmd', 'g++.cmd', 'gcc.cmd', 'gdb.cmd', 'python.cmd', 'python3.cmd', 'cat.cmd')
foreach ($cmdName in $expectedCmds) {
    $cmdPath = Join-Path $ToolBin $cmdName
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        throw "Missing generated wrapper: $cmdPath"
    }
    $raw = Read-TextUtf8 -Path $cmdPath
    if ($raw -notmatch '@setlocal') {
        throw "$cmdName missing @setlocal"
    }
    if ($cmdName -notin @('python.cmd', 'python3.cmd', 'cat.cmd') -and $raw -notmatch 'set "PATH=.*%PATH%"') {
        throw "$cmdName missing non-shadowing PATH prepend"
    }
}

# Extract the compiler flags from generated g++14.cmd and g++20.cmd and compile + run real C++14, C++20, and Python3 solutions in $ContestWorkspaceDir
$cpp14Src = Join-Path $ContestWorkspaceDir 'solve14.cpp'
$cpp14Out = Join-Path $ContestWorkspaceDir 'solve14.exe'
Write-TextUtf8NoBom -Path $cpp14Src -Content @"
#include <iostream>
int main() {
    auto mul = [](auto a, auto b) { return a * b; };
    std::cout << "CPP14_OK:" << mul(6, 7) << "\n";
    return 0;
}
"@

$cpp20Src = Join-Path $ContestWorkspaceDir 'solve20.cpp'
$cpp20Out = Join-Path $ContestWorkspaceDir 'solve20.exe'
Write-TextUtf8NoBom -Path $cpp20Src -Content @"
#include <iostream>
#include <concepts>
template <std::integral T>
constexpr T tri(T n) { return n * (n + 1) / 2; }
int main() {
    std::cout << "CPP20_OK:" << tri(10) << "\n";
    return 0;
}
"@

$pySrc = Join-Path $ContestWorkspaceDir 'solve.py'
Write-TextUtf8NoBom -Path $pySrc -Content @"
import sys
print(f"PY3_OK:{sum(i * i * i for i in range(1, 11))}")
"@

$gpp14CmdLine = (Read-LinesUtf8 -Path (Join-Path $ToolBin 'g++14.cmd'))[-1]
$gpp20CmdLine = (Read-LinesUtf8 -Path (Join-Path $ToolBin 'g++20.cmd'))[-1]
if ($gpp14CmdLine -notmatch '-std=gnu\+\+14' -or $gpp20CmdLine -notmatch '-std=gnu\+\+20') {
    throw "Wrapper C++ standard flags missing"
}

$origEnvPath = $env:Path
try {
    if ($onWin) {
        $gppBinDir = Split-Path -Parent $realGpp
        $env:Path = "$gppBinDir;$origEnvPath"
    }
    $c14Res = Invoke-NativeCommand -FilePath $realGpp -ArgumentList @('-std=gnu++14', '-O2', '-Wall', '-Wextra', '-pedantic', $cpp14Src, '-o', $cpp14Out) -Quiet
    if ($c14Res.ExitCode -ne 0) { throw "C++14 compile failed: $($c14Res.Output -join ' ')" }
    $r14Res = Invoke-NativeCommand -FilePath $cpp14Out -ArgumentList @() -Quiet
    if ($r14Res.ExitCode -ne 0) { throw "C++14 run failed" }

    $c20Res = Invoke-NativeCommand -FilePath $realGpp -ArgumentList @('-std=gnu++20', '-O2', '-Wall', '-Wextra', '-pedantic', $cpp20Src, '-o', $cpp20Out) -Quiet
    if ($c20Res.ExitCode -ne 0) { throw "C++20 compile failed: $($c20Res.Output -join ' ')" }
    $r20Res = Invoke-NativeCommand -FilePath $cpp20Out -ArgumentList @() -Quiet
    if ($r20Res.ExitCode -ne 0) { throw "C++20 run failed" }

    $pyRes = Invoke-NativeCommand -FilePath $realPy -ArgumentList @($pySrc) -Quiet
    if ($pyRes.ExitCode -ne 0) { throw "Python3 run failed" }
} finally {
    $env:Path = $origEnvPath
}

Write-Output ("T5_37_OK:{0}|{1}|{2}" -f ($r14Res.Output -join '').Trim(), ($r20Res.Output -join '').Trim(), ($pyRes.Output -join '').Trim())
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_37_",
                extra_env={"CS_TEST_ROOT": str(root_path)},
            )
            assert res.returncode == 0, f"T5_37 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "T5_37_OK:CPP14_OK:42|CPP20_OK:55|PY3_OK:3025" in res.stdout, f"Unexpected T5_37 output: {res.stdout}"

    @register("T5_38", 5, "F3+F5+F20", "Live pwsh E2E: Test-ValidCachedInstallerFile magic-byte/size validation, Copy-FromCacheDirIfPresent, and Seed-Msys2PackageCacheFromCacheDir")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_38 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_38_cache_") as tmp_root:
            root_path = Path(tmp_root) / "CPTools"
            cache_dir = Path(tmp_root) / "OfflineBundle"
            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$CacheDir = $env:CS_TEST_CACHE
$MsysRoot = Join-Path $Root 'msys64'
. (Join-Path $env:CS_REPO_ROOT 'common.ps1')
Import-ContestScriptFunctionsAst -ScriptPath (Join-Path $env:CS_REPO_ROOT 'setup-msys2.ps1')

New-Item -ItemType Directory -Force -Path $CacheDir, $DownloadDir | Out-Null

# 1. Create captive-portal HTML decoy, truncated MZ decoy, valid MZ .exe, and valid PK .zip/.vsix
$htmlDecoy = Join-Path $CacheDir 'captive.exe'
[System.IO.File]::WriteAllBytes($htmlDecoy, [System.Text.Encoding]::UTF8.GetBytes(('<!DOCTYPE html><html>Login</html>' * 200)))

$truncExe = Join-Path $CacheDir 'truncated.exe'
$truncBytes = New-Object byte[] 512
$truncBytes[0] = 0x4D; $truncBytes[1] = 0x5A
[System.IO.File]::WriteAllBytes($truncExe, $truncBytes)

$validExe = Join-Path (Join-Path $CacheDir 'installers') 'python-3.10.11-amd64.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $validExe) | Out-Null
$exeBytes = New-Object byte[] 8192
$exeBytes[0] = 0x4D; $exeBytes[1] = 0x5A
[System.IO.File]::WriteAllBytes($validExe, $exeBytes)

$validZip = Join-Path (Join-Path $CacheDir 'installers') 'vscode-win32-x64-archive.zip'
$zipBytes = New-Object byte[] 8192
$zipBytes[0] = 0x50; $zipBytes[1] = 0x4B; $zipBytes[2] = 0x03; $zipBytes[3] = 0x04
[System.IO.File]::WriteAllBytes($validZip, $zipBytes)

if (Test-ValidCachedInstallerFile -Path $htmlDecoy -MinBytes 1024) { throw "Accepted HTML decoy" }
if (Test-ValidCachedInstallerFile -Path $truncExe -MinBytes 4096) { throw "Accepted truncated exe" }
if (-not (Test-ValidCachedInstallerFile -Path $validExe -MinBytes 4096)) { throw "Rejected valid MZ exe" }
if (-not (Test-ValidCachedInstallerFile -Path $validZip -MinBytes 4096)) { throw "Rejected valid PK zip" }

# 2. Copy-FromCacheDirIfPresent copies from $CacheDir/installers to $DownloadDir
$destExe = Join-Path $DownloadDir 'python-3.10.11-amd64.exe'
$copied = Copy-FromCacheDirIfPresent -OutFile $destExe -MinBytes 4096
if (-not $copied -or -not (Test-Path -LiteralPath $destExe)) {
    throw "Copy-FromCacheDirIfPresent failed to copy valid installer from CacheDir/installers"
}

# 3. Seed-Msys2PackageCacheFromCacheDir: overwrites stale sync .db, copies .pkg.tar.zst, excludes .sig from count
$cachePkgDir = Join-Path $CacheDir 'msys2-pkg'
$cacheSyncDir = Join-Path $CacheDir 'msys2-sync'
$destPkgDir = Join-Path $MsysRoot 'var/cache/pacman/pkg'
$destSyncDir = Join-Path $MsysRoot 'var/lib/pacman/sync'
New-Item -ItemType Directory -Force -Path $cachePkgDir, $cacheSyncDir, $destPkgDir, $destSyncDir | Out-Null

Write-TextUtf8NoBom -Path (Join-Path $destSyncDir 'ucrt64.db') -Content 'STALE_DB'
Write-TextUtf8NoBom -Path (Join-Path $cacheSyncDir 'ucrt64.db') -Content 'FRESH_EXPORTED_DB'
Write-TextUtf8NoBom -Path (Join-Path $cachePkgDir 'mingw-w64-ucrt-x86_64-gcc-14.2.0-1-any.pkg.tar.zst') -Content 'PKG_ZST_1'
Write-TextUtf8NoBom -Path (Join-Path $cachePkgDir 'mingw-w64-ucrt-x86_64-gdb-15.1-1-any.pkg.tar.zst') -Content 'PKG_ZST_2'
Write-TextUtf8NoBom -Path (Join-Path $cachePkgDir 'mingw-w64-ucrt-x86_64-gcc-14.2.0-1-any.pkg.tar.zst.sig') -Content 'DETACHED_SIG'

$seededOk = Seed-Msys2PackageCacheFromCacheDir
$syncedDbText = Read-TextUtf8 -Path (Join-Path $destSyncDir 'ucrt64.db')
$destArchives = @(Get-ChildItem -LiteralPath $destPkgDir -File | Where-Object { $_.Name -notlike '*.sig' })
if (-not $seededOk -or $syncedDbText.Trim() -ne 'FRESH_EXPORTED_DB' -or $destArchives.Count -ne 2) {
    throw "Seed-Msys2PackageCacheFromCacheDir failed: seeded=$seededOk db=$syncedDbText count=$($destArchives.Count)"
}

Write-Output ("T5_38_OK:COPIED={0}|SEEDED={1}|DB={2}|ARCHIVES={3}" -f $copied, $seededOk, $syncedDbText.Trim(), $destArchives.Count)
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_38_",
                extra_env={"CS_TEST_ROOT": str(root_path), "CS_TEST_CACHE": str(cache_dir)},
            )
            assert res.returncode == 0, f"T5_38 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "T5_38_OK:COPIED=True|SEEDED=True|DB=FRESH_EXPORTED_DB|ARCHIVES=2" in res.stdout, f"Unexpected T5_38 output: {res.stdout}"

    @register("T5_39", 5, "F11+F22", "Live pwsh E2E: ai-hosts-block.ps1 idempotent hosts apply/restore preserving custom judge host + 22 browser policy specs")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_39 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_39_hosts_") as tmp_root:
            hosts_path = Path(tmp_root) / "hosts"
            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$MsysRoot = Join-Path $Root 'msys64'
. (Join-Path $env:CS_REPO_ROOT 'common.ps1')
Import-ContestScriptFunctionsAst -ScriptPath (Join-Path $env:CS_REPO_ROOT 'ai-hosts-block.ps1') -AllowVariableNames @(
    'DefaultAiBlockDomains', 'BeginMarker', 'EndMarker', 'DefaultExamEndKstIso', 'DefaultBlockDurationHours'
)

$BlocklistUrl = ''
$BlockListUrl = ''
$BlocklistFile = ''
$BlockListPath = ''
$DomainListPath = ''
$DomainListUrl = ''
$RawListPath = Join-Path $Root 'ai-domains-raw.txt'
$ExpandedListPath = Join-Path $Root 'ai-domains-expanded.txt'
$HostsFilePath = $env:CS_TEST_HOSTS

$origHosts = "127.0.0.1 localhost`r`n::1 localhost`r`n10.0.0.5 judge.internal.ac.kr`r`n"
Write-TextUtf8NoBom -Path $HostsFilePath -Content $origHosts
$origBytes = [System.IO.File]::ReadAllBytes($HostsFilePath)

$defaultDomains = @(Get-BlockDomains)
if ($defaultDomains.Count -lt 230) {
    throw "Expected >= 230 expanded default domains from Get-BlockDomains, got $($defaultDomains.Count)"
}

# Also test custom $DomainListPath combining $DefaultAiBlockDomains + 20 extra AI domains (>= 500 IPv4+IPv6 rules)
$customListFile = Join-Path $Root 'custom-blocklist.txt'
$customLines = @($DefaultAiBlockDomains | ForEach-Object { "0.0.0.0 $_" })
for ($i = 1; $i -le 20; $i++) {
    $customLines += "0.0.0.0 custom-llm-$i.ai"
}
Write-LinesUtf8NoBom -Path $customListFile -Lines ([string[]]$customLines)
$DomainListPath = $customListFile
$domains = @(Get-BlockDomains)
if ($domains.Count -lt 250) {
    throw "Expected >= 250 expanded domains with custom blocklist, got $($domains.Count)"
}

function Build-ManagedHostsText([string]$BaseContent, [string[]]$DomainList) {
    $cleaned = Remove-ManagedHostsSectionFromText -HostsText $BaseContent
    $sb = New-Object System.Text.StringBuilder
    if (-not [string]::IsNullOrWhiteSpace($cleaned)) {
        [void]$sb.Append($cleaned.TrimEnd("`r", "`n"))
        [void]$sb.Append("`r`n`r`n")
    }
    [void]$sb.AppendLine($BeginMarker)
    foreach ($d in $DomainList) {
        [void]$sb.AppendLine("0.0.0.0 $d")
        [void]$sb.AppendLine(":: $d")
    }
    [void]$sb.AppendLine($EndMarker)
    return $sb.ToString()
}

# Apply twice (idempotency check)
$pass1 = Build-ManagedHostsText -BaseContent (Read-TextUtf8 -Path $HostsFilePath) -DomainList $domains
Write-HostsFileWithRetry -Path $HostsFilePath -Content $pass1
$afterPass1 = Read-TextUtf8 -Path $HostsFilePath

$pass2 = Build-ManagedHostsText -BaseContent $afterPass1 -DomainList $domains
Write-HostsFileWithRetry -Path $HostsFilePath -Content $pass2
$afterPass2 = Read-TextUtf8 -Path $HostsFilePath

if ($afterPass1 -ne $afterPass2) {
    throw "Managed hosts apply is not idempotent across repeated applications"
}
$ruleLines = @([regex]::Matches($afterPass2, '(?m)^(?:0\.0\.0\.0|::)\s+\S+'))
if ($ruleLines.Count -lt 500) {
    throw "Expected >= 500 active IPv4/IPv6 rules in hosts file, got $($ruleLines.Count)"
}
foreach ($reqHost in @('chatgpt.com', 'www.chatgpt.com', 'claude.ai', 'www.claude.ai', 'gemini.google.com', 'wrtn.ai', 'clova-x.naver.com')) {
    if ($afterPass2 -notmatch ("(?m)^0\.0\.0\.0\s+" + [regex]::Escape($reqHost) + "\s*$") -or
        $afterPass2 -notmatch ("(?m)^::\s+" + [regex]::Escape($reqHost) + "\s*$")) {
        throw "Missing IPv4 or IPv6 block rule for $reqHost"
    }
}
if ($afterPass2 -notmatch '10\.0\.0\.5 judge\.internal\.ac\.kr') {
    throw "Custom judge entry 10.0.0.5 judge.internal.ac.kr was lost during hosts block"
}

# Restore original hosts content and verify byte-for-byte identity
$restoredText = (Remove-ManagedHostsSectionFromText -HostsText $afterPass2) + "`r`n"
Write-HostsFileWithRetry -Path $HostsFilePath -Content $restoredText
$restoredBytes = [System.IO.File]::ReadAllBytes($HostsFilePath)
$origSha = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($origBytes)) -Algorithm SHA256).Hash
$restSha = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($restoredBytes)) -Algorithm SHA256).Hash
if ($origSha -ne $restSha) {
    throw "Restored hosts SHA256 ($restSha) != original ($origSha)"
}

# Verify 13 core + 9 extended = 22 browser policy specifications
$coreSpecs = @(Get-BrowserPolicySpecifications)
$extSpecs = @(Get-ExtendedBrowserPolicySpecifications)
if ($coreSpecs.Count -ne 13 -or $extSpecs.Count -ne 9) {
    throw "Expected 13 core + 9 extended browser policies, got $($coreSpecs.Count) + $($extSpecs.Count)"
}

Write-Output ("T5_39_OK:DOMAINS={0}|RULES={1}|SHA_MATCH={2}|POLICIES={3}" -f $domains.Count, $ruleLines.Count, ($origSha -eq $restSha), ($coreSpecs.Count + $extSpecs.Count))
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_39_",
                extra_env={"CS_TEST_ROOT": str(tmp_root), "CS_TEST_HOSTS": str(hosts_path)},
            )
            assert res.returncode == 0, f"T5_39 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "SHA_MATCH=True|POLICIES=22" in res.stdout, f"Unexpected T5_39 output: {res.stdout}"

    @register("T5_40", 5, "F4+F12+F21", "Live pwsh E2E: restore-and-cleanup.ps1 workspace <=5MB source backup filter, MSYS2 .contest-bak restore, VS Code unlock, PATH strip, and >25m late-boot guard")
    def _():
        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("T5_40 requires pwsh 7.4+ (set CONTEST_PWSH or put pwsh on PATH)")

        with tempfile.TemporaryDirectory(prefix="cs_t5_40_restore_") as tmp_root:
            root_path = Path(tmp_root) / "CPTools"
            student_profile = Path(tmp_root) / "StudentProfile"
            ps_probe = r"""
$Root = $env:CS_TEST_ROOT
$MsysRoot = Join-Path $Root 'msys64'
$TargetUserSid = 'S-1-5-21-123456789-123456789-123456789-1001'
$TargetUserProfile = $env:CS_STUDENT_PROFILE
$env:ProgramData = Join-Path $env:CS_TMP_BASE 'ProgramData'
New-Item -ItemType Directory -Force -Path $TargetUserProfile, $env:ProgramData | Out-Null

. (Join-Path $env:CS_REPO_ROOT 'common.ps1')
Import-ContestScriptFunctionsAst -ScriptPath (Join-Path $env:CS_REPO_ROOT 'restore-and-cleanup.ps1')

# 1. Seed student workspace with valid sources (.cpp, .py), compiled binary (.exe), empty file, and >5MB file
$wsDir = Join-Path $Root 'contest'
New-Item -ItemType Directory -Force -Path (Join-Path $wsDir 'sub') | Out-Null
Write-TextUtf8NoBom -Path (Join-Path $wsDir 'main.cpp') -Content '#include <iostream>'
Write-TextUtf8NoBom -Path (Join-Path $wsDir 'sub/solve.py') -Content 'print(42)'
Write-TextUtf8NoBom -Path (Join-Path $wsDir 'a.exe') -Content 'MZ_BINARY_NOT_SOURCE'
Write-TextUtf8NoBom -Path (Join-Path $wsDir 'empty.cpp') -Content ''
$oversizePath = Join-Path $wsDir 'huge.cpp'
$oversizeBytes = New-Object byte[] (5 * 1024 * 1024 + 1024)
[System.IO.File]::WriteAllBytes($oversizePath, $oversizeBytes)

$backupDir = Backup-ContestWorkspaceSources -ContestRoot $Root -StudentProfilePath $TargetUserProfile
if ([string]::IsNullOrWhiteSpace($backupDir) -or -not (Test-Path -LiteralPath $backupDir)) {
    throw "Backup-ContestWorkspaceSources did not create backup directory"
}
$backedUpFiles = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
if (($backedUpFiles -join ',') -ne 'main.cpp,solve.py') {
    throw "Expected only main.cpp,solve.py in workspace backup, got: $($backedUpFiles -join ',')"
}

# 2. Restore-Msys2ContestConfiguration restores pacman.conf.contest-bak, mirrorlist.*.contest-bak, and removes contestsetup-windows-roots.pem
$etcDir = Join-Path $MsysRoot 'etc'
$pacDir = Join-Path $etcDir 'pacman.d'
$certsDir = Join-Path $etcDir 'pki/ca-trust/source/anchors'
New-Item -ItemType Directory -Force -Path $pacDir, $certsDir | Out-Null
Write-TextUtf8NoBom -Path (Join-Path $etcDir 'pacman.conf') -Content 'MODIFIED_PACMAN_CONF'
Write-TextUtf8NoBom -Path (Join-Path $etcDir 'pacman.conf.contest-bak') -Content 'ORIGINAL_PACMAN_CONF'
Write-TextUtf8NoBom -Path (Join-Path $pacDir 'mirrorlist.ucrt64') -Content 'KAIST_MIRROR_PREF'
Write-TextUtf8NoBom -Path (Join-Path $pacDir 'mirrorlist.ucrt64.contest-bak') -Content 'ORIGINAL_MIRRORLIST'
$customPem = Join-Path $certsDir 'contestsetup-windows-roots.pem'
Write-TextUtf8NoBom -Path $customPem -Content 'CERT_DATA'

Restore-Msys2ContestConfiguration -ToolchainRoot $MsysRoot
if ((Read-TextUtf8 -Path (Join-Path $etcDir 'pacman.conf')).Trim() -ne 'ORIGINAL_PACMAN_CONF') {
    throw "pacman.conf was not restored from .contest-bak"
}
if ((Read-TextUtf8 -Path (Join-Path $pacDir 'mirrorlist.ucrt64')).Trim() -ne 'ORIGINAL_MIRRORLIST') {
    throw "mirrorlist.ucrt64 was not restored from .contest-bak"
}
if ((Test-Path -LiteralPath (Join-Path $etcDir 'pacman.conf.contest-bak')) -or (Test-Path -LiteralPath $customPem)) {
    throw ".contest-bak or contestsetup-windows-roots.pem remained after Restore-Msys2ContestConfiguration"
}

# 3. Restore-VSCodeProductJsonWhenKept unlocks modern <commit>/resources/app/product.json
$vscCommitApp = Join-Path $Root 'vscode/1234567890abcdef/resources/app'
New-Item -ItemType Directory -Force -Path $vscCommitApp | Out-Null
$pj = Join-Path $vscCommitApp 'product.json'
Write-JsonUtf8NoBom -Path $pj -InputObject @{ extensionsGallery = @{ serviceUrl = 'https://127.0.0.1' } }
Write-JsonUtf8NoBom -Path "$pj.contest-orig" -InputObject @{ extensionsGallery = @{ serviceUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery' } }

Restore-VSCodeProductJsonWhenKept -ContestRoot $Root
$unlockedPj = ConvertFrom-JsonSafe -Json (Read-TextUtf8 -Path $pj)
if ($unlockedPj.extensionsGallery.serviceUrl -notmatch 'marketplace\.visualstudio\.com' -or (Test-Path -LiteralPath "$pj.contest-orig")) {
    throw "Restore-VSCodeProductJsonWhenKept failed to unlock product.json"
}

# 4. Remove-ContestEntriesFromPathScope strips $Root and $MsysRoot entries while preserving non-contest entries
$Script:MockRegPath = @{
    User    = 'C:\CPTools\bin;C:\CPTools\Python310;C:\CPTools\msys64\ucrt64\bin;C:\Users\Student\AppData\Local\Programs\Git\cmd'
    Machine = 'C:\CPTools\bin;C:\Windows\System32;C:\Windows'
}
$mockGetRegPath = { param($Scope, $UserSid, $UserProfile) return $Script:MockRegPath[$Scope] }
$mockSetRegPath = { param($Scope, $PathValue, $UserSid, $UserProfile) $Script:MockRegPath[$Scope] = $PathValue; return $true }
Set-Item -Path 'Function:\global:Get-RegistryScopePathValue' -Value $mockGetRegPath
Set-Item -Path 'Function:\script:Get-RegistryScopePathValue' -Value $mockGetRegPath
Set-Item -Path 'Function:\global:Set-RegistryScopePathValue' -Value $mockSetRegPath
Set-Item -Path 'Function:\script:Set-RegistryScopePathValue' -Value $mockSetRegPath

Remove-ContestEntriesFromPathScope -Scope 'User' -ContestRoot 'C:\CPTools' -MsysRootPath 'C:\CPTools\msys64' -IncludeMsys
Remove-ContestEntriesFromPathScope -Scope 'Machine' -ContestRoot 'C:\CPTools' -MsysRootPath 'C:\CPTools\msys64' -IncludeMsys
if ($Script:MockRegPath['User'] -ne 'C:\Users\Student\AppData\Local\Programs\Git\cmd' -or $Script:MockRegPath['Machine'] -ne 'C:\Windows\System32;C:\Windows') {
    throw "Remove-ContestEntriesFromPathScope mismatch: User=$($Script:MockRegPath['User']) Machine=$($Script:MockRegPath['Machine'])"
}

# 5. ConvertTo-LocalScheduleTime + >25m late-boot shutdown suppression
$schedLocal = ConvertTo-LocalScheduleTime -Text '2026-11-23T20:30:00+09:00'
$late15 = ([DateTimeOffset]::Parse('2026-11-23T20:45:00+09:00').LocalDateTime - $schedLocal).TotalMinutes
$late26 = ([DateTimeOffset]::Parse('2026-11-23T20:56:00+09:00').LocalDateTime - $schedLocal).TotalMinutes
if (($late15 -gt 25) -or (-not ($late26 -gt 25))) {
    throw "Late-boot >25m threshold calculation failed: late15=$late15 late26=$late26"
}

Write-Output ("T5_40_OK:BAK={0}|UNLOCKED=True|PATH_USER={1}|LATE26={2}" -f ($backedUpFiles -join ','), $Script:MockRegPath['User'], ($late26 -gt 25))
"""
            res = _run_pwsh_script(
                pwsh,
                ps_probe,
                prefix="cs_t5_40_",
                extra_env={
                    "CS_TEST_ROOT": str(root_path),
                    "CS_STUDENT_PROFILE": str(student_profile),
                    "CS_TMP_BASE": str(tmp_root),
                },
            )
            assert res.returncode == 0, f"T5_40 failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert "T5_40_OK:BAK=main.cpp,solve.py|UNLOCKED=True|PATH_USER=C:\\Users\\Student\\AppData\\Local\\Programs\\Git\\cmd|LATE26=True" in res.stdout, (
                f"Unexpected T5_40 output: {res.stdout}"
            )

    @register("T5_41", 5, "F2+F13+F23", "Repository structural modularity & zero-duplication contract gate (lib/*.ps1 <600L, common.ps1 <300L, run_tests.py <200L, docs/STRUCTURE.md)")
    def _():
        # 1. All 8 expected lib/*.ps1 modules exist and each is < 600 lines
        discovered_lib = ps.lib_ps1_files()
        assert discovered_lib == EXPECTED_LIB_PS1_FILES, (
            f"Expected 8 lib/*.ps1 modules {EXPECTED_LIB_PS1_FILES}, found {discovered_lib}"
        )
        for lib_rel in EXPECTED_LIB_PS1_FILES:
            lib_lines = ps.read_text(lib_rel).splitlines()
            assert 1 <= len(lib_lines) < 600, f"{lib_rel} must be < 600 lines, got {len(lib_lines)}"

        # 2. common.ps1 is < 300 lines and imports its 6 core lib/*.ps1 modules
        common_raw = ps.read_text("common.ps1")
        common_lines = common_raw.splitlines()
        assert 1 <= len(common_lines) < 300, f"common.ps1 must be < 300 lines after modularization, got {len(common_lines)}"
        for mod_name in (
            "core-primitives.ps1",
            "logging-and-manifest.ps1",
            "schedule-and-preflight.ps1",
            "download-and-archive.ps1",
            "path-and-identity.ps1",
            "environment-audit.ps1",
        ):
            assert mod_name in common_raw, f"common.ps1 does not import {mod_name}"
        assert "vscode-workspace.ps1" in ps.read_text("setup-vscode.ps1"), "setup-vscode.ps1 does not import vscode-workspace.ps1"
        assert "browser-policies.ps1" in ps.read_text("ai-hosts-block.ps1"), "ai-hosts-block.ps1 does not import browser-policies.ps1"
        assert "browser-policies.ps1" in ps.read_text("restore-and-cleanup.ps1"), "restore-and-cleanup.ps1 does not import browser-policies.ps1"

        # 3. tests/run_tests.py is < 200 lines and all modular test package files exist
        runner_lines = (repo_root / "tests" / "run_tests.py").read_text(encoding="utf-8").splitlines()
        assert 1 <= len(runner_lines) < 200, f"tests/run_tests.py must be < 200 lines, got {len(runner_lines)}"

        expected_py_modules = (
            "__init__.py",
            "inspector.py",
            "simulator.py",
            "tier1_features.py",
            "tier2_boundaries.py",
            "tier3_contracts.py",
            "tier4_scenarios.py",
            "tier5_adversarial.py",
            "live_pwsh_e2e.py",
        )
        for py_mod in expected_py_modules:
            mod_path = repo_root / "tests" / "contestsetup_tests" / py_mod
            assert mod_path.is_file(), f"Missing modular test file: tests/contestsetup_tests/{py_mod}"

        # 4. Zero inline duplication of shared JSON/browser-policy helpers in root scripts
        for root_script in ("common.ps1", "setup-vscode.ps1"):
            raw_root = ps.strip_comments(ps.read_text(root_script))
            assert "function ConvertFrom-JsonSafe" not in raw_root, (
                f"{root_script} still duplicates inline 'function ConvertFrom-JsonSafe' instead of importing lib/core-primitives.ps1"
            )
            assert "function ConvertFrom-JsonArray" not in raw_root, (
                f"{root_script} still duplicates inline 'function ConvertFrom-JsonArray' instead of importing lib/core-primitives.ps1"
            )
        for root_script in ("common.ps1", "setup-vscode.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            assert "core-primitives.ps1" in ps.read_text(root_script), (
                f"{root_script} must import core-primitives.ps1 via Import-ContestLibraryModule"
            )

        # 5. docs/STRUCTURE.md exists and documents every module in lib/ and tests/contestsetup_tests/
        structure_doc_path = repo_root / "docs" / "STRUCTURE.md"
        assert structure_doc_path.is_file(), "Missing docs/STRUCTURE.md architecture map"
        structure_doc = ps.read_text("docs/STRUCTURE.md")
        for lib_rel in EXPECTED_LIB_PS1_FILES:
            mod_name = Path(lib_rel).name
            assert mod_name in structure_doc, f"docs/STRUCTURE.md missing documentation for {lib_rel}"
        for py_mod in expected_py_modules:
            if py_mod != "__init__.py":
                assert py_mod in structure_doc, f"docs/STRUCTURE.md missing documentation for tests/contestsetup_tests/{py_mod}"
        assert "run_tests.py" in structure_doc

        # 6. All 20 .ps1 files (12 root + 8 lib/*.ps1) pass 7-bit ASCII, no BOM, LF endings, and syntax balance
        all_ps1 = ps.all_ps1_files()
        assert len(all_ps1) == len(PS1_FILES) + len(EXPECTED_LIB_PS1_FILES) == 20
        for fname in all_ps1:
            ps.assert_pure_ascii_ps1(fname)
            raw_bytes = ps.read_bytes(fname)
            assert not raw_bytes.startswith(b"\xef\xbb\xbf"), f"{fname} has UTF-8 BOM"
            assert b"\r\n" not in raw_bytes, f"{fname} contains CRLF"
            assert raw_bytes.endswith(b"\n"), f"{fname} does not end with LF"
            ok, msg = ps.validate_syntax_balance(ps.read_text(fname), fname)
            assert ok, msg

    return tests
