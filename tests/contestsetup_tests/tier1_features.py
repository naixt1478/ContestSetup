#!/usr/bin/env python3
"""Tier 1: Feature Specification & Behavioral Verification Tests (100 tests)."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import datetime
import stat
import sys
import zipfile
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

from . import EXPECTED_LIB_PS1_FILES, INSTALL_ENV_21_PARAMS, PS1_FILES, REPO_ROOT, TestCase, TestSkipped, find_pwsh, make_registrar
from .inspector import PowerShellInspector
from .simulator import BehavioralSimulator


def register_tests(ps: PowerShellInspector, sim: BehavioralSimulator, repo_root: Path) -> List[TestCase]:
    tests: List[TestCase] = []
    register = make_registrar(tests)

    # =========================================================================
    # TIER 1 — FEATURE COVERAGE (100 TESTS: 5 PER FEATURE F1..F14, F17..F22)
    # =========================================================================

    # --- F1: Exam Schedule Alignment (2026-11-23 Mon 19:00-20:30) ---
    @register("T1_F1_01", 1, "F1", "Default ExamStart, ExamEnd, and RestoreAt pinned to 2026-11-23 19:00-20:30 (+09:00) across all schedule scripts")
    def _():
        ie_code = ps.read_active_code("install-env.ps1")
        assert re.search(r"\$ExamStart\s*=\s*'2026-11-23T19:00:00'", ie_code)
        assert re.search(r"\$ExamEnd\s*=\s*'2026-11-23T20:30:00'", ie_code)
        assert re.search(r"\$RestoreAt\s*=\s*'2026-11-23T20:30:00'", ie_code)

        for script in ("common.ps1", "setup-restore-task.ps1"):
            code = ps.read_active_code(script)
            assert re.search(r"-Name\s+'ExamStart'\s+-DefaultValue\s+'2026-11-23T19:00:00'", code), (
                f"{script} missing Get-ContestVariableValue ExamStart default '2026-11-23T19:00:00'"
            )
            assert re.search(r"-Name\s+'ExamEnd'\s+-DefaultValue\s+'2026-11-23T20:30:00'", code), (
                f"{script} missing Get-ContestVariableValue ExamEnd default '2026-11-23T20:30:00'"
            )
            assert re.search(r"-Name\s+'RestoreAt'\s+-DefaultValue\s+'2026-11-23T20:30:00'", code), (
                f"{script} missing Get-ContestVariableValue RestoreAt default '2026-11-23T20:30:00'"
            )

        for ai_script in ("ai-hosts-block.ps1", "install-ai-hosts.ps1"):
            ai_code = ps.read_active_code(ai_script)
            assert "$DefaultExamEndKstIso = '2026-11-23T20:30:00+09:00'" in ai_code, (
                f"{ai_script} missing exact $DefaultExamEndKstIso = '2026-11-23T20:30:00+09:00'"
            )

    @register("T1_F1_02", 1, "F1", "Calendar verification that 2026-11-23 is Monday and Test-ExamScheduleConfiguration compares [System.DayOfWeek]::Monday")
    def _():
        exam_date = datetime.date(2026, 11, 23)
        assert exam_date.weekday() == 0 and exam_date.strftime("%A") == "Monday"
        body = ps.extract_function_body("common.ps1", "Test-ExamScheduleConfiguration")
        assert re.search(r"\$KstStart\.DayOfWeek\s+-eq\s+\[System\.DayOfWeek\]::Monday", body), (
            "Test-ExamScheduleConfiguration must compare $KstStart.DayOfWeek -eq [System.DayOfWeek]::Monday (not hardcoded $true)"
        )

    @register("T1_F1_03", 1, "F1", "KST timezone (+09:00) normalization and clock-skew HTTPS check present in common.ps1")
    def _():
        kst_body = ps.extract_function_body("common.ps1", "ConvertTo-KstDateTimeOffset")
        assert re.search(r'(?:\+\s*\x27\+09:00\x27|\$Trimmed\+09:00)', kst_body) and "DateTimeOffset" in kst_body
        skew_body = ps.extract_function_body("common.ps1", "Test-SystemClockSkewHttps")
        assert "Headers.Date" in skew_body and "5.0" in skew_body

    @register("T1_F1_04", 1, "F1", "Past-timestamp safeguard in setup-restore-task.ps1 prevents immediate shutdown when RestoreAt <= Get-Date")
    def _():
        code = ps.read_active_code("setup-restore-task.ps1")
        assert "IsPastRestoreTime" in code
        assert "AddHours(2)" in code and "$IncludeShutdownFlag = $false" in code

    @register("T1_F1_05", 1, "F1", "Exam-start enforcement hook (ContestSetupExamStartEnforcement) and schedule env var overrides supported")
    def _():
        combined = (
            ps.read_active_code("common.ps1")
            + "\n"
            + ps.read_active_code("setup-restore-task.ps1")
            + "\n"
            + ps.read_active_code("restore-and-cleanup.ps1")
        )
        assert "ContestSetupExamStartEnforcement" in combined
        for env_name in ("CONTEST_EXAM_START", "CONTEST_EXAM_END", "CONTEST_RESTORE_AT"):
            assert env_name in combined, f"Missing {env_name} override"

    # --- F2: Hybrid Local-First + Staged Module Loader (install-env.ps1) ---
    @register("T1_F2_01", 1, "F2", "Local-first module resolution from $PSScriptRoot when -UseRemote is not set")
    def _():
        code = ps.read_active_code("install-env.ps1")
        body = ps.extract_function_body("install-env.ps1", "Resolve-OrStageScriptPath")
        assert "$LocalSourceDir = $PSScriptRoot" in code
        assert "$CanUseLocalModules = (-not $UseRemote)" in code and "$CanUseLocalModules" in body

    @register("T1_F2_02", 1, "F2", "Remote staging downloads modules into $Root\\scripts with AST syntax validation before dot-sourcing")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert re.search(r"Join-Path\s+\$Root\s+['\"]scripts['\"]", code)
        ast_body = ps.extract_function_body("install-env.ps1", "Assert-PowerShellSyntaxValid")
        assert "Parser]::ParseFile" in ast_body
        assert "Invoke-Expression" not in code

    @register("T1_F2_03", 1, "F2", "UAC self-elevation quotes arguments via Quote-ProcessArgument and writes UTF-8 with BOM for PS 5.1")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "Quote-ProcessArgument" in code
        assert re.search(r"UTF8Encoding\s*\(\s*\$true\s*\)", code)

    @register("T1_F2_04", 1, "F2", "Global mutex tracks ownership ($MutexAcquired) before calling ReleaseMutex and Dispose")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "ContestSetupEnvironmentMutex" in code
        assert "if ($MutexAcquired)" in code and "$Global:SetupMutex.ReleaseMutex()" in code
        assert "$Global:SetupMutex.Dispose()" in code

    @register("T1_F2_05", 1, "F2", "-NoPause skips blocking MessageBox::Show and 5-second exit sleep")
    def _():
        msg_body = ps.extract_function_body("install-env.ps1", "Show-SetupResultMessage")
        assert "if ($NoPause)" in msg_body and "return" in msg_body
        code = ps.read_active_code("install-env.ps1")
        assert "if (-not $NoPause -and ($Mode -eq 'Install'))" in code

    # --- F3: Lifecycle Modes & Pre-flight Checks ---
    @register("T1_F3_01", 1, "F3", "install-env.ps1 declares [ValidateSet('Install', 'Status', 'Verify', 'Restore', 'DryRun', 'ExportCache')][string]$Mode")
    def _():
        params = ps.parse_declared_parameters("install-env.ps1")
        assert "mode" in params
        expected_modes = {"Install", "Status", "Verify", "Restore", "DryRun", "ExportCache"}
        assert params["mode"]["validate_set"] == expected_modes

    @register("T1_F3_02", 1, "F3", "Invoke-PreflightChecks verifies 64-bit OS, per-drive free disk space, clock skew, and guards hosts clear with (-not $DryRunOnly) -and ($Mode -eq 'Install')")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-PreflightChecks")
        assert "Is64BitOperatingSystem" in body
        assert "DriveInfo" in body and "AvailableFreeSpace" in body
        assert "Test-SystemClockSkewHttps" in body
        assert re.search(
            r"if\s*\(\s*\(-not\s+\$DryRunOnly\)\s+-and\s+\(\$Mode\s+-eq\s+'Install'\)\s*\)\s*\{\s*Clear-StaleAiHostsSectionBeforeInstall\s*\}",
            body,
            re.DOTALL,
        ), "Invoke-PreflightChecks must guard Clear-StaleAiHostsSectionBeforeInstall with (-not $DryRunOnly) -and ($Mode -eq 'Install')"

    @register("T1_F3_03", 1, "F3", "-Mode Status and -Mode Verify non-destructively inspect toolchain, VS Code, hosts, and scheduled task")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        assert "Invoke-ContestEnvironmentAudit" in install_code
        assert "ContestSetupRestoreAndCleanup" in audit_body

    @register("T1_F3_04", 1, "F3", "-Mode DryRun validates schedule and prerequisites via Invoke-PreflightChecks -DryRunOnly without mutating state")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        assert "Invoke-PreflightChecks -DryRunOnly" in install_code

    @register("T1_F3_05", 1, "F3", "State manifest C:\\CPTools\\state\\install-manifest.json is read/written via ConvertFrom-JsonSafe and Write-JsonUtf8NoBom")
    def _():
        read_body = ps.extract_function_body("common.ps1", "Read-ContestStateManifest")
        save_body = ps.extract_function_body("common.ps1", "Save-ContestStateManifest")
        upd_body = ps.extract_function_body("common.ps1", "Update-ContestStateManifest")
        assert "ConvertFrom-JsonSafe" in read_body
        assert "Write-JsonUtf8NoBom" in save_body and "Save-ContestStateManifest" in upd_body

    # --- F4: Non-Destructive Failure Handling & Log/Cache Preservation ---
    @register("T1_F4_01", 1, "F4", "install-env.ps1 catch block calls Stop-SetupLogging before error log backup or rollback")
    def _():
        code = ps.read_active_code("install-env.ps1")
        finally_idx = code.rfind("finally")
        matches = list(re.finditer(r"\n\}\s*catch\s*\{", code[:finally_idx]))
        assert matches and finally_idx != -1
        catch_body = code[matches[-1].start() : finally_idx]
        stop_log_pos = catch_body.find("Stop-SetupLogging")
        rollback_pos = catch_body.find("restore-and-cleanup.ps1")
        backup_log_pos = catch_body.find("Backup-SetupLogsToTemp")
        assert stop_log_pos != -1 and backup_log_pos != -1 and rollback_pos != -1
        assert stop_log_pos < backup_log_pos < rollback_pos

    @register("T1_F4_02", 1, "F4", "Default install failure preserves contest workspace, downloads, and logs unless -RollbackOnFailure is set")
    def _():
        code = ps.read_active_code("install-env.ps1")
        finally_idx = code.rfind("finally")
        matches = list(re.finditer(r"\n\}\s*catch\s*\{", code[:finally_idx]))
        catch_body = code[matches[-1].start() : finally_idx]
        assert "if ($RollbackOnFailure)" in catch_body
        assert "-KeepDownloads -KeepLogs -KeepWorkspace" in catch_body

    @register("T1_F4_03", 1, "F4", "Error and transcript logs are backed up to $env:TEMP\\ContestSetup-Logs on failure")
    def _():
        body = ps.extract_function_body("common.ps1", "Backup-SetupLogsToTemp")
        assert "ContestSetup-Logs" in body and "Copy-Item" in body

    @register("T1_F4_04", 1, "F4", "restore-and-cleanup.ps1 supports -KeepLogs, -KeepDownloads, -KeepWorkspace, and -KeepVSCode flags")
    def _():
        params = ps.parse_declared_parameters("restore-and-cleanup.ps1")
        for flag in ("keepdownloads", "keeplogs", "keepworkspace", "keepvscode"):
            assert flag in params, f"restore-and-cleanup.ps1 param() missing -{flag}"

    @register("T1_F4_05", 1, "F4", "restore-and-cleanup.ps1 selectively preserves contest, downloads, logs, and vscode directories when Keep* switches are set")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "if ($KeepDownloads) { $PreserveDirs += 'downloads' }" in code
        assert "if ($KeepLogs) { $PreserveDirs += 'logs' }" in code
        assert "if ($KeepWorkspace) { $PreserveDirs += 'contest' }" in code
        assert "if ($KeepVSCode) { $PreserveDirs += @('vscode', 'vscode-contest') }" in code

    # --- F5: Parallel Download Prefetcher & Smart Cache Reuse (common.ps1) ---
    @register("T1_F5_01", 1, "F5", "common.ps1 implements Invoke-ParallelDownloadFiles for concurrent installer prefetching")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-ParallelDownloadFiles")
        assert "GetAsync" in body and "CopyToAsync" in body and "WhenAll" in body

    @register("T1_F5_02", 1, "F5", "common.ps1 and install-env.ps1 support -CacheDir and CONTEST_CACHE_DIR for USB/LAN offline cache")
    def _():
        body = ps.extract_function_body("common.ps1", "Copy-FromCacheDirIfPresent")
        assert "$CacheDir" in body
        assert "CONTEST_CACHE_DIR" in ps.read_active_code("install-env.ps1")

    @register("T1_F5_03", 1, "F5", "Invoke-DownloadFile validates HTTP Content-Length against downloaded file length")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-DownloadFile")
        assert "ContentLength" in body and "$ActualLength -ne $ExpectedLength" in body

    @register("T1_F5_04", 1, "F5", "Invoke-DownloadFile allows Invoke-WebRequest fallback on both PS 5.1 and PS 7+ with silenced progress bar")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-DownloadFile")
        assert "else { throw }" not in body
        assert "Invoke-WebRequest" in body and "$ProgressPreference = 'SilentlyContinue'" in body

    @register("T1_F5_05", 1, "F5", "Smart cache reuse validates PK (ZIP/NUPKG/VSIX) and MZ (EXE) magic headers and caches winget --help queries")
    def _():
        magic_body = ps.extract_function_body("common.ps1", "Test-ValidCachedInstallerFile")
        assert "0x50" in magic_body and "0x4B" in magic_body and "0x4D" in magic_body and "0x5A" in magic_body
        winget_body = ps.extract_function_body("common.ps1", "Test-WingetHelpSupports")
        assert "WingetHelpCache" in winget_body

    # --- F6: Fast & Self-Healing MSYS2 Provisioning (setup-msys2.ps1) ---
    @register("T1_F6_01", 1, "F6", "setup-msys2.ps1 only enters post-winget wait loop when Install-ByWinget returns $true")
    def _():
        code = ps.read_active_code("setup-msys2.ps1")
        assert "$WingetInstalledMsys2 = Install-ByWinget" in code
        assert "if ($WingetInstalledMsys2)" in code

    @register("T1_F6_02", 1, "F6", "setup-msys2.ps1 auto-recovers stale var/lib/pacman/db.lck and terminates orphan gpg-agent/dirmngr")
    def _():
        lock_body = ps.extract_function_body("setup-msys2.ps1", "Remove-StaleMsys2Locks")
        gpg_body = ps.extract_function_body("setup-msys2.ps1", "Stop-Msys2GpgDaemons")
        assert "db.lck" in lock_body and "$ActivePacman.Count -eq 0" in lock_body
        assert "gpg-agent" in gpg_body and "dirmngr" in gpg_body

    @register("T1_F6_03", 1, "F6", "setup-msys2.ps1 implements fast-path skip when g++.exe, gcc.exe, gdb.exe, and cat.exe exist and execute --version")
    def _():
        ready_body = ps.extract_function_body("setup-msys2.ps1", "Test-Msys2ToolsReady")
        assert "--version" in ready_body
        assert "if ((-not $ForceUpdate) -and (Test-Msys2ToolsReady))" in ps.read_active_code("setup-msys2.ps1")

    @register("T1_F6_04", 1, "F6", "setup-msys2.ps1 prioritizes Korean mirrors (ftp.kaist.ac.kr, mirror.harukasan.org) before mirror.msys2.org and repo.msys2.org")
    def _():
        body = ps.extract_function_body("setup-msys2.ps1", "Set-Msys2OfficialMirrors")
        kaist_pos = body.find("ftp.kaist.ac.kr")
        harukasan_pos = body.find("mirror.harukasan.org")
        mirror_pos = body.find("mirror.msys2.org")
        repo_pos = body.find("repo.msys2.org")
        assert -1 < kaist_pos < harukasan_pos < mirror_pos < repo_pos

    @register("T1_F6_05", 1, "F6", "setup-msys2.ps1 enables ParallelDownloads = 8 in pacman.conf, makes root CA sync lazy, and uses combined pacman transaction")
    def _():
        opt_body = ps.extract_function_body("setup-msys2.ps1", "Optimize-Msys2PacmanConfig")
        assert "ParallelDownloads = 8" in opt_body
        code = ps.read_active_code("setup-msys2.ps1")
        assert "--needed -Syu mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb coreutils" in code

    # --- F7: Conflict-Free Python 3.10 Provisioning (setup-python.ps1) ---
    @register("T1_F7_01", 1, "F7", "setup-python.ps1 handles pre-existing system Python 3.10.11 collision via robocopy or PSF NuGet fallback")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Install-PythonDirect")
        assert "Find-ExistingSystemPython310" in body and "robocopy.exe" in body and "Install-PythonFromNugetFallback" in body

    @register("T1_F7_02", 1, "F7", "setup-python.ps1 retries up to 5 times on MSI exit code 1618 (ERROR_INSTALL_ALREADY_RUNNING)")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Install-PythonDirect")
        assert "$LastExitCode -eq 1618" in body and "$MsiAttempt -le 5" in body

    @register("T1_F7_03", 1, "F7", "setup-python.ps1 creates native python3.exe inside $PythonDir alongside python.exe")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Ensure-NativePython3Binary")
        assert "$PythonExe" in body and "$Python3Exe" in body and "Copy-Item" in body

    @register("T1_F7_04", 1, "F7", "setup-python.ps1 records PythonInstalledByContestSetup in install-manifest.json")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Install-PythonDirect")
        assert "Update-ContestStateManifest" in body and "PythonInstalledByContestSetup" in body

    @register("T1_F7_05", 1, "F7", "setup-python.ps1 verifies python.exe --version, python3.exe --version, and stdlib imports")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Assert-PythonRuntimeHealthy")
        assert "--version" in body and "import site, encodings" in body

    # --- F8: Opt-In Visual Studio 2022 & vswhere.exe Detection (setup-visualstudio.ps1) ---
    @register("T1_F8_01", 1, "F8", "setup-visualstudio.ps1 detects Community, Professional, Enterprise, and BuildTools via vswhere.exe + cl.exe check")
    def _():
        body = ps.extract_function_body("setup-visualstudio.ps1", "Find-VisualStudioWithCppTools")
        assert "vswhere.exe" in body and "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" in body
        assert "Test-MsvcClCompilerPresent" in body
        for edition in ("Community", "Professional", "Enterprise", "BuildTools"):
            assert edition in body

    @register("T1_F8_02", 1, "F8", "setup-visualstudio.ps1 skips VS 2022 installation by default unless -IncludeVisualStudio is passed")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert "elseif (-not $IncludeVisualStudio)" in code

    @register("T1_F8_03", 1, "F8", "setup-visualstudio.ps1 omits --includeRecommended and passes --quiet --wait --norestart")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert "--includeRecommended" not in code
        assert "--add Microsoft.VisualStudio.Workload.NativeDesktop --quiet --wait --norestart" in code

    @register("T1_F8_04", 1, "F8", "setup-visualstudio.ps1 treats exit code 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) as success")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert "$ExitCode -in @(0, 3010)" in code

    @register("T1_F8_05", 1, "F8", "IncludeVisualStudio parameter and CONTEST_INCLUDE_VS env var are wired in install-env.ps1 and common.ps1")
    def _():
        assert "CONTEST_INCLUDE_VS" in ps.read_active_code("install-env.ps1")
        assert "CONTEST_INCLUDE_VS" in ps.read_active_code("common.ps1")

    # --- F9: Bulletproof Portable VS Code & Batched Extensions (setup-vscode.ps1) ---
    @register("T1_F9_01", 1, "F9", "setup-vscode.ps1 verifies Code.exe, code.cmd, and product.json before considering standalone VS Code installed")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Test-VSCodeStandaloneComplete")
        assert "Get-VSCodeCommandPath" in body and "Get-VSCodeExePath" in body and "Get-VSCodeProductJsonPath" in body

    @register("T1_F9_02", 1, "F9", "setup-vscode.ps1 backs up product.json.contest-orig before locking Marketplace to 127.0.0.1 and restores before extension installs")
    def _():
        lock_body = ps.extract_function_body("setup-vscode.ps1", "Disable-VSCodeMarketplace")
        rest_body = ps.extract_function_body("setup-vscode.ps1", "Restore-VSCodeMarketplace")
        ext_body = ps.extract_function_body("setup-vscode.ps1", "Install-VSCodeExtensions")
        assert ".contest-orig" in lock_body and "https://127.0.0.1" in lock_body
        assert ".contest-orig" in rest_body and "Restore-VSCodeMarketplace" in ext_body

    @register("T1_F9_03", 1, "F9", "Install-VSCodeExtensions skips already-installed extensions and batches missing ones without unconditional --force")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Install-VSCodeExtensions")
        assert "Get-InstalledContestVSCodeExtensions" in body
        assert "if ($ForceExtUpdate) { $BatchExtArgs += '--force' }" in body
        assert "$BatchExtArgs += @('--install-extension', $Ext)" in body

    @register("T1_F9_04", 1, "F9", "setup-vscode.ps1 throws fatal error if required extensions remain missing after installation attempts")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Warn-IfRequiredVSCodeExtensionsMissing")
        assert "if ($Missing.Count -gt 0)" in body and "throw" in body

    @register("T1_F9_05", 1, "F9", "setup-vscode.ps1 generates tasks.json, c_cpp_properties.json, and launch.json and preserves shortcut Existed flag")
    def _():
        ws_body = ps.extract_function_body("setup-vscode.ps1", "Set-ContestVSCodeWorkspaceDefaults")
        for cfg in ("tasks.json", "c_cpp_properties.json", "launch.json"):
            assert cfg in ws_body
        shortcut_body = ps.extract_function_body("setup-vscode.ps1", "Set-ContestVSCodeShortcut")
        assert "Test-Path -LiteralPath $DefaultBackupPath" in shortcut_body and "$Existed = $true" in shortcut_body

    # --- F10: Clean Command Wrappers & Machine/User PATH Precedence (setup-wrappers.ps1, common.ps1) ---
    @register("T1_F10_01", 1, "F10", "setup-wrappers.ps1 includes @setlocal in all 9 .cmd compiler/tool wrappers and removes dead $PathBin directory")
    def _():
        body = ps.extract_function_body("setup-wrappers.ps1", "Create-CommandWrappers")
        assert body.count("'@setlocal'") >= 9
        assert "$PathBin" not in ps.read_active_code("setup-wrappers.ps1")

    @register("T1_F10_02", 1, "F10", "Configure-Path places $PythonDir, $UcrtBin, and $MsysUsrBin before $ToolBin so native .exe tools are not shadowed")
    def _():
        body = ps.extract_function_body("setup-wrappers.ps1", "Configure-Path")
        assert "Add-UserPathsFront @($PythonDir, $UcrtBin, $MsysUsrBin, $ToolBin)" in body

    @register("T1_F10_03", 1, "F10", "common.ps1 backs up and updates Machine PATH alongside User PATH to prevent Machine PATH shadowing")
    def _():
        add_body = ps.extract_function_body("common.ps1", "Add-UserPathsFront")
        bak_body = ps.extract_function_body("common.ps1", "Backup-PathEnvironment")
        assert "Get-RawMachinePath" in add_body and "Set-RawMachinePath" in add_body
        assert "Machine PATH:" in bak_body

    @register("T1_F10_04", 1, "F10", "Run-SmokeTests verifies command resolution via Get-Command for all 10 contest commands")
    def _():
        res_body = ps.extract_function_body("setup-wrappers.ps1", "Assert-ContestCommandResolution")
        for cmd in ("g++", "g++14", "g++17", "g++20", "gcc", "gdb", "python", "python3", "cat", "code"):
            assert f"'{cmd}'" in res_body

    @register("T1_F10_05", 1, "F10", "Run-SmokeTests compiles and executes C++14, C++20, and Python3 test programs concurrently")
    def _():
        body = ps.extract_function_body("setup-wrappers.ps1", "Run-SmokeTests")
        assert "CPP14 OK 14" in body and "CPP20 OK 20" in body and "PYTHON3 OK 6" in body
        assert "Start-SmokeProcessAsync" in body and "Wait-SmokeProcessChecked" in body

    # --- F11: Resilient IPv4+IPv6 AI Hosts Blocking ---
    @register("T1_F11_01", 1, "F11", "Remove-ManagedHostsSectionFromText declares [AllowEmptyString()] and [AllowNull()] on $HostsText")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Remove-ManagedHostsSectionFromText")
        assert "AllowEmptyString" in body and "AllowNull" in body

    @register("T1_F11_02", 1, "F11", "ai-hosts-block.ps1 clears ReadOnly attribute and retries hosts file writes up to 5 times on file lock")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Write-HostsFileWithRetry")
        assert "ReadOnly" in body and "MaxAttempts = 5" in body

    @register("T1_F11_03", 1, "F11", "Apply-AiHostsBlock blocks both IPv4 (0.0.0.0) and IPv6 (::) plus www. subdomain variants")
    def _():
        apply_body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        dom_body = ps.extract_function_body("ai-hosts-block.ps1", "Get-BlockDomains")
        assert '"0.0.0.0 $Domain"' in apply_body and '":: $Domain"' in apply_body
        assert '"www.$Part"' in dom_body

    @register("T1_F11_04", 1, "F11", "Apply-AiHostsBlock always copies script to stable paths even when -NoSchedule is passed")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        assert "Copy-SelfToStablePath" in body

    @register("T1_F11_05", 1, "F11", "install-ai-hosts.ps1 removes -NoExit hang and updates -Until schedule examples to 2026-11-23 20:30")
    def _():
        raw_install = ps.read_text("install-ai-hosts.ps1")
        active_install = ps.read_active_code("install-ai-hosts.ps1")
        raw_ai = ps.read_text("ai-hosts-block.ps1")
        assert "-NoExit" not in active_install
        assert "2026-11-23 20:30" in raw_install and "2026-11-23 20:30" in raw_ai

    # --- F12: Admin-Checked Complete Restoration ---
    @register("T1_F12_01", 1, "F12", "restore-and-cleanup.ps1 enforces Test-IsAdmin and captures student SID before self-elevation")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        admin_pos = code.find("if (-not (Test-IsAdmin))")
        step0_pos = code.find("[0/6]")
        assert -1 < admin_pos < step0_pos

    @register("T1_F12_02", 1, "F12", "restore-and-cleanup.ps1 unregisters ContestSetupRestoreAndCleanup, ContestSetupRestoreAiHostsBlock, and ContestSetupExamStartEnforcement")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        for task_name in (
            "ContestSetupRestoreAndCleanup",
            "ContestSetupRestoreAiHostsBlock",
            "ContestSetupExamStartEnforcement",
        ):
            assert f"'{task_name}'" in code

    @register("T1_F12_03", 1, "F12", "restore-and-cleanup.ps1 restores PATH from oldest snapshot and runs Remove-ContestEntriesFromPathScope")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "path-environment-before-cleanup.txt" in code
        assert "Remove-ContestEntriesFromPathScope" in code

    @register("T1_F12_04", 1, "F12", "restore-and-cleanup.ps1 verifies InstallLocation is inside $Root before uninstalling Python from Registry")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Test-PathInside -ChildPath $InstallLocation -ParentPath $Root" in code
        assert '$InstallLocation -like "$PythonDir*"' not in code

    @register("T1_F12_05", 1, "F12", "restore-and-cleanup.ps1 kills all processes with .Path inside $Root and writes remove-cptools.cmd in UTF-8 with chcp 65001")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Encoding]::ASCII" not in code
        assert "'chcp 65001 >nul'" in code
        body = ps.extract_function_body("restore-and-cleanup.ps1", "Stop-ProcessesUnderPath")
        assert "Get-Process" in body and "Test-PathInside" in body

    # --- F13: JSON Serialization & Shared Helper Deduplication ---
    @register("T1_F13_01", 1, "F13", "Write-JsonUtf8NoBom uses ConvertTo-Json -InputObject $InputObject to preserve 0 and 1 element arrays")
    def _():
        for script in ("common.ps1", "ai-hosts-block.ps1"):
            body = ps.extract_function_body(script, "Write-JsonUtf8NoBom")
            assert "ConvertTo-Json -InputObject $InputObject" in body
            assert "$InputObject | ConvertTo-Json" not in body

    @register("T1_F13_02", 1, "F13", "common.ps1 and restore-and-cleanup.ps1 provide Quote-ProcessArgument, state manifest helpers, Test-PathInside, and Assert-SafeRemovalPath")
    def _():
        common_code = ps.read_active_code("common.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for helper in ("Quote-ProcessArgument", "Normalize-PathForCompare", "Read-ContestStateManifest", "Update-ContestStateManifest", "Test-PathInside"):
            assert f"function {helper}" in common_code
        for helper in ("Test-PathInside", "Assert-SafeRemovalPath"):
            assert f"function {helper}" in restore_code

    @register("T1_F13_03", 1, "F13", "common.ps1 safely parses PythonVersion with fallback if minor version part is missing")
    def _():
        code = ps.read_active_code("common.ps1")
        assert "$VersionParts.Count -ge 2" in code

    @register("T1_F13_04", 1, "F13", "Invoke-NativeCommand uses Test-Path -LiteralPath and ProcessStartInfo cmd.exe wrapper for .cmd/.bat")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-NativeCommand")
        assert "Test-Path -LiteralPath" in body and "ProcessStartInfo" in body

    @register("T1_F13_05", 1, "F13", "common.ps1 enables Set-StrictMode -Version 2.0 and configures UTF-8 console encoding")
    def _():
        code = ps.read_active_code("common.ps1")
        assert "Set-StrictMode -Version 2.0" in code and "65001" in code and "UTF8Encoding" in code

    # --- F14: v2.0 Architecture & Speed Optimization Analysis Document ---
    @register("T1_F14_01", 1, "F14", "README.md is updated in Korean for Monday 2026-11-23 19:00-20:30 exam schedule and auto-restore warning")
    def _():
        readme = ps.read_text("README.md")
        assert "2026년 11월 23일(월)" in readme and "19:00" in readme and "20:30" in readme

    @register("T1_F14_02", 1, "F14", "README.md documents v2.0 lifecycle modes (Install/Status/Verify/DryRun/Restore/ExportCache) and proctor runbook")
    def _():
        readme = ps.read_text("README.md")
        for term in ("Status", "Verify", "DryRun", "ExportCache", "CacheDir", "restore-and-cleanup.ps1", "ContestSetup-Workspace-Backup"):
            assert term in readme, f"README.md missing '{term}'"

    @register("T1_F14_03", 1, "F14", "ARCHITECTURE_V2.md exists and documents the 2026-11-23 (월) 19:00-20:30 KST schedule architecture")
    def _():
        arch = ps.read_text("ARCHITECTURE_V2.md")
        assert len(arch.splitlines()) >= 100
        assert "2026-11-23" in arch and "+09:00" in arch and "S-1-5-18" in arch

    @register("T1_F14_04", 1, "F14", "ARCHITECTURE_V2.md documents root-cause analysis of all stability defects S-01 through S-28")
    def _():
        arch = ps.read_text("ARCHITECTURE_V2.md")
        for defect_id in [f"S-{i:02d}" for i in range(1, 29)]:
            assert defect_id in arch, f"ARCHITECTURE_V2.md missing stability defect {defect_id}"

    @register("T1_F14_05", 1, "F14", "ARCHITECTURE_V2.md documents and quantifies all speed & classroom optimizations O1 through O10")
    def _():
        arch = ps.read_text("ARCHITECTURE_V2.md")
        for opt_id in [f"O{i}" for i in range(1, 11)]:
            assert opt_id in arch, f"ARCHITECTURE_V2.md missing speed optimization {opt_id}"

    # --- F17: PS 5.1 Encoding, JSONC/Array & PSCustomObject Runtime Safety (S-19, S-20, S-26, S-28) ---
    @register("T1_F17_01", 1, "F17", "All .ps1 files are strictly 7-bit ASCII (< 0x80) and replace bare Get-Content with Read-TextUtf8 / Read-LinesUtf8")
    def _():
        for fname in ps.all_ps1_files():
            ps.assert_pure_ascii_ps1(fname)
            code = ps.read_active_code(fname)
            assert not re.search(r"\bGet-Content\b", code, re.IGNORECASE), (
                f"{fname} uses bare Get-Content instead of explicit UTF-8 Read-TextUtf8 / Read-LinesUtf8"
            )

    @register("T1_F17_02", 1, "F17", "ConvertFrom-JsonSafe and ConvertFrom-JsonArray eliminate JSONC crashes and PS 5.1 Object[][] double-wrapping")
    def _():
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            assert not re.search(r"@\([^)]*\|\s*ConvertFrom-Json", code, re.IGNORECASE), (
                f"{fname} contains PS 5.1 Object[][] bug pattern @(... | ConvertFrom-Json)"
            )
        for script in ("common.ps1", "setup-vscode.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            arr_body = ps.extract_function_body(script, "ConvertFrom-JsonArray")
            assert "System.Array" in arr_body and "ConvertFrom-JsonSafe" in arr_body

    @register("T1_F17_03", 1, "F17", "Set-ObjectProperty uses Add-Member -Force in common.ps1 & setup-vscode.ps1 and Disable-VSCodeMarketplace verifies lock")
    def _():
        for script in ("common.ps1", "setup-vscode.ps1"):
            prop_body = ps.extract_function_body(script, "Set-ObjectProperty")
            assert re.search(r"\bAdd-Member\b[^\n]*-Force\b", prop_body), (
                f"{script} Set-ObjectProperty must use Add-Member -Force (never direct $o.$n= assignment)"
            )
        body = ps.extract_function_body("setup-vscode.ps1", "Disable-VSCodeMarketplace")
        assert "Set-ObjectProperty" in body
        assert "VerifiedObj" in body and "https://127.0.0.1" in body and "Marketplace lock verification failed" in body

    @register("T1_F17_04", 1, "F17", "MSYS2 two-stage SyncFirst post-check (Test-Msys2RequiredBinariesExist) and PGP keyring recovery (Ensure-Msys2KeyringReady)")
    def _():
        code = ps.read_active_code("setup-msys2.ps1")
        assert "if (-not (Test-Msys2RequiredBinariesExist))" in code
        key_body = ps.extract_function_body("setup-msys2.ps1", "Ensure-Msys2KeyringReady")
        pac_body = ps.extract_function_body("setup-msys2.ps1", "Invoke-PacmanChecked")
        assert "Invoke-MsysBashChecked 'pacman-key --init && pacman-key --populate msys2'" in key_body
        assert "msys2-keyring" in pac_body

    @register("T1_F17_05", 1, "F17", "Python Repair-PythonPthFileIfNeeded replaces #import site with active 'import site' and setup-visualstudio.ps1 verifies cl.exe")
    def _():
        pth_body = ps.extract_function_body("setup-python.ps1", "Repair-PythonPthFileIfNeeded")
        assert "python*._pth" in pth_body
        assert re.search(
            r"\[regex\]::Replace\(\s*\$RawPth\s*,\s*'\(\?m\)\^#\\s\*import\\s\+site\\b'\s*,\s*'import site'\s*\)",
            pth_body,
        ), "Repair-PythonPthFileIfNeeded must replace #import site with exact active 'import site'"
        cl_body = ps.extract_function_body("setup-visualstudio.ps1", "Test-MsvcClCompilerPresent")
        assert "cl.exe" in cl_body
        vs_code = ps.read_active_code("setup-visualstudio.ps1")
        assert "vs_installer.exe" in vs_code and "'modify'" in vs_code

    # --- F18: CLI/CONTEST_* Env Binding, Non-Destructive -Mode Verify & Exit Code Integrity (S-21, S-27) ---
    @register("T1_F18_01", 1, "F18", "All 21 CLI parameters in install-env.ps1 use $PSBoundParameters-guarded CONTEST_* environment variable binding")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        common_code = ps.read_active_code("common.ps1")
        assert "BoundParamMap.ContainsKey" in install_code
        for param_name, env_name in INSTALL_ENV_21_PARAMS.items():
            assert f"'{param_name}'" in install_code and f"'{env_name}'" in install_code, (
                f"install-env.ps1 missing CONTEST_* binding for {param_name} -> {env_name}"
            )
            assert f"'{env_name}'" in common_code, f"common.ps1 missing {env_name}"

    @register("T1_F18_02", 1, "F18", "Zero StrictMode-unsafe $MyInvocation.MyCommand.Path or .Definition references across all .ps1 scripts")
    def _():
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            assert not re.search(r"MyInvocation\.MyCommand\.(?:Path|Definition)", code, re.IGNORECASE), (
                f"{fname} contains StrictMode-unsafe $MyInvocation.MyCommand.Path/.Definition"
            )

    @register("T1_F18_03", 1, "F18", "Read-only modes (DryRun, Status, Verify) bypass forced UAC elevation while mutating modes capture student SID first")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "if (-not (Test-IsAdmin) -and ($Mode -notin @('DryRun', 'Status', 'Verify')))" in code
        assert "WindowsIdentity]::GetCurrent().User.Value" in code

    @register("T1_F18_04", 1, "F18", "-Mode Verify is non-destructive (never touches hosts or GUI modals) and failure branches exit non-zero (never exit 0)")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "PreferLocalWithoutStaging" in code
        assert "if ($Mode -eq 'Verify')" in code and "if (-not $AuditReport.AllReady)" in code
        assert code.count("$ExitCodeToReturn = 1") >= 2, "Expected >= 2 '$ExitCodeToReturn = 1' failure assignments in install-env.ps1"
        assert len(re.findall(r"\{\s*exit\s+1\s*\}", code)) >= 2, "Expected >= 2 '{ exit 1 }' failure branches in install-env.ps1"
        assert not re.search(r"\bexit\s+0\b", code), "install-env.ps1 must never hardcode 'exit 0' in failure/early-exit branches"
        assert "if (($Mode -eq 'Install') -and (Get-Command Clear-StaleAiHostsSectionBeforeInstall" in code
        assert "$global:LASTEXITCODE = $FinalExitCode" in code

    @register("T1_F18_05", 1, "F18", "Invoke-ContestEnvironmentAudit performs deep 7-component readiness and anti-cheat verification")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        for token in (
            "MSYS2 UCRT64",
            "import site, encodings",
            "Portable VS Code & Marketplace Lock",
            "UnauthorizedExts",
            "chat.disableAIFeatures",
            "CLI Wrappers (10 .cmd wrappers)",
            "$RuleCount -ge 100",
            "ContestSetupRestoreAndCleanup",
        ):
            assert token in body, f"Invoke-ContestEnvironmentAudit missing deep check '{token}'"

    # --- F19: VS Code --locale ko, Portable vscode\data Trap & Extension Allowlist (S-22, S-27) ---
    @register("T1_F19_01", 1, "F19", "--locale ko is passed in shortcuts, Start-Contest-VSCode.ps1, bin\\code.cmd, and both argv.json files")
    def _():
        sc_body = ps.extract_function_body("setup-vscode.ps1", "Get-ContestVSCodeShortcutArguments")
        ln_body = ps.extract_function_body("setup-vscode.ps1", "New-ContestVSCodeLauncher")
        cw_body = ps.extract_function_body("setup-vscode.ps1", "New-ContestVSCodeCliWrapper")
        ko_body = ps.extract_function_body("setup-vscode.ps1", "Set-VSCodeDisplayLanguageKorean")
        assert "--locale ko" in sc_body
        assert "--locale ko" in ln_body
        assert cw_body.count("--locale ko") >= 2
        assert "Get-PortableVSCodeDataDir" in ko_body and "argv.json" in ko_body

    @register("T1_F19_02", 1, "F19", "Portable Mode trap directory ($Root\\vscode\\data) is initialized and receives exact AI-disabled settings")
    def _():
        init_body = ps.extract_function_body("setup-vscode.ps1", "Initialize-ContestVSCodeIsolated")
        ai_body = ps.extract_function_body("setup-vscode.ps1", "Set-VSCodeAiHiddenSettings")
        assert "Get-PortableVSCodeDataDir" in init_body and "user-data\\User" in init_body
        assert "Get-PortableVSCodeDataDir" in ai_body and "Write-JsonUtf8NoBom -Path $PortableSettingsPath" in ai_body
        assert re.search(r"'chat\.disableAIFeatures'\s*=\s*\$true\b", ai_body)
        assert re.search(r"'github\.copilot\.enable'\s*=\s*\$CopilotEnable\b", ai_body)
        for false_key in (
            "chat.agent.enabled",
            "chat.edits.enabled",
            "chat.mcp.enabled",
            "inlineChat.enabled",
            "github.copilot.chat.enabled",
            "github.copilot.chat.agent.enabled",
            "github.copilot.chat.edits.enabled",
            "github.copilot.editor.enableAutoCompletions",
            "github.copilot.nextEditSuggestions.enabled",
            "github.copilot.inlineSuggest.enable",
        ):
            assert re.search(rf"'{re.escape(false_key)}'\s*=\s*\$false\b", ai_body), (
                f"Set-VSCodeAiHiddenSettings must set '{false_key}' = $false"
            )

    @register("T1_F19_03", 1, "F19", "Strict VS Code extension allowlist & blocked list (including github.copilot & github.copilot-chat) sweep unauthorized dirs")
    def _():
        allow_body = ps.extract_function_body("setup-vscode.ps1", "Get-AllowedVSCodeExtensions")
        block_body = ps.extract_function_body("setup-vscode.ps1", "Get-BlockedVSCodeExtensions")
        rem_body = ps.extract_function_body("setup-vscode.ps1", "Remove-BlockedVSCodeExtensions")
        for req in ("ms-ceintl.vscode-language-pack-ko", "ms-vscode.cpptools", "ms-python.python", "ms-python.debugpy"):
            assert f"'{req}'" in allow_body
        for blocked_ext in (
            "github.copilot",
            "github.copilot-chat",
            "rooveterinaryinc.roo-cline",
            "kilocode.kilo-code",
            "anthropic.claude-code",
            "google.geminicodeassist",
        ):
            assert f"'{blocked_ext}'" in block_body, f"Get-BlockedVSCodeExtensions missing '{blocked_ext}'"
        assert "$AllowedSet -notcontains $_" in rem_body and "Purging unauthorized extension directory" in rem_body

    @register("T1_F19_04", 1, "F19", "VS Code shortcut management resolves target student profile, TaskBar pinned .lnk, and CommonDesktopDirectory")
    def _():
        folders_body = ps.extract_function_body("setup-vscode.ps1", "Get-TargetStudentShortcutFolders")
        targets_body = ps.extract_function_body("setup-vscode.ps1", "Get-VSCodeShortcutTargets")
        assert "Resolve-ContestTargetUser" in folders_body and "User Pinned\\TaskBar" in folders_body
        assert "CommonDesktop" in targets_body and "IsSystemOrCrossUser" in targets_body

    @register("T1_F19_05", 1, "F19", "code.cmd avoids cmd (...) blocks around %*, tasks.json uses -std=gnu++17, and launch.json injects UCRT64 PATH")
    def _():
        cw_body = ps.extract_function_body("setup-vscode.ps1", "New-ContestVSCodeCliWrapper")
        ws_body = ps.extract_function_body("setup-vscode.ps1", "Set-ContestVSCodeWorkspaceDefaults")
        assert "goto :contest_default" in cw_body and ") else (" not in cw_body
        assert "-std=gnu++17" in ws_body and "$UcrtBinValue;$MsysUsrBinValue" in ws_body

    # --- F20: Classroom Speed & Scale Optimizations (O8, O9, O10) ---
    @register("T1_F20_01", 1, "F20", "Expand-ArchiveFast implements 3-tier extraction using explicit System32\\tar.exe -> ZipFile -> silent Expand-Archive")
    def _():
        body = ps.extract_function_body("common.ps1", "Expand-ArchiveFast")
        assert "System32\\tar.exe" in body
        assert "Get-Command 'tar" not in body and 'Get-Command "tar' not in body
        assert "ZipFile]::ExtractToDirectory" in body
        assert "Expand-Archive -LiteralPath" in body and "$ProgressPreference = 'SilentlyContinue'" in body
        assert "Expand-ArchiveFast" in ps.read_active_code("setup-vscode.ps1")
        assert "Expand-ArchiveFast" in ps.read_active_code("setup-python.ps1")

    @register("T1_F20_02", 1, "F20", "Invoke-ParallelDownloadFiles streams response bodies concurrently via CopyToAsync + Task::WhenAll with DefaultConnectionLimit >= 16")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-ParallelDownloadFiles")
        assert "DefaultConnectionLimit" in body and "16" in body
        assert "CopyToAsync" in body and "Task]::WhenAll" in body and "Test-ValidCachedInstallerFile" in body

    @register("T1_F20_03", 1, "F20", "-Mode ExportCache builds complete zero-bandwidth bundle (installers, vscode-extensions, msys2-pkg, scripts, cache-manifest.json)")
    def _():
        code = ps.read_active_code("install-env.ps1")
        exp_idx = code.find("elseif ($Mode -eq 'ExportCache')")
        assert exp_idx != -1
        export_section = code[exp_idx : exp_idx + 4500]
        for artifact in ("vscode-extensions", "msys2-pkg", "msys2-sync", "scripts", "cache-manifest.json"):
            assert artifact in export_section, f"ExportCache section missing '{artifact}'"

    @register("T1_F20_04", 1, "F20", "Offline CacheDir seeds VS Code extensions (vscode-extensions / .vsix) and MSYS2 pacman cache (msys2-pkg / msys2-sync)")
    def _():
        vsc_seed = ps.extract_function_body("setup-vscode.ps1", "Seed-VSCodeExtensionsFromCacheDir")
        msys_seed = ps.extract_function_body("setup-msys2.ps1", "Seed-Msys2PackageCacheFromCacheDir")
        assert "vscode-extensions" in vsc_seed and "*.vsix" in vsc_seed
        assert "msys2-pkg" in msys_seed and "msys2-sync" in msys_seed

    @register("T1_F20_05", 1, "F20", "Single-pass $Script:StagedScriptPaths cache, $Script:InstalledVSCodeExtensionsCache, $Global:ContestToolVersions, and -O0 parallel smoke tests")
    def _():
        assert "$Script:StagedScriptPaths" in ps.read_active_code("install-env.ps1")
        assert "$Script:InstalledVSCodeExtensionsCache" in ps.read_active_code("setup-vscode.ps1")
        assert "$Global:ContestToolVersions" in ps.read_active_code("common.ps1")
        smoke_body = ps.extract_function_body("setup-wrappers.ps1", "Run-SmokeTests")
        assert smoke_body.count("'-O0'") >= 2 and "Start-SmokeProcessAsync" in smoke_body

    # --- F21: SID-Aware SYSTEM Scheduled Tasks, Dual-Trigger/Late-Shutdown Guards & Complete Restore ---
    @register("T1_F21_01", 1, "F21", "Scheduled task registration functions use primary S-1-5-18 ServiceAccount principal, -StartWhenAvailable, -WakeToRun, and 1h limit")
    def _():
        # Verify setup-restore-task.ps1 primary principal & settings block
        srt_code = ps.read_active_code("setup-restore-task.ps1")
        srt_reg_body = ps.extract_function_body("setup-restore-task.ps1", "Register-ContestScheduledTaskWithFallback")
        srt_principals = re.findall(r"New-ScheduledTaskPrincipal\s+([^\n]+)", srt_reg_body)
        assert len(srt_principals) >= 1
        assert "-UserId 'S-1-5-18'" in srt_principals[0] and "-LogonType ServiceAccount" in srt_principals[0], (
            f"Primary principal in setup-restore-task.ps1 must be S-1-5-18 ServiceAccount, got: {srt_principals[0]}"
        )
        srt_settings_m = re.search(r"\$Settings\s*=\s*New-ScheduledTaskSettingsSet\b(.*?New-TimeSpan\s+-Hours\s+\d+\))", srt_code, re.DOTALL)
        assert srt_settings_m, "Missing $Settings = New-ScheduledTaskSettingsSet block in setup-restore-task.ps1"
        srt_settings = srt_settings_m.group(0)
        assert "-StartWhenAvailable" in srt_settings and "-WakeToRun" in srt_settings
        assert "New-TimeSpan -Hours 1)" in srt_settings

        # Verify ai-hosts-block.ps1 Register-AutoRestore primary principal & settings block
        ai_reg_body = ps.extract_function_body("ai-hosts-block.ps1", "Register-AutoRestore")
        ai_principals = re.findall(r"New-ScheduledTaskPrincipal\s+([^\n]+)", ai_reg_body)
        assert len(ai_principals) >= 1
        assert "-UserId 'S-1-5-18'" in ai_principals[0] and "-LogonType ServiceAccount" in ai_principals[0], (
            f"Primary principal in ai-hosts-block.ps1 must be S-1-5-18 ServiceAccount, got: {ai_principals[0]}"
        )
        assert "-StartWhenAvailable" in ai_reg_body and "-WakeToRun" in ai_reg_body
        assert "New-TimeSpan -Hours 1)" in ai_reg_body

        for script in ("setup-restore-task.ps1", "ai-hosts-block.ps1"):
            code = ps.read_active_code(script)
            assert "System32\\WindowsPowerShell\\v1.0\\powershell.exe" in code
            assert "WindowsApps" in code
        ps_body = ps.extract_function_body("ai-hosts-block.ps1", "Get-PreferredPowerShell")
        assert "System32\\WindowsPowerShell\\v1.0\\powershell.exe" in ps_body

    @register("T1_F21_02", 1, "F21", "SID-aware User PATH management targets HKU\\<StudentSID>\\Environment with REG_EXPAND_SZ and never writes HKU\\.DEFAULT")
    def _():
        common_set = ps.extract_function_body("common.ps1", "Set-UserPathForTargetUser")
        restore_set = ps.extract_function_body("restore-and-cleanup.ps1", "Set-RegistryScopePathValue")
        assert "S-1-5-18" in common_set and "ExpandString" in common_set and "NTUSER.DAT" in common_set
        assert "S-1-5-18" in restore_set and "ExpandString" in restore_set and "NTUSER.DAT" in restore_set

    @register("T1_F21_03", 1, "F21", "ContestSetupExamStartEnforcement sets trigger EndBoundary = ExamEnd and passes -NotAfter to prevent post-exam hosts re-blocking")
    def _():
        task_code = ps.read_active_code("setup-restore-task.ps1")
        ai_body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        assert "EndBoundary" in task_code and "'-NotAfter'" in task_code
        assert "$NotAfter" in ai_body and "Skipping AI hosts block" in ai_body

    @register("T1_F21_04", 1, "F21", "restore-and-cleanup.ps1 suppresses -Shutdown at exact >25m word-boundary threshold and filters <=5MB student workspace sources")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert re.search(r"\$LateMinutes\s+-gt\s+25\b", code), (
            "restore-and-cleanup.ps1 must check exact word-boundary '$LateMinutes -gt 25'"
        )
        assert sim.extract_late_boot_threshold_minutes() == 25.0
        assert "$Shutdown = [switch]$false" in code
        bak_body = ps.extract_function_body("restore-and-cleanup.ps1", "Backup-ContestWorkspaceSources")
        base_body = ps.extract_function_body("restore-and-cleanup.ps1", "Resolve-WorkspaceBackupBaseDir")
        assert "ContestSetup-Workspace-Backup-" in bak_body
        for req_ext in (".cpp", ".cc", ".c", ".py", ".java"):
            assert f"'{req_ext}'" in bak_body, f"Backup-ContestWorkspaceSources missing extension '{req_ext}'"
        assert re.search(r"\$MaxBytes\s*=\s*5\s*\*\s*1024\s*\*\s*1024\b", bak_body)
        assert re.search(r"\$_\.Length\s+-gt\s+0\b", bak_body) and re.search(r"\$_\.Length\s+-le\s+\$MaxBytes\b", bak_body)
        assert "ContestSetup-Backups" in base_body

    @register("T1_F21_05", 1, "F21", "restore-and-cleanup.ps1 self-relocates to TEMP, restores MSYS2 .contest-bak configs, and sequences shutdown after rmdir")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "contest-restore-runner.ps1" in code and "IncludeReinvokedFromTemp" in code
        msys_body = ps.extract_function_body("restore-and-cleanup.ps1", "Restore-Msys2ContestConfiguration")
        assert "pacman.conf" in msys_body and "mirrorlist.*.contest-bak" in msys_body and "contestsetup-windows-roots.pem" in msys_body
        rmdir_pos = code.find("rmdir /s /q")
        bat_shutdown_pos = code.find('$BatchLines += \'shutdown.exe /s /f /t 15')
        assert -1 < rmdir_pos < bat_shutdown_pos

    # --- F22: Anti-Cheat Browser DoH/Copilot Lockdown & 2025-2026/KR AI Domain Expansion ---
    @register("T1_F22_01", 1, "F22", "ai-hosts-block.ps1 enforces exact 22 HKLM Browser DoH & Copilot policy values across Chrome, Edge, Brave, Whale, Firefox, and Windows")
    def _():
        core_tuples = sim.parse_browser_policy_tuples("ai-hosts-block.ps1", "Get-BrowserPolicySpecifications")
        ext_tuples = sim.parse_browser_policy_tuples("ai-hosts-block.ps1", "Get-ExtendedBrowserPolicySpecifications")
        assert len(core_tuples) == 13, f"Expected 13 core browser policies, got {len(core_tuples)}"
        assert len(ext_tuples) == 9, f"Expected 9 extended browser policies, got {len(ext_tuples)}"
        policy_map = {(kp, name): (vtype, val) for kp, name, vtype, val in (core_tuples + ext_tuples)}
        expected_policies = {
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "DnsOverHttpsMode"): ("String", "off"),
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "BuiltInDnsClientEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "DnsOverHttpsTemplates"): ("String", ""),
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "BuiltInAIAPIsEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "GenAILocalFoundationalModelSettings"): ("DWord", 1),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "DnsOverHttpsMode"): ("String", "off"),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "BuiltInDnsClientEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "HubsSidebarEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "CopilotPageContext"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "DnsOverHttpsTemplates"): ("String", ""),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "EdgeEntraCopilotPageContext"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge", "BuiltInAIAPIsEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave", "DnsOverHttpsMode"): ("String", "off"),
            ("HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave", "BuiltInDnsClientEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave", "DnsOverHttpsTemplates"): ("String", ""),
            ("HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave", "BraveAIChatEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale", "DnsOverHttpsMode"): ("String", "off"),
            ("HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale", "BuiltInDnsClientEnabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale", "DnsOverHttpsTemplates"): ("String", ""),
            ("HKLM:\\SOFTWARE\\Policies\\Mozilla\\Firefox\\DNSOverHTTPS", "Enabled"): ("DWord", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Mozilla\\Firefox\\DNSOverHTTPS", "Locked"): ("DWord", 1),
            ("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot", "TurnOffWindowsCopilot"): ("DWord", 1),
        }
        assert policy_map == expected_policies, f"Browser policy exact-value mismatch: {policy_map ^ expected_policies if hasattr(policy_map, '__xor__') else set(policy_map.items()) ^ set(expected_policies.items())}"

    @register("T1_F22_02", 1, "F22", "Browser policy state is backed up once to browser-policies.bak.json and restored by both ai-hosts-block.ps1 and restore-and-cleanup.ps1")
    def _():
        set_body = ps.extract_function_body("ai-hosts-block.ps1", "Set-ContestBrowserPolicies")
        res_body = ps.extract_function_body("ai-hosts-block.ps1", "Restore-ContestBrowserPolicies")
        fb_body = ps.extract_function_body("restore-and-cleanup.ps1", "Restore-BrowserPoliciesFallback")
        assert "browser-policies.bak.json" in ps.read_active_code("ai-hosts-block.ps1")
        assert "if (-not (Test-Path -LiteralPath $BrowserPolicyBackupPath))" in set_body
        assert "PriorValue" in res_body and "PriorVal" in fb_body

    @register("T1_F22_03", 1, "F22", "Expanded DefaultAiBlockDomains (>= 161 domains) contains frozen core AI domain set across frontier, coding, and Korean platforms")
    def _():
        domains = set(sim.get_default_ai_domains())
        assert len(domains) >= 161, f"Expected >= 161 base AI domains, got {len(domains)}"
        frozen_core_ai_domains = {
            "chatgpt.com",
            "openai.com",
            "chat.com",
            "claude.ai",
            "claude.com",
            "anthropic.com",
            "gemini.google.com",
            "aistudio.google.com",
            "notebooklm.google.com",
            "deepseek.com",
            "grok.com",
            "x.ai",
            "perplexity.ai",
            "copilot.microsoft.com",
            "m365copilot.com",
            "copilot.cloud.microsoft",
            "wrtn.ai",
            "clova-x.naver.com",
            "cue.search.naver.com",
            "liner.com",
            "alan.estsoft.ai",
            "genspark.ai",
            "manus.im",
            "lmarena.ai",
            "duck.ai",
            "qwen.ai",
            "kimi.com",
            "v0.dev",
            "bolt.new",
            "lovable.dev",
            "trae.ai",
            "augmentcode.com",
            "api2.cursor.sh",
            "api.individual.githubcopilot.com",
            "sora.com",
        }
        missing = sorted(frozen_core_ai_domains - domains)
        assert not missing, f"Frozen core AI domains missing from $DefaultAiBlockDomains: {missing}"

    @register("T1_F22_04", 1, "F22", "Apply-AiHostsBlock validates RestoreTime before mutating hosts, reverts on task failure, and flushes DNS cache")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        validate_pos = body.find("$PlannedRestoreTime = Get-RestoreTime")
        write_pos = body.find("Write-HostsFileWithRetry")
        register_pos = body.find("Register-AutoRestore")
        revert_pos = body.find("Restore-ContestBrowserPolicies")
        assert -1 < validate_pos < write_pos < register_pos < revert_pos
        dns_body = ps.extract_function_body("ai-hosts-block.ps1", "Invoke-DnsCacheFlush")
        assert "Clear-DnsClientCache" in dns_body and "ipconfig.exe /flushdns" in dns_body

    @register("T1_F22_05", 1, "F22", "-DeferAiBlockUntilExamStart stages ai-hosts-block.ps1 without early lock, and install-ai-hosts.ps1 propagates child exit codes")
    def _():
        setup_ai = ps.read_active_code("setup-ai-hosts.ps1")
        assert "DeferAiBlockUntilExamStart" in setup_ai and "IsBeforeExamStart" in setup_ai
        inst_ai = ps.read_active_code("install-ai-hosts.ps1")
        assert "2026-11-23T20:30:00+09:00" in inst_ai and "$ChildExitCode = $LASTEXITCODE" in inst_ai

    return tests
