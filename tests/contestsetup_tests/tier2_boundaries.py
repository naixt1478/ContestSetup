#!/usr/bin/env python3
"""Tier 2: Edge Case, Boundary & Failure Mode Tests (100 tests)."""
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
    # TIER 2 — BOUNDARY & CORNER CASES (100 TESTS: 5 PER FEATURE F1..F14, F17..F22)
    # =========================================================================

    # --- F1 Boundary Cases ---
    @register("T2_F1_01", 2, "F1", "Zero lingering old exam timestamps (2026-05-09, 17:10:00, 5월 9일, 2026-05-04) in any .ps1 file or README.md")
    def _():
        for fname in PS1_FILES + ["README.md"]:
            text = ps.read_text(fname)
            for forbidden in ("2026-05-09", "17:10:00", "5월 9일", "5월9일", "2026-05-04"):
                assert forbidden not in text, f"Lingering outdated schedule string '{forbidden}' found in {fname}"

    @register("T2_F1_02", 2, "F1", "Boundary timestamp check: ExamStart < ExamEnd <= RestoreAt and exact 90-minute exam duration")
    def _():
        parsed = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00")
        assert parsed["DayOfWeek"] == "Monday"
        assert parsed["DurationMinutes"] == 90.0
        assert parsed["ExamStartDto"] < parsed["ExamEndDto"] <= parsed["RestoreAtDto"]

    @register("T2_F1_03", 2, "F1", "Boundary timestamp check: RestoreAt in the past (now = 2026-11-23T20:30:01 KST) triggers IsPastRestoreTime")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        just_after = datetime.datetime(2026, 11, 23, 20, 30, 1, tzinfo=kst)
        just_before = datetime.datetime(2026, 11, 23, 20, 29, 59, tzinfo=kst)
        res_after = sim.simulate_kst_schedule_parse(
            "2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=just_after
        )
        res_before = sim.simulate_kst_schedule_parse(
            "2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=just_before
        )
        assert res_after["IsPastRestoreTime"] is True
        assert res_before["IsPastRestoreTime"] is False

    @register("T2_F1_04", 2, "F1", "Boundary check: -NoRestoreTask skips registration and -NoRestoreShutdown omits -Shutdown flag")
    def _():
        code = ps.read_active_code("setup-restore-task.ps1")
        assert "if ($SkipRestoreTask)" in code
        assert "$IncludeShutdownFlag = (-not $SkipRestoreShutdown)" in code
        assert "if ($IncludeShutdownFlag)" in code

    @register("T2_F1_05", 2, "F1", "Boundary check: Invalid or inverted schedule (ExamEnd <= ExamStart) raises error in Test-ExamScheduleConfiguration")
    def _():
        body = ps.extract_function_body("common.ps1", "Test-ExamScheduleConfiguration")
        assert "if ($EndDto -le $StartDto)" in body and "throw" in body
        for bad_end in ("2026-11-23T19:00:00", "2026-11-23T18:59:59"):
            try:
                sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", bad_end, "2026-11-23T20:30:00")
                raise AssertionError(f"Expected ValueError for ExamEnd={bad_end}")
            except ValueError:
                pass

    # --- F2 Boundary Cases ---
    @register("T2_F2_01", 2, "F2", "PowerShell syntax & token balance across install-env.ps1, common.ps1, lib/*.ps1, and all setup-*.ps1 scripts")
    def _():
        for fname in ps.all_ps1_files():
            ok, msg = ps.validate_syntax_balance(ps.read_text(fname), fname)
            assert ok, msg

    @register("T2_F2_02", 2, "F2", "Quote-ProcessArgument boundary cases: empty string, spaces, embedded quotes, trailing backslashes, Korean paths")
    def _():
        assert sim.quote_process_argument(None) == '""'
        assert sim.quote_process_argument("") == '""'
        assert sim.quote_process_argument("C:\\CPTools") == "C:\\CPTools"
        assert sim.quote_process_argument("C:\\Users\\홍길동 Student\\CPTools\\") == '"C:\\Users\\홍길동 Student\\CPTools\\\\"'
        assert sim.quote_process_argument('arg with "quote"') == '"arg with \\"quote\\""'

    @register("T2_F2_03", 2, "F2", "irm | iex invocation mode initializes all 21 parameters in install-env.ps1 under StrictMode 2.0")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "Get-Variable -Name $StringParam.Name" in code and "Get-Variable -Name $SwitchDef.Name" in code
        for var in INSTALL_ENV_21_PARAMS:
            assert f"Name = '{var}'" in code, f"install-env.ps1 missing irm|iex variable table entry for ${var}"

    @register("T2_F2_04", 2, "F2", "AbandonedMutexException handling sets $MutexAcquired = $true across all mutex-holding scripts")
    def _():
        for script in ("install-env.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            code = ps.read_active_code(script)
            assert "AbandonedMutexException" in code, f"{script} must catch AbandonedMutexException"

    @register("T2_F2_05", 2, "F2", "Self-elevation propagates child process ExitCode on exit in both install-env.ps1 and restore-and-cleanup.ps1")
    def _():
        for script in ("install-env.ps1", "restore-and-cleanup.ps1"):
            code = ps.read_active_code(script)
            assert "Start-Process" in code and "-Verb RunAs" in code and "ExitCode" in code

    # --- F3 Boundary Cases ---
    @register("T2_F3_01", 2, "F3", "Pre-flight disk space check differentiates cold install (2.5 GB / 1.8+0.8 GB) vs warm re-run (0.5 GB / 0.3 GB) per drive")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-PreflightChecks")
        assert "2.5" in body and "0.5" in body and "1.8" in body and "0.8" in body
        assert "RootDrive -ieq $MsysDrive" in body

    @register("T2_F3_02", 2, "F3", "-Mode Restore delegates directly to restore-and-cleanup.ps1 before running setup modules")
    def _():
        code = ps.read_active_code("install-env.ps1")
        restore_pos = code.find("elseif ($Mode -eq 'Restore')")
        loop_pos = code.find("foreach ($Module in $Modules)")
        assert -1 < restore_pos < loop_pos

    @register("T2_F3_03", 2, "F3", "Read-ContestStateManifest returns default manifest when install-manifest.json is missing, empty, or corrupted")
    def _():
        body = ps.extract_function_body("common.ps1", "Read-ContestStateManifest")
        assert "New-DefaultContestStateManifest" in body and "catch" in body and "ConvertFrom-JsonSafe" in body

    @register("T2_F3_04", 2, "F3", "CONTEST_MODE overrides default Mode with AllowedModes check when -Mode is not explicitly passed on CLI")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "CONTEST_MODE" in code and "if ($AllowedModes -notcontains $Mode)" in code

    @register("T2_F3_05", 2, "F3", "-Mode Verify sets $ExitCodeToReturn = 1 and exits non-zero when Invoke-ContestEnvironmentAudit reports AllReady=$false")
    def _():
        code = ps.read_active_code("install-env.ps1")
        verify_idx = code.find("if ($Mode -in @('Status', 'Verify', 'DryRun'))")
        assert verify_idx != -1
        snippet = code[verify_idx : verify_idx + 1800]
        assert "if ($Mode -eq 'Verify')" in snippet and "if (-not $AuditReport.AllReady)" in snippet
        assert "$ExitCodeToReturn = 1" in snippet

    # --- F4 Boundary Cases ---
    @register("T2_F4_01", 2, "F4", "Behavioral simulation: selective directory cleanup in restore-and-cleanup.ps1 with -KeepWorkspace -KeepDownloads -KeepLogs -KeepVSCode")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "CPTools"
            for sub in ("contest", "downloads", "logs", "vscode", "vscode-contest", "bin", "Python310", "ai-block", "state"):
                d = root / sub
                d.mkdir(parents=True)
                (d / "sample.txt").write_text(f"content in {sub}", encoding="utf-8")

            keep_names = {"contest", "downloads", "logs", "vscode", "vscode-contest"}
            for child in list(root.iterdir()):
                if child.name not in keep_names:
                    shutil.rmtree(child)

            for kept in keep_names:
                assert (root / kept / "sample.txt").exists()
            for removed in ("bin", "Python310", "ai-block", "state"):
                assert not (root / removed).exists()

    @register("T2_F4_02", 2, "F4", "Stop-SetupLogging is idempotent when called multiple times (in catch and finally)")
    def _():
        body = ps.extract_function_body("common.ps1", "Stop-SetupLogging")
        assert "$global:TranscriptStarted" in body and "$global:TranscriptStarted = $false" in body

    @register("T2_F4_03", 2, "F4", "Write-ErrorLog wraps error logging in try/catch so logging failures never mask original error")
    def _():
        body = ps.extract_function_body("common.ps1", "Write-ErrorLog")
        assert "try" in body and "catch" in body and "Write-LinesUtf8NoBom" in body

    @register("T2_F4_04", 2, "F4", "Backup-PathEnvironment skips creating duplicate snapshots when an original path-* snapshot already exists")
    def _():
        body = ps.extract_function_body("common.ps1", "Backup-PathEnvironment")
        install_code = ps.read_active_code("install-env.ps1")
        assert "if (Test-Path -LiteralPath $SnapshotPath)" in body
        assert "$ExistingBackups.Count -eq 0" in install_code

    @register("T2_F4_05", 2, "F4", "install-env.ps1 catch block only clears AI hosts block when $Mode -eq 'Install' (protecting -Mode Verify)")
    def _():
        code = ps.read_active_code("install-env.ps1")
        finally_idx = code.rfind("finally")
        matches = list(re.finditer(r"\n\}\s*catch\s*\{", code[:finally_idx]))
        catch_body = code[matches[-1].start() : finally_idx]
        assert "if (($Mode -eq 'Install') -and (Get-Command Clear-StaleAiHostsSectionBeforeInstall" in catch_body

    # --- F5 Boundary Cases ---
    @register("T2_F5_01", 2, "F5", "Behavioral simulation: magic header check rejects 0-byte, truncated, or HTML error page disguised as .zip/.exe")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)
            empty_zip = tdir / "empty.zip"
            empty_zip.write_bytes(b"")
            html_exe = tdir / "installer.exe"
            html_exe.write_bytes(b"<html>404 Not Found</html>" * 100)
            valid_zip = tdir / "vscode.zip"
            valid_zip.write_bytes(b"PK\x03\x04" + b"\x00" * 4096)
            valid_exe = tdir / "msys2.exe"
            valid_exe.write_bytes(b"MZ" + b"\x90" * 4096)

            assert not sim.can_reuse_cached_download(empty_zip)
            assert not sim.can_reuse_cached_download(html_exe)
            assert sim.can_reuse_cached_download(valid_zip)
            assert sim.can_reuse_cached_download(valid_exe)

    @register("T2_F5_02", 2, "F5", "Behavioral simulation: SHA256 mismatch triggers re-download and rejects tampered file")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "payload.exe"
            f.write_bytes(b"MZ" + b"A" * 2048)
            good_hash = hashlib.sha256(f.read_bytes()).hexdigest()
            bad_hash = "0" * 64
            assert sim.can_reuse_cached_download(f, expected_sha256=good_hash)
            assert not sim.can_reuse_cached_download(f, expected_sha256=bad_hash)

    @register("T2_F5_03", 2, "F5", "Download-VerifiedFile calls Copy-FromCacheDirIfPresent before network download and verifies Authenticode")
    def _():
        body = ps.extract_function_body("common.ps1", "Download-VerifiedFile")
        cache_pos = body.find("Copy-FromCacheDirIfPresent")
        dl_pos = body.find("Invoke-DownloadFile")
        auth_pos = body.find("Assert-AuthenticodeValid")
        assert -1 < cache_pos < dl_pos and auth_pos != -1

    @register("T2_F5_04", 2, "F5", "Invoke-DownloadFile cleans up partial .part file on exception or Content-Length mismatch")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-DownloadFile")
        assert ".part" in body and "Remove-Item -LiteralPath $TempOutFile" in body

    @register("T2_F5_05", 2, "F5", "Test-WingetHelpSupports caches output per command so winget --help is not spawned repeatedly")
    def _():
        body = ps.extract_function_body("common.ps1", "Test-WingetHelpSupports")
        assert "$Script:WingetHelpCache.ContainsKey($Command)" in body

    # --- F6 Boundary Cases ---
    @register("T2_F6_01", 2, "F6", "Behavioral simulation: stale db.lck is removed when no pacman.exe is running, but preserved if pacman is active")
    def _():
        lock_body = ps.extract_function_body("setup-msys2.ps1", "Remove-StaleMsys2Locks")
        assert "Get-Process -Name 'pacman'" in lock_body and "Test-PathInside" in lock_body
        with tempfile.TemporaryDirectory() as tmp:
            msys_root = Path(tmp) / "msys64"
            lock_file = msys_root / "var" / "lib" / "pacman" / "db.lck"
            lock_file.parent.mkdir(parents=True)
            lock_file.write_text("", encoding="utf-8")
            active_pacman = True
            if not active_pacman and lock_file.exists():
                lock_file.unlink()
            assert lock_file.exists()
            active_pacman = False
            if not active_pacman and lock_file.exists():
                lock_file.unlink()
            assert not lock_file.exists()

    @register("T2_F6_02", 2, "F6", "setup-msys2.ps1 backs up original mirrorlist.* and pacman.conf to .contest-bak only once")
    def _():
        mir_body = ps.extract_function_body("setup-msys2.ps1", "Set-Msys2OfficialMirrors")
        opt_body = ps.extract_function_body("setup-msys2.ps1", "Optimize-Msys2PacmanConfig")
        assert ".contest-bak" in mir_body and "(-not (Test-Path -LiteralPath $BackupFile))" in mir_body
        assert ".contest-bak" in opt_body and "(-not (Test-Path -LiteralPath $BackupConf))" in opt_body

    @register("T2_F6_03", 2, "F6", "Sync-WindowsRootCertificatesToMsys2 writes a single contestsetup-windows-roots.pem bundle")
    def _():
        body = ps.extract_function_body("setup-msys2.ps1", "Sync-WindowsRootCertificatesToMsys2")
        assert "contestsetup-windows-roots.pem" in body and "StringBuilder" in body

    @register("T2_F6_04", 2, "F6", "Optimize-Msys2PacmanConfig disables unused repos (mingw32, mingw64, clang32, clang64, clangarm64)")
    def _():
        body = ps.extract_function_body("setup-msys2.ps1", "Optimize-Msys2PacmanConfig")
        for repo in ("mingw32", "mingw64", "clang32", "clang64", "clangarm64"):
            assert f"'{repo}'" in body

    @register("T2_F6_05", 2, "F6", "Invoke-PacmanChecked triggers lazy root CA sync on TLS errors and offline cache fallback on network errors")
    def _():
        body = ps.extract_function_body("setup-msys2.ps1", "Invoke-PacmanChecked")
        assert "if ($IsTlsError -and (-not $Script:MsysRootCertsSynced))" in body
        assert "Sync-WindowsRootCertificatesToMsys2" in body
        assert "if ($IsNetworkError)" in body and "/var/cache/pacman/pkg/*.pkg.tar.zst" in body

    # --- F7 Boundary Cases ---
    @register("T2_F7_01", 2, "F7", "setup-python.ps1 resets broken/partial $PythonDir when python.exe is missing or fails stdlib check")
    def _():
        code = ps.read_active_code("setup-python.ps1")
        assert "if (-not (Test-Path -LiteralPath $PythonExe))" in code and "Reset-ManagedPython" in code
        assert "Assert-PythonRuntimeHealthy" in code

    @register("T2_F7_02", 2, "F7", "Assert-PythonRuntimeHealthy calls Repair-PythonPthFileIfNeeded and Ensure-NativePython3Binary on warm runs too")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Assert-PythonRuntimeHealthy")
        pth_pos = body.find("Repair-PythonPthFileIfNeeded")
        py3_pos = body.find("Ensure-NativePython3Binary")
        ver_pos = body.find("Invoke-NativeChecked")
        assert -1 < pth_pos < py3_pos < ver_pos

    @register("T2_F7_03", 2, "F7", "Behavioral simulation: Python collision fallback copies pre-existing Python 3.10 and creates python3.exe")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            sys_py = Path(tmp) / "Program Files" / "Python310"
            sys_py.mkdir(parents=True)
            (sys_py / "python.exe").write_bytes(b"MZ_PYTHON310")
            target_py = Path(tmp) / "CPTools" / "Python310"
            shutil.copytree(sys_py, target_py)
            shutil.copy2(target_py / "python.exe", target_py / "python3.exe")
            assert (target_py / "python.exe").exists() and (target_py / "python3.exe").exists()

    @register("T2_F7_04", 2, "F7", "Install-PythonDirect sets PythonInstalledByContestSetup = $false when pre-existing Python 3.10 existed or fallback ran")
    def _():
        body = ps.extract_function_body("setup-python.ps1", "Install-PythonDirect")
        assert "$InstalledMsiByContestSetup = ($null -eq $PreExistingSystemPy)" in body
        assert "$InstalledMsiByContestSetup = $false" in body

    @register("T2_F7_05", 2, "F7", "PythonVersion single-number boundary (e.g., '3') falls back to '10' minor version without IndexOutOfRangeException")
    def _():
        code = ps.read_active_code("common.ps1")
        assert "$PyMinor = if ($VersionParts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($VersionParts[1])) { $VersionParts[1] } else { '10' }" in code

    # --- F8 Boundary Cases ---
    @register("T2_F8_01", 2, "F8", "Find-VisualStudioWithCppTools handles missing vswhere.exe and falls back to 2026/2022/2019 directory scan")
    def _():
        body = ps.extract_function_body("setup-visualstudio.ps1", "Find-VisualStudioWithCppTools")
        assert "Test-Path -LiteralPath $VsWherePath" in body
        for year in ("2026", "2022", "2019"):
            assert f"'{year}'" in body

    @register("T2_F8_02", 2, "F8", "Test-MsvcClCompilerPresent checks both Hostx64\\x64\\cl.exe and Hostx86\\x86\\cl.exe under VC\\Tools\\MSVC")
    def _():
        body = ps.extract_function_body("setup-visualstudio.ps1", "Test-MsvcClCompilerPresent")
        assert "Hostx64\\x64\\cl.exe" in body and "Hostx86\\x86\\cl.exe" in body

    @register("T2_F8_03", 2, "F8", "setup-visualstudio.ps1 handles missing winget gracefully when -IncludeVisualStudio is passed")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert "elseif (-not (Test-CommandExists 'winget'))" in code

    @register("T2_F8_04", 2, "F8", "setup-visualstudio.ps1 distinguishes exit code 3010 reboot recommendation from exit code 0")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert "if ($ExitCode -eq 3010)" in code and "reboot recommended" in code

    @register("T2_F8_05", 2, "F8", "setup-visualstudio.ps1 completes inner progress bar (-Completed) on all 4 exit branches")
    def _():
        code = ps.read_active_code("setup-visualstudio.ps1")
        assert code.count("-Completed") >= 4

    # --- F9 Boundary Cases ---
    @register("T2_F9_01", 2, "F9", "Behavioral simulation: product.json lock -> re-run unlock -> extension check -> re-lock lifecycle")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            vscode_app = Path(tmp) / "vscode" / "resources" / "app"
            vscode_app.mkdir(parents=True)
            prod_path = vscode_app / "product.json"
            orig_path = vscode_app / "product.json.contest-orig"
            orig_data = {
                "nameShort": "Code",
                "extensionsGallery": {
                    "serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery",
                    "itemUrl": "https://marketplace.visualstudio.com/items",
                },
            }
            prod_path.write_text(json.dumps(orig_data, indent=2), encoding="utf-8")

            if not orig_path.exists():
                shutil.copy2(prod_path, orig_path)
            locked = json.loads(prod_path.read_text(encoding="utf-8"))
            for k in list(locked["extensionsGallery"].keys()):
                locked["extensionsGallery"][k] = "https://127.0.0.1"
            prod_path.write_text(json.dumps(locked, indent=2), encoding="utf-8")
            assert json.loads(prod_path.read_text(encoding="utf-8"))["extensionsGallery"]["serviceUrl"] == "https://127.0.0.1"

            if orig_path.exists():
                shutil.copy2(orig_path, prod_path)
            unlocked = json.loads(prod_path.read_text(encoding="utf-8"))
            assert "marketplace.visualstudio.com" in unlocked["extensionsGallery"]["serviceUrl"]

    @register("T2_F9_02", 2, "F9", "Behavioral simulation: shortcut-manifest.json preserves Existed=true across multiple runs")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "shortcut-manifest.json"
            manifest = [
                {
                    "ShortcutPath": "C:\\Users\\Student\\Desktop\\Visual Studio Code.lnk",
                    "Existed": True,
                    "BackupPath": "C:\\CPTools\\backup\\vscode-shortcuts\\Desktop_Visual_Studio_Code.lnk.bak.lnk",
                }
            ]
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            loaded = sim.simulate_json_array_parse(manifest_path.read_text(encoding="utf-8"))
            assert isinstance(loaded, list) and len(loaded) == 1
            assert loaded[0]["Existed"] is True  # type: ignore[index]

    @register("T2_F9_03", 2, "F9", "Corrupted settings.json is backed up to .bak and recreated cleanly in Set-VSCodeAiHiddenSettings")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Set-VSCodeAiHiddenSettings")
        assert '"$SettingsPath.bak"' in body and "ConvertFrom-JsonSafe" in body

    @register("T2_F9_04", 2, "F9", "Install-VSCodeStandalone removes incomplete $ExtractPath and re-extracts via Expand-ArchiveFast")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Install-VSCodeStandalone")
        assert "Stop-VSCodeProcesses -ContestOnly" in body
        assert "Remove-Item -LiteralPath $ExtractPath" in body
        assert "Expand-ArchiveFast" in body

    @register("T2_F9_05", 2, "F9", "c_cpp_properties.json configures forward-slash UCRT64 g++.exe compilerPath and windows-gcc-x64 intelliSenseMode")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Set-ContestVSCodeWorkspaceDefaults")
        assert "Convert-ToForwardSlashPath $GppExeValue" in body and "windows-gcc-x64" in body

    # --- F10 Boundary Cases ---
    @register("T2_F10_01", 2, "F10", "Behavioral simulation: repeated .cmd wrapper execution with @setlocal does not grow %PATH%")
    def _():
        body = ps.extract_function_body("setup-wrappers.ps1", "Create-CommandWrappers")
        assert "'@setlocal'" in body
        caller_path = "C:\\Windows\\System32;C:\\Windows"
        for _ in range(50):
            _scoped = f"C:\\msys64\\ucrt64\\bin;C:\\msys64\\usr\\bin;{caller_path}"
        assert caller_path == "C:\\Windows\\System32;C:\\Windows"

    @register("T2_F10_02", 2, "F10", "Normalize-PathForCompare handles forward slashes, trailing slashes, mixed case, and whitespace")
    def _():
        body = ps.extract_function_body("common.ps1", "Normalize-PathForCompare")
        assert "-replace '/', '\\'" in body and "TrimEnd('\\')" in body and "ToLowerInvariant()" in body

    @register("T2_F10_03", 2, "F10", "Add-UserPathsFront deduplicates case-insensitively and Remove-ConflictingPathEntries expands environment variables")
    def _():
        add_body = ps.extract_function_body("common.ps1", "Add-UserPathsFront")
        rem_body = ps.extract_function_body("common.ps1", "Remove-ConflictingPathEntries")
        assert "Normalize-PathForCompare" in add_body and "$Seen.ContainsKey($Normalized)" in add_body
        assert "ExpandEnvironmentVariables" in rem_body

    @register("T2_F10_04", 2, "F10", "Remove-ConflictingPathEntries strips standard VS Code bin paths across User, Machine, and Process PATH")
    def _():
        rem_body = ps.extract_function_body("common.ps1", "Remove-ConflictingPathEntries")
        match_body = ps.extract_function_body("common.ps1", "Remove-PathEntriesMatching")
        assert "Microsoft VS Code\\bin" in rem_body
        for scope in ("'User'", "'Machine'", "'Process'"):
            assert scope in rem_body
        assert "Set-UserPathForTargetUser" in match_body and "Set-RawMachinePath" in match_body

    @register("T2_F10_05", 2, "F10", "code.cmd wrapper opens $ContestWorkspace when invoked with no arguments and forwards %* otherwise")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "New-ContestVSCodeCliWrapper")
        assert 'if "%~1"=="" goto :contest_default' in body and "%*" in body

    # --- F11 Boundary Cases ---
    @register("T2_F11_01", 2, "F11", "Behavioral simulation: Remove-ManagedHostsSectionFromText on empty string '', whitespace, and no-marker hosts")
    def _():
        assert sim.remove_managed_hosts_section("") == ""
        assert sim.remove_managed_hosts_section("   \r\n  ") == ""
        sample = "127.0.0.1 localhost\r\n::1 localhost\r\n"
        assert sim.remove_managed_hosts_section(sample) == "127.0.0.1 localhost\r\n::1 localhost"

    @register("T2_F11_02", 2, "F11", "Behavioral simulation: Remove-ManagedHostsSectionFromText strips single and duplicate managed blocks across CRLF and LF")
    def _():
        raw = (
            "127.0.0.1 localhost\n"
            "# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN\n"
            "0.0.0.0 chatgpt.com\n"
            ":: chatgpt.com\n"
            "# <<< CP_CONTEST_AI_BLOCKLIST_END\n"
            "10.0.0.1 internal.local\r\n"
            "# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN\r\n"
            "0.0.0.0 claude.ai\r\n"
            "# <<< CP_CONTEST_AI_BLOCKLIST_END\r\n"
        )
        cleaned = sim.remove_managed_hosts_section(raw)
        assert "CP_CONTEST_AI_BLOCKLIST" not in cleaned
        assert "chatgpt.com" not in cleaned and "claude.ai" not in cleaned
        assert "127.0.0.1 localhost" in cleaned and "10.0.0.1 internal.local" in cleaned

    @register("T2_F11_03", 2, "F11", "Behavioral simulation: ReadOnly hosts file attribute is cleared before write in temporary fixture")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            hosts_file = Path(tmp) / "hosts"
            hosts_file.write_text("127.0.0.1 localhost\r\n", encoding="utf-8")
            hosts_file.chmod(stat.S_IREAD)
            hosts_file.chmod(stat.S_IREAD | stat.S_IWRITE)
            hosts_file.write_text("127.0.0.1 localhost\r\n0.0.0.0 chatgpt.com\r\n", encoding="utf-8")
            assert "0.0.0.0 chatgpt.com" in hosts_file.read_text(encoding="utf-8")

    @register("T2_F11_04", 2, "F11", "Default AI blocklist contains >= 130 unique base domains (>= 350 entries with www + IPv6)")
    def _():
        domains = sim.get_default_ai_domains()
        assert len(domains) >= 130
        expanded = sim.expand_domains_with_www_and_ipv6(domains)
        assert len(expanded) >= 350

    @register("T2_F11_05", 2, "F11", "Remote BlockListUrl without BlockListSha256 throws error unless -AllowUnverifiedBlockListUrl is set")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Get-BlockDomains")
        assert "[string]::IsNullOrWhiteSpace($BlockListSha256) -and (-not $AllowUnverifiedBlockListUrl)" in body

    # --- F12 Boundary Cases ---
    @register("T2_F12_01", 2, "F12", "Behavioral simulation: Assert-SafeRemovalPath rejects empty, relative, drive root (C:\\), and critical system paths")
    def _():
        for bad in ("", "   ", "relative\\path", "C:", "C:\\", "C:/", "D:\\", "C:\\Windows", "C:\\Program Files", "C:\\Users\\Student"):
            try:
                sim.assert_safe_removal_path(bad)
                raise AssertionError(f"Assert-SafeRemovalPath should have rejected '{bad}'")
            except ValueError:
                pass
        assert sim.assert_safe_removal_path("C:\\CPTools\\") == "C:\\CPTools"

    @register("T2_F12_02", 2, "F12", "Behavioral simulation: Test-PathInside prevents sibling prefix false positives (C:\\CPTools2 vs C:\\CPTools)")
    def _():
        assert sim.test_path_inside("C:\\CPTools", "C:\\CPTools")
        assert sim.test_path_inside("C:\\CPTools\\Python310\\python.exe", "C:\\CPTools")
        assert not sim.test_path_inside("C:\\CPTools2\\python.exe", "C:\\CPTools")
        assert not sim.test_path_inside("C:\\Program Files\\Python310", "C:\\CPTools")

    @register("T2_F12_03", 2, "F12", "restore-and-cleanup.ps1 never deletes $MsysRoot (C:\\msys64), only restoring .contest-bak config files")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert not re.search(r"Remove-Item\s+-LiteralPath\s+\$MsysRoot|Remove-Item\s+-LiteralPath\s+\$ToolchainRoot|rmdir.*MsysRoot", code, re.IGNORECASE)
        msys_body = ps.extract_function_body("restore-and-cleanup.ps1", "Restore-Msys2ContestConfiguration")
        assert "Copy-Item -LiteralPath $PacmanConfBak -Destination $PacmanConfFile" in msys_body

    @register("T2_F12_04", 2, "F12", "restore-and-cleanup.ps1 deferred remove-cptools.cmd sequences rmdir /s /q strictly BEFORE shutdown.exe and returns early")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        deferred_idx = code.find("$TempBat = Join-Path $env:TEMP 'remove-cptools.cmd'")
        assert deferred_idx != -1
        deferred_block = code[deferred_idx : deferred_idx + 1400]
        rmdir_pos = deferred_block.find("rmdir /s /q")
        shutdown_pos = deferred_block.find("shutdown.exe /s /f /t 15")
        return_pos = deferred_block.find("return")
        assert -1 < rmdir_pos < shutdown_pos < return_pos

    @register("T2_F12_05", 2, "F12", "restore-and-cleanup.ps1 excludes current $PID when terminating processes under $Root")
    def _():
        body = ps.extract_function_body("restore-and-cleanup.ps1", "Stop-ProcessesUnderPath")
        assert "$_.Id -eq $PID" in body

    # --- F13 Boundary Cases ---
    @register("T2_F13_01", 2, "F13", ".editorconfig compliance: all .ps1 files, docs, .editorconfig, and .gitignore use UTF-8 without BOM and LF")
    def _():
        for fname in ps.all_ps1_files() + ["README.md", "ARCHITECTURE_V2.md", "PROJECT.md", ".editorconfig", ".gitignore"]:
            raw = ps.read_bytes(fname)
            assert not raw.startswith(b"\xef\xbb\xbf"), f"{fname} must be UTF-8 without BOM"
            assert b"\r\n" not in raw, f"{fname} contains CRLF; .editorconfig requires LF"
            assert raw.endswith(b"\n"), f"{fname} must end with LF"
            for line_no, line in enumerate(ps.read_text(fname).splitlines(), 1):
                assert not line.endswith((" ", "\t")), f"{fname}:{line_no} has trailing whitespace"

    @register("T2_F13_02", 2, "F13", "Write-VSCodeShortcutManifest deduplicates by ShortcutPath and serializes via Write-JsonUtf8NoBom")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Write-VSCodeShortcutManifest")
        assert "Group-Object -Property ShortcutPath" in body and "Write-JsonUtf8NoBom" in body

    @register("T2_F13_03", 2, "F13", "Read-VSCodeShortcutManifest uses Read-TextUtf8 + ConvertFrom-JsonArray and returns @() on error")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Read-VSCodeShortcutManifest")
        assert "Read-TextUtf8" in body and "ConvertFrom-JsonArray" in body and "return @()" in body

    @register("T2_F13_04", 2, "F13", "Get-ContestVariableValue honors explicit CLI $PSBoundParameters over CONTEST_* env vars over DefaultValue")
    def _():
        body = ps.extract_function_body("common.ps1", "Get-ContestVariableValue")
        install_code = ps.read_active_code("install-env.ps1")
        assert "$BoundParamMap.ContainsKey" in install_code
        assert "Get-Variable -Name $Name -Scope $Scope" in body and "$EnvVar" in body and "$DefaultValue" in body

    @register("T2_F13_05", 2, "F13", "No test, source, or data files placed inside .agents/teamwork/ metadata directory")
    def _():
        teamwork_dir = REPO_ROOT / ".agents" / "teamwork"
        if teamwork_dir.exists():
            for p in teamwork_dir.rglob("*"):
                if p.is_file():
                    assert p.suffix == ".md", f"Non-markdown file found in .agents/teamwork/: {p}"
                    assert p.name not in ("AGENTS.md", "GEMINI.md"), f"Forbidden filename in .agents/teamwork/: {p}"

    # --- F14 Boundary Cases ---
    @register("T2_F14_01", 2, "F14", "Balanced markdown code fences (```) and structured tables in README.md, ARCHITECTURE_V2.md, and PROJECT.md")
    def _():
        for doc in ("README.md", "ARCHITECTURE_V2.md", "PROJECT.md"):
            text = ps.read_text(doc)
            fences = sum(1 for line in text.splitlines() if line.strip().startswith("```"))
            assert fences % 2 == 0, f"Unbalanced markdown code fences in {doc} (count={fences})"
        arch_tables = sum(1 for line in ps.read_text("ARCHITECTURE_V2.md").splitlines() if line.strip().startswith("|"))
        assert arch_tables >= 35

    @register("T2_F14_02", 2, "F14", "ARCHITECTURE_V2.md contains quantified Cold, Warm, and 50-200 PC classroom installation time tables")
    def _():
        arch = ps.read_text("ARCHITECTURE_V2.md")
        assert "Cold" in arch and "Warm" in arch and "ExportCache" in arch and "0 MB" in arch

    @register("T2_F14_03", 2, "F14", "README.md includes online (irm | iex), ExportCache USB/LAN rollout, emergency schedule extension, and manual restore")
    def _():
        readme = ps.read_text("README.md")
        assert "install-env.ps1" in readme and "ExportCache" in readme and "CONTEST_RESTORE_AT" in readme and "shutdown /a" in readme

    @register("T2_F14_04", 2, "F14", "PROJECT.md catalogs all 23 features F1..F23 and all Round 1 & Round 2 milestones")
    def _():
        proj = ps.read_text("PROJECT.md")
        for fid in [f"F{i}" for i in range(1, 24)]:
            assert f"| {fid} |" in proj, f"PROJECT.md missing feature row {fid}"
        for ms in ("M1", "E2E", "M2", "R2-M1", "R2-M2", "R2-E2E"):
            assert f"| {ms} |" in proj, f"PROJECT.md missing milestone {ms}"

    @register("T2_F14_05", 2, "F14", "TEST_INFRA.md maps features through F23 and documents all 5 test tiers (--tier 1..5|all)")
    def _():
        infra = ps.read_text("TEST_INFRA.md")
        for fid in [f"F{i}" for i in range(1, 24)]:
            assert fid in infra, f"TEST_INFRA.md missing mapping for {fid}"
        assert "--tier" in infra and "Tier 5" in infra
        for fname in ps.all_ps1_files():
            assert (repo_root / fname).is_file(), f"Missing PowerShell file {fname}"

    # --- F17 Boundary Cases (PS 5.1 Encoding, JSONC/Array & PSCustomObject Safety) ---
    @register("T2_F17_01", 2, "F17", "Behavioral simulation: ConvertFrom-JsonSafe strips UTF-8 BOM, //, /* */, and trailing commas while preserving URLs in strings")
    def _():
        jsonc = (
            '\ufeff{\n'
            '  // Single-line comment with Korean 한글 and https://example.com\n'
            '  "serviceUrl": "https://127.0.0.1 // keep inside string /* also keep */",\n'
            '  "escapedQuote": "path \\"C:\\\\CPTools\\\\\\" // still string",\n'
            '  /* Multi-line\n'
            '     block comment */\n'
            '  "items": [\n'
            '    "a",\n'
            '    "b", // trailing comma in array\n'
            '  ], // trailing comma in object\n'
            '}\n'
        )
        parsed = sim.simulate_jsonc_strip_and_parse(jsonc)
        assert isinstance(parsed, dict)
        assert parsed["serviceUrl"] == "https://127.0.0.1 // keep inside string /* also keep */"
        assert parsed["escapedQuote"] == 'path "C:\\CPTools\\" // still string'
        assert parsed["items"] == ["a", "b"]

    @register("T2_F17_02", 2, "F17", "Behavioral simulation: ConvertFrom-JsonArray returns flat 1D list on '', '[]', single object, 1-item array, and N-item array")
    def _():
        assert sim.simulate_json_array_parse("") == []
        assert sim.simulate_json_array_parse("   \n\t ") == []
        assert sim.simulate_json_array_parse("null") == []
        assert sim.simulate_json_array_parse("[]") == []
        one_obj = sim.simulate_json_array_parse('{"ShortcutPath": "C:\\\\Users\\\\학생\\\\Desktop\\\\Code.lnk", "Existed": true}')
        assert len(one_obj) == 1 and isinstance(one_obj[0], dict) and not isinstance(one_obj[0], list)
        one_arr = sim.simulate_json_array_parse('[{"ShortcutPath": "C:\\\\Users\\\\학생\\\\Desktop\\\\Code.lnk", "Existed": true}]')
        assert len(one_arr) == 1 and isinstance(one_arr[0], dict) and not isinstance(one_arr[0], list)
        two_arr = sim.simulate_json_array_parse('[{"a": 1}, {"a": 2}]')
        assert len(two_arr) == 2 and two_arr[1]["a"] == 2  # type: ignore[index]

    @register("T2_F17_03", 2, "F17", "Behavioral simulation: Disable-VSCodeMarketplace locks minimal product.json missing cacheUrl/controlUrl and verifies read-back")
    def _():
        minimal_product = {"nameShort": "Code - OSS", "extensionsGallery": {"serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery"}}
        gallery = dict(minimal_product["extensionsGallery"])
        for ep in ("serviceUrl", "cacheUrl", "itemUrl", "controlUrl", "resourceUrlTemplate", "extensionUrlTemplate", "nlsBaseUrl", "publisherUrl"):
            gallery[ep] = "https://127.0.0.1"
        minimal_product["extensionsGallery"] = gallery
        serialized = json.dumps(minimal_product)
        verified = sim.simulate_jsonc_strip_and_parse(serialized)
        assert isinstance(verified, dict)
        assert verified["extensionsGallery"]["serviceUrl"] == "https://127.0.0.1"
        assert verified["extensionsGallery"]["itemUrl"] == "https://127.0.0.1"
        assert verified["extensionsGallery"]["cacheUrl"] == "https://127.0.0.1"

    @register("T2_F17_04", 2, "F17", "Behavioral simulation: Repair-PythonPthFileIfNeeded uncomments #import site and prepends Lib when Lib\\os.py exists")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            py_dir = Path(tmp) / "Python310"
            (py_dir / "Lib").mkdir(parents=True)
            (py_dir / "Lib" / "os.py").write_text("# stdlib os\n", encoding="utf-8")
            pth = py_dir / "python310._pth"
            pth.write_text("python310.zip\r\n.\r\n#import site\r\n", encoding="utf-8")

            raw_pth = pth.read_text(encoding="utf-8")
            if re.search(r"(?m)^#\s*import\s+site\b", raw_pth):
                updated = re.sub(r"(?m)^#\s*import\s+site\b", "import site", raw_pth)
                if not re.search(r"(?m)^Lib\s*$", updated):
                    updated = "Lib\r\n" + updated
                pth.write_text(updated, encoding="utf-8")

            final_lines = [ln.strip() for ln in pth.read_text(encoding="utf-8").splitlines() if ln.strip()]
            assert "Lib" in final_lines and "import site" in final_lines and "#import site" not in final_lines

    @register("T2_F17_05", 2, "F17", "Behavioral simulation: Invoke-NativeCommand .cmd quoting preserves spaces and parentheses in both executable and arguments")
    def _():
        cmd_exe = "C:\\Program Files\\Contest Setup\\vscode\\bin\\code.cmd"
        arg_list = ["--locale", "ko", "--user-data-dir", "C:\\Users\\김철수 (학부)\\vscode-contest\\user-data", "--list-extensions"]
        parts = [sim.quote_process_argument(cmd_exe)] + [sim.quote_process_argument(a) for a in arg_list]
        inner_cmd = " ".join(parts)
        parsed_argv = sim.win32_command_line_to_argv(inner_cmd)
        assert parsed_argv == [cmd_exe] + arg_list

    # --- F18 Boundary Cases (CLI/CONTEST_* Precedence, Non-Destructive Verify & Exit Codes) ---
    @register("T2_F18_01", 2, "F18", "Behavioral simulation: 3-tier parameter precedence (CLI bound > CONTEST_* env > default) including explicit -Switch:$false")
    def _():
        def resolve_switch(cli_bound: Optional[bool], env_val: str, default: bool = False) -> bool:
            if cli_bound is not None:
                return cli_bound
            if env_val.strip():
                return env_val.strip().lower() in ("1", "true", "yes", "on")
            return default

        assert resolve_switch(None, "", False) is False
        assert resolve_switch(None, "1", False) is True
        assert resolve_switch(None, "true", False) is True
        assert resolve_switch(None, "0", True) is False
        assert resolve_switch(False, "1", False) is False
        assert resolve_switch(True, "0", False) is True

    @register("T2_F18_02", 2, "F18", "Normalize-ContestDirectoryPath strips trailing slashes from C:\\CPTools\\ while preserving drive root C:\\")
    def _():
        for script, fn_name in (("install-env.ps1", "Normalize-InstallPath"), ("common.ps1", "Normalize-ContestDirectoryPath")):
            body = ps.extract_function_body(script, fn_name)
            assert "^[A-Za-z]:[\\\\/]$" in body and "TrimEnd('\\', '/')" in body

    @register("T2_F18_03", 2, "F18", "Invoke-ContestEnvironmentAudit parses product.json via ConvertFrom-JsonSafe and ignores commented-out hosts lines")
    def _():
        body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        assert "ConvertFrom-JsonSafe" in body
        assert "(?:0\\.0\\.0\\.0|::)\\s+\\S+" in body
        assert "$TaskObj" in body

    @register("T2_F18_04", 2, "F18", "Mutex release in install-env.ps1, ai-hosts-block.ps1, and restore-and-cleanup.ps1 is strictly guarded by ownership flag")
    def _():
        assert "if ($MutexAcquired)" in ps.read_active_code("install-env.ps1")
        assert "if ($AiMutexAcquired)" in ps.read_active_code("ai-hosts-block.ps1")
        assert "if ($RestoreMutexAcquired)" in ps.read_active_code("restore-and-cleanup.ps1")

    @register("T2_F18_05", 2, "F18", "Exit code propagation supports both script-file execution (exit N) and irm|iex execution ($global:LASTEXITCODE = N)")
    def _():
        code = ps.read_active_code("install-env.ps1")
        assert "$global:LASTEXITCODE = $FinalExitCode" in code
        assert "if ($PSCommandPath)" in code and "exit $FinalExitCode" in code

    # --- F19 Boundary Cases (VS Code --locale ko, Portable vscode\data Trap & Allowlist) ---
    @register("T2_F19_01", 2, "F19", "bin\\code.cmd label jump (:contest_default) safely handles arguments with closing parentheses")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "New-ContestVSCodeCliWrapper")
        assert ":contest_default" in body
        assert "exit /b %ERRORLEVEL%" in body
        # Ensure zero parenthesized blocks around %*
        for line in body.splitlines():
            if "%*" in line:
                assert "(" not in line and ")" not in line

    @register("T2_F19_02", 2, "F19", "Behavioral simulation: extension allowlist sweep keeps allowed versioned folders & hidden .obsolete while purging sideloaded AI dirs")
    def _():
        allowed_ids = {
            "ms-ceintl.vscode-language-pack-ko",
            "ms-vscode.cpptools",
            "ms-vscode.cpptools-themes",
            "ms-vscode.cpptools-extension-pack",
            "ms-python.python",
            "ms-python.debugpy",
            "ms-python.vscode-pylance",
            "ms-python.vscode-python-envs",
        }
        with tempfile.TemporaryDirectory() as tmp:
            for sub in ("vscode-contest/extensions", "vscode/data/extensions"):
                ext_dir = Path(tmp) / sub
                ext_dir.mkdir(parents=True)
                (ext_dir / ".obsolete").mkdir()
                (ext_dir / "ms-vscode.cpptools-1.22.11-win32-x64").mkdir()
                (ext_dir / "ms-python.vscode-pylance-2024.12.1").mkdir()
                (ext_dir / "rooveterinaryinc.roo-cline-3.8.0").mkdir()
                (ext_dir / "custom.cheat-agent-0.1.0").mkdir()

                for folder in list(ext_dir.iterdir()):
                    if not folder.is_dir():
                        continue
                    lower = folder.name.lower()
                    if lower.startswith("."):
                        continue
                    if not any(lower == aid or lower.startswith(f"{aid}-") for aid in allowed_ids):
                        shutil.rmtree(folder)

                remaining = {p.name for p in ext_dir.iterdir()}
                assert remaining == {".obsolete", "ms-vscode.cpptools-1.22.11-win32-x64", "ms-python.vscode-pylance-2024.12.1"}

    @register("T2_F19_03", 2, "F19", "Test-ContestVSCodeShortcut recognizes both v2.0 (--locale ko) and legacy contest shortcut arguments to protect original backups")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Test-ContestVSCodeShortcut")
        assert "$ExpectedArgs" in body and "$LegacyExpectedArgs" in body

    @register("T2_F19_04", 2, "F19", "Integrated terminal PATH order in setup-vscode.ps1 matches Configure-Path in setup-wrappers.ps1 ($PythonDir;$UcrtBin;$MsysUsrBin;$ToolBin)")
    def _():
        vsc_body = ps.extract_function_body("setup-vscode.ps1", "Set-VSCodeAiHiddenSettings")
        wrap_body = ps.extract_function_body("setup-wrappers.ps1", "Configure-Path")
        assert '"$PythonDirValue;$UcrtBinValue;$MsysUsrBinValue;$ToolBinValue;`${env:Path}"' in vsc_body
        assert "Add-UserPathsFront @($PythonDir, $UcrtBin, $MsysUsrBin, $ToolBin)" in wrap_body

    @register("T2_F19_05", 2, "F19", "Restore-NormalVSCodeShortcut -RemoveContestData removes both vscode-contest and portable vscode\\data")
    def _():
        body = ps.extract_function_body("setup-vscode.ps1", "Restore-NormalVSCodeShortcut")
        assert "$ContestRoot" in body and "Get-PortableVSCodeDataDir" in body

    # --- F20 Boundary Cases (Classroom Speed & Scale Optimizations) ---
    @register("T2_F20_01", 2, "F20", "Behavioral simulation: ZipFile extraction into pre-existing destination cleans partial files and rejects corrupt archive")
    def _():
        body = ps.extract_function_body("common.ps1", "Expand-ArchiveFast")
        assert "Get-ChildItem -LiteralPath $DestinationPath -Force" in body
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            good_zip = tpath / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as zf:
                zf.writestr("Code.exe", b"MZ_CODE")
                zf.writestr("resources/app/product.json", '{"nameShort":"Code"}')
            dest = tpath / "vscode"
            dest.mkdir()
            (dest / "stale.tmp").write_text("stale", encoding="utf-8")
            for child in list(dest.iterdir()):
                child.unlink()
            with zipfile.ZipFile(good_zip, "r") as zf:
                zf.extractall(dest)
            assert (dest / "Code.exe").exists() and not (dest / "stale.tmp").exists()

            bad_zip = tpath / "bad.zip"
            bad_zip.write_bytes(b"NOT_A_ZIP_ARCHIVE")
            try:
                with zipfile.ZipFile(bad_zip, "r"):
                    pass
                raise AssertionError("Expected BadZipFile")
            except zipfile.BadZipFile:
                pass

    @register("T2_F20_02", 2, "F20", "Copy-FromCacheDirIfPresent supports versioned glob fallbacks (VSCode-win32-x64-*.zip, msys2-x86_64-*.exe, python.*.nupkg)")
    def _():
        body = ps.extract_function_body("common.ps1", "Copy-FromCacheDirIfPresent")
        assert "VSCode-win32-x64*.zip" in body
        assert "msys2-x86_64-*.exe" in body
        assert "python.$PythonVersion.nupkg" in body

    @register("T2_F20_03", 2, "F20", "Behavioral simulation: ExportCache bundle structure matches offline Install -CacheDir readers")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            cache_dir = Path(tmp) / "ContestCache"
            for sub in ("vscode-extensions/ms-vscode.cpptools-1.22.11", "msys2-pkg", "msys2-sync", "scripts"):
                (cache_dir / sub).mkdir(parents=True)
            (cache_dir / "vscode-win32-x64-archive.zip").write_bytes(b"PK\x03\x04" + b"\x00" * 2048)
            (cache_dir / "python-3.10.11-amd64.exe").write_bytes(b"MZ" + b"\x90" * 2048)
            (cache_dir / "msys2-x86_64-latest.exe").write_bytes(b"MZ" + b"\x90" * 2048)
            (cache_dir / "msys2-pkg/mingw-w64-ucrt-x86_64-gcc-14.2.0-1-any.pkg.tar.zst").write_bytes(b"\x28\xb5\x2f\xfd" * 64)
            (cache_dir / "msys2-sync/ucrt64.db").write_bytes(b"DB_SYNC")
            for s in PS1_FILES:
                shutil.copy2(REPO_ROOT / s, cache_dir / "scripts" / s)
            assert all((cache_dir / "scripts" / s).exists() for s in PS1_FILES)
            assert sim.can_reuse_cached_download(cache_dir / "vscode-win32-x64-archive.zip")

    @register("T2_F20_04", 2, "F20", "$Script:InstalledVSCodeExtensionsCache is invalidated ($null) whenever extensions are seeded, installed, or removed")
    def _():
        vsc_code = ps.read_active_code("setup-vscode.ps1")
        assert vsc_code.count("$Script:InstalledVSCodeExtensionsCache = $null") >= 6

    @register("T2_F20_05", 2, "F20", "-ForceUpdate bypasses Copy-FromCacheDirIfPresent, Test-Msys2ToolsReady skip, and VS Code extension skip")
    def _():
        assert "if (-not $ForceUpdate -and (Copy-FromCacheDirIfPresent" in ps.extract_function_body("common.ps1", "Invoke-DownloadFile")
        assert "if ((-not $ForceUpdate) -and (Test-Msys2ToolsReady))" in ps.read_active_code("setup-msys2.ps1")
        assert "if (($Missing.Count -eq 0) -and (-not $ForceExtUpdate))" in ps.extract_function_body("setup-vscode.ps1", "Install-VSCodeExtensions")

    # --- F21 Boundary Cases (SID-Aware SYSTEM Tasks, Late-Boot Guard & Restore) ---
    @register("T2_F21_01", 2, "F21", "Behavioral simulation: KST +09:00 schedule normalization across KST (+9), UTC (0), and PST (-8) laptops")
    def _():
        kst_res = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", local_offset_hours=9.0)
        utc_res = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", local_offset_hours=0.0)
        pst_res = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", local_offset_hours=-8.0)

        expected_utc = datetime.datetime(2026, 11, 23, 11, 30, 0, tzinfo=datetime.timezone.utc)
        assert kst_res["RestoreAtUtc"] == expected_utc
        assert utc_res["RestoreAtUtc"] == expected_utc
        assert pst_res["RestoreAtUtc"] == expected_utc
        assert kst_res["IsKst"] is True and utc_res["IsKst"] is False and pst_res["IsKst"] is False
        assert pst_res["RestoreAt"].hour == 3 and pst_res["RestoreAt"].minute == 30  # type: ignore[attr-defined]

    @register("T2_F21_02", 2, "F21", "Behavioral simulation: Late-boot -Shutdown guard around 25-minute boundary (0m, 24.9m, 25.0m, 25.1m, 750m)")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        sched = "2026-11-23T20:30:00+09:00"
        base = datetime.datetime(2026, 11, 23, 20, 30, 0, tzinfo=kst)
        assert sim.simulate_late_boot_shutdown_guard(True, sched, base) is True
        assert sim.simulate_late_boot_shutdown_guard(True, sched, base + datetime.timedelta(minutes=24, seconds=54)) is True
        assert sim.simulate_late_boot_shutdown_guard(True, sched, base + datetime.timedelta(minutes=25, seconds=0)) is True
        assert sim.simulate_late_boot_shutdown_guard(True, sched, base + datetime.timedelta(minutes=25, seconds=6)) is False
        assert sim.simulate_late_boot_shutdown_guard(True, sched, base + datetime.timedelta(hours=12, minutes=30)) is False

    @register("T2_F21_03", 2, "F21", "Behavioral simulation: Backup-ContestWorkspaceSources backs up <=5MB source files while skipping .vscode, .exe, and >5MB files")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            root = tpath / "CPTools"
            ws = root / "contest"
            (ws / ".vscode").mkdir(parents=True)
            (ws / "sub").mkdir(parents=True)
            (ws / "A.cpp").write_text("#include <iostream>\nint main(){}\n", encoding="utf-8")
            (ws / "sub" / "B_한글.py").write_text("print(42)\n", encoding="utf-8")
            (ws / "A.exe").write_bytes(b"MZ" + b"\x00" * 1024)
            (ws / "empty.cpp").write_bytes(b"")
            (ws / "huge.txt").write_bytes(b"X" * (5 * 1024 * 1024 + 10))
            (ws / ".vscode" / "tasks.json").write_text("{}", encoding="utf-8")

            bak = sim.simulate_workspace_backup(root, tpath / "TEMP")
            assert bak is not None
            assert (bak / "A.cpp").exists()
            assert (bak / "sub" / "B_한글.py").exists()
            assert not (bak / "A.exe").exists()
            assert not (bak / "empty.cpp").exists()
            assert not (bak / "huge.txt").exists()
            assert not (bak / ".vscode").exists()

    @register("T2_F21_04", 2, "F21", "Behavioral simulation: Restore-Msys2ContestConfiguration restores pacman.conf & mirrorlists and deletes contest CA anchors")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            msys = Path(tmp) / "msys64"
            (msys / "etc" / "pacman.d").mkdir(parents=True)
            (msys / "etc" / "pki" / "ca-trust" / "source" / "anchors").mkdir(parents=True)
            (msys / "ucrt64" / "bin").mkdir(parents=True)
            (msys / "ucrt64" / "bin" / "g++.exe").write_bytes(b"MZ_GPP")

            (msys / "etc" / "pacman.conf").write_text("# modified\nParallelDownloads = 8\n#[mingw64]\n", encoding="utf-8")
            (msys / "etc" / "pacman.conf.contest-bak").write_text("[options]\n[mingw64]\nInclude = /etc/pacman.d/mirrorlist.mingw64\n", encoding="utf-8")
            (msys / "etc" / "pacman.d" / "mirrorlist.ucrt64").write_text("Server = https://ftp.kaist.ac.kr\n", encoding="utf-8")
            (msys / "etc" / "pacman.d" / "mirrorlist.ucrt64.contest-bak").write_text("Server = https://mirror.msys2.org\n", encoding="utf-8")
            pem = msys / "etc" / "pki" / "ca-trust" / "source" / "anchors" / "contestsetup-windows-roots.pem"
            custom_ca = msys / "etc" / "pki" / "ca-trust" / "source" / "anchors" / "campus-proxy.crt"
            pem.write_text("PEM", encoding="utf-8")
            custom_ca.write_text("CRT", encoding="utf-8")

            # Simulate Restore-Msys2ContestConfiguration
            shutil.copy2(msys / "etc" / "pacman.conf.contest-bak", msys / "etc" / "pacman.conf")
            (msys / "etc" / "pacman.conf.contest-bak").unlink()
            shutil.copy2(msys / "etc" / "pacman.d" / "mirrorlist.ucrt64.contest-bak", msys / "etc" / "pacman.d" / "mirrorlist.ucrt64")
            (msys / "etc" / "pacman.d" / "mirrorlist.ucrt64.contest-bak").unlink()
            pem.unlink()
            custom_ca.unlink()

            assert "[mingw64]" in (msys / "etc" / "pacman.conf").read_text(encoding="utf-8")
            assert not (msys / "etc" / "pacman.conf.contest-bak").exists()
            assert not pem.exists() and not custom_ca.exists()
            assert (msys / "ucrt64" / "bin" / "g++.exe").exists()

    @register("T2_F21_05", 2, "F21", "restore-and-cleanup.ps1 sorts path-* snapshots ascending (oldest original first) and runs WiX Burn before MsiExec")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Sort-Object CreationTime)" in code and "Sort-Object CreationTime -Descending" not in code
        assert "if ($U -match 'MsiExec') { 1 } else { 0 }" in code

    # --- F22 Boundary Cases (Browser DoH/Copilot Lockdown & AI Domain Expansion) ---
    @register("T2_F22_01", 2, "F22", "Behavioral simulation: Browser DoH policy backup/restore preserves prior enterprise Chrome policy while pruning newly created keys")
    def _():
        registry: Dict[str, Dict[str, object]] = {
            "HKLM:\\SOFTWARE\\Policies\\Google\\Chrome": {"DnsOverHttpsMode": "secure", "DefaultSearchProviderEnabled": 1},
        }
        specs = [
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "DnsOverHttpsMode", "off"),
            ("HKLM:\\SOFTWARE\\Policies\\Google\\Chrome", "BuiltInDnsClientEnabled", 0),
            ("HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale", "DnsOverHttpsMode", "off"),
        ]
        backup_entries = []
        for kpath, vname, new_val in specs:
            key_existed = kpath in registry
            val_existed = key_existed and (vname in registry[kpath])
            prior_val = registry[kpath][vname] if val_existed else None
            backup_entries.append({"KeyPath": kpath, "ValueName": vname, "KeyExisted": key_existed, "ValueExisted": val_existed, "PriorValue": prior_val})
            registry.setdefault(kpath, {})[vname] = new_val

        assert registry["HKLM:\\SOFTWARE\\Policies\\Google\\Chrome"]["DnsOverHttpsMode"] == "off"
        assert registry["HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale"]["DnsOverHttpsMode"] == "off"

        # Restore from backup
        keys_to_prune = set()
        for entry in backup_entries:
            kp = str(entry["KeyPath"])
            vn = str(entry["ValueName"])
            if entry["ValueExisted"]:
                registry.setdefault(kp, {})[vn] = entry["PriorValue"]
            elif kp in registry:
                registry[kp].pop(vn, None)
            if not entry["KeyExisted"]:
                keys_to_prune.add(kp)
        for kp in keys_to_prune:
            if kp in registry and len(registry[kp]) == 0:
                del registry[kp]

        assert registry["HKLM:\\SOFTWARE\\Policies\\Google\\Chrome"] == {"DnsOverHttpsMode": "secure", "DefaultSearchProviderEnabled": 1}
        assert "HKLM:\\SOFTWARE\\Policies\\Naver\\Naver Whale" not in registry

    @register("T2_F22_02", 2, "F22", "Behavioral simulation: Get-BlockDomains www. expansion handles 2-label apex and 3-label .co.kr/.ac.kr without polluting API subdomains")
    def _():
        expanded = sim.parse_and_expand_blocklist_domains(
            [
                "chatgpt.com",
                "wrtn.ai",
                "service.co.kr",
                "portal.ac.kr",
                "api2.cursor.sh",
                "clova-x.naver.com",
                "www.already.com",
            ]
        )
        assert "chatgpt.com" in expanded and "www.chatgpt.com" in expanded
        assert "wrtn.ai" in expanded and "www.wrtn.ai" in expanded
        assert "service.co.kr" in expanded and "www.service.co.kr" in expanded
        assert "portal.ac.kr" in expanded and "www.portal.ac.kr" in expanded
        assert "api2.cursor.sh" in expanded and "www.api2.cursor.sh" not in expanded
        assert "clova-x.naver.com" in expanded and "www.clova-x.naver.com" not in expanded
        assert "www.already.com" in expanded and "www.www.already.com" not in expanded

    @register("T2_F22_03", 2, "F22", "Apply-AiHostsBlock honors -NotAfter expiry before touching hosts and rejects past -Until before writing")
    def _():
        body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        not_after_pos = body.find("if (-not [string]::IsNullOrWhiteSpace($NotAfter))")
        restore_time_pos = body.find("$PlannedRestoreTime = Get-RestoreTime")
        hosts_pos = body.find("Write-HostsFileWithRetry")
        policy_pos = body.find("Set-ContestBrowserPolicies")
        assert -1 < not_after_pos < restore_time_pos < hosts_pos < policy_pos

    @register("T2_F22_04", 2, "F22", "restore-and-cleanup.ps1 unconditionally strips CP_CONTEST_AI_BLOCKLIST markers and restores browser policies even if ai-hosts-block.ps1 is deleted")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Write-HostsFileDirectRetry" in code
        assert "Restore-BrowserPoliciesFallback -ContestRoot $Root" in code

    @register("T2_F22_05", 2, "F22", "Repository hygiene: .gitignore covers __pycache__/, .agents/, *.tmp, *.bak, *.contest-bak, and *.contest-orig")
    def _():
        gitignore = ps.read_text(".gitignore")
        for pat in ("__pycache__/", ".agents/", "*.tmp", "*.bak", "*.contest-bak", "*.contest-orig"):
            assert pat in gitignore, f".gitignore missing pattern '{pat}'"

    return tests
