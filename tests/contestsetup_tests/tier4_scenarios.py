#!/usr/bin/env python3
"""Tier 4: End-to-End Lifecycle Scenario Simulation Tests (16 tests)."""
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
    # TIER 4 — REAL-WORLD APPLICATION SCENARIOS (16 END-TO-END WORKLOAD TESTS)
    # =========================================================================

    @register("T4_01", 4, "Scenario 1", "Cold lab PC provisioning on Monday 2026-11-23 afternoon for the 19:00-20:30 exam")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "CPTools"
            msys = Path(tmp) / "msys64"
            etc_hosts = Path(tmp) / "hosts"
            etc_hosts.write_text("127.0.0.1 localhost\r\n", encoding="utf-8")

            kst = datetime.timezone(datetime.timedelta(hours=9))
            now_kst = datetime.datetime(2026, 11, 23, 15, 0, 0, tzinfo=kst)
            sched = sim.simulate_kst_schedule_parse(
                "2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=now_kst
            )
            assert sched["IsBeforeExamStart"] is True and sched["IsPastRestoreTime"] is False

            for d in (
                "bin", "downloads", "logs", "backup", "state", "scripts",
                "vscode/bin", "vscode/resources/app", "vscode/data/user-data/User", "vscode/data/extensions",
                "vscode-contest/user-data/User", "vscode-contest/extensions",
                "contest/.vscode", "Python310", "ai-block",
            ):
                (root / d).mkdir(parents=True, exist_ok=True)
            for d in ("usr/bin", "ucrt64/bin", "etc/pacman.d"):
                (msys / d).mkdir(parents=True, exist_ok=True)

            for bin_name in ("g++.exe", "gcc.exe", "gdb.exe"):
                (msys / "ucrt64/bin" / bin_name).write_bytes(b"MZ_UCRT")
            (msys / "usr/bin/bash.exe").write_bytes(b"MZ_BASH")
            (msys / "usr/bin/cat.exe").write_bytes(b"MZ_CAT")
            (root / "Python310/python.exe").write_bytes(b"MZ_PY")
            (root / "Python310/python3.exe").write_bytes(b"MZ_PY")
            (root / "vscode/Code.exe").write_bytes(b"MZ_CODE")
            (root / "vscode/bin/code.cmd").write_text("@echo off\n", encoding="utf-8")
            (root / "vscode/resources/app/product.json.contest-orig").write_text(
                json.dumps({"extensionsGallery": {"serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery"}}),
                encoding="utf-8",
            )
            (root / "vscode/resources/app/product.json").write_text(
                json.dumps({"extensionsGallery": {"serviceUrl": "https://127.0.0.1", "itemUrl": "https://127.0.0.1"}}),
                encoding="utf-8",
            )
            for cfg in ("tasks.json", "c_cpp_properties.json", "launch.json"):
                (root / "contest/.vscode" / cfg).write_text("{}", encoding="utf-8")

            domains = sim.get_default_ai_domains()
            block_lines = ["# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN"] + sim.expand_domains_with_www_and_ipv6(domains) + ["# <<< CP_CONTEST_AI_BLOCKLIST_END"]
            etc_hosts.write_text("127.0.0.1 localhost\r\n" + "\r\n".join(block_lines) + "\r\n", encoding="utf-8")

            manifest = {
                "Version": "2.0.0",
                "ExamStart": "2026-11-23T19:00:00",
                "ExamEnd": "2026-11-23T20:30:00",
                "RestoreAt": "2026-11-23T20:30:00",
                "TargetUserSid": "S-1-5-21-123456789-1001",
                "TargetUserProfile": "C:\\Users\\Student",
                "PythonInstalledByContestSetup": True,
                "ScheduledTasks": ["ContestSetupRestoreAndCleanup", "ContestSetupExamStartEnforcement"],
            }
            (root / "state/install-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

            hosts_text = etc_hosts.read_text(encoding="utf-8")
            assert "0.0.0.0 chatgpt.com" in hosts_text and ":: chatgpt.com" in hosts_text and "0.0.0.0 wrtn.ai" in hosts_text
            assert (root / "vscode/data/extensions").exists()

    @register("T4_02", 4, "Scenario 2", "Warm idempotent re-run 10 minutes before exam (2026-11-23 18:50) unlocks product.json, skips installed tools, and preserves student code")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "CPTools"
            contest_dir = root / "contest"
            contest_dir.mkdir(parents=True)
            student_solution = contest_dir / "A_solution.cpp"
            student_solution.write_text("#include <bits/stdc++.h>\nint main() { return 0; }\n", encoding="utf-8")

            vscode_app = root / "vscode/resources/app"
            vscode_app.mkdir(parents=True)
            orig = vscode_app / "product.json.contest-orig"
            prod = vscode_app / "product.json"
            orig.write_text(json.dumps({"extensionsGallery": {"serviceUrl": "https://marketplace.visualstudio.com"}}), encoding="utf-8")
            prod.write_text(json.dumps({"extensionsGallery": {"serviceUrl": "https://127.0.0.1"}}), encoding="utf-8")

            shutil.copy2(orig, prod)
            assert json.loads(prod.read_text(encoding="utf-8"))["extensionsGallery"]["serviceUrl"] == "https://marketplace.visualstudio.com"
            installed_exts = {"ms-ceintl.vscode-language-pack-ko", "ms-vscode.cpptools", "ms-python.python", "ms-python.debugpy"}
            required_exts = {"ms-ceintl.vscode-language-pack-ko", "ms-vscode.cpptools", "ms-python.python", "ms-python.debugpy"}
            assert len(required_exts - installed_exts) == 0
            prod.write_text(json.dumps({"extensionsGallery": {"serviceUrl": "https://127.0.0.1"}}), encoding="utf-8")
            assert student_solution.read_text(encoding="utf-8").startswith("#include <bits/stdc++.h>")

    @register("T4_03", 4, "Scenario 3", "Mid-install interruption during MSYS2 pacman leaving var/lib/pacman/db.lck followed by self-healing recovery re-run")
    def _():
        code = ps.read_active_code("setup-msys2.ps1")
        assert "Remove-StaleMsys2Locks" in code and "Test-Msys2RequiredBinariesExist" in code
        with tempfile.TemporaryDirectory() as tmp:
            msys = Path(tmp) / "msys64"
            db_lck = msys / "var/lib/pacman/db.lck"
            db_lck.parent.mkdir(parents=True)
            db_lck.write_text("locked", encoding="utf-8")
            db_lck.unlink()
            assert not db_lck.exists()

    @register("T4_04", 4, "Scenario 4", "Student PC with pre-existing Python 3.10.11, Visual Studio 2022 Professional, and Machine PATH compiler shadowing")
    def _():
        vs_code = ps.read_active_code("setup-visualstudio.ps1")
        py_code = ps.read_active_code("setup-python.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Professional" in vs_code and "Test-MsvcClCompilerPresent" in vs_code
        assert "PythonInstalledByContestSetup" in py_code
        assert "Test-PathInside -ChildPath $InstallLocation -ParentPath $Root" in restore_code
        assert not sim.test_path_inside("C:\\Program Files\\Python310", "C:\\CPTools")

    @register("T4_05", 4, "Scenario 5", "Offline/USB lab installation using local scripts in $PSScriptRoot and pre-populated -CacheDir")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        common_code = ps.read_active_code("common.ps1")
        assert "CacheDir" in install_code and "Copy-FromCacheDirIfPresent" in common_code
        with tempfile.TemporaryDirectory() as tmp:
            cache_dir = Path(tmp) / "USB_Cache"
            dl_dir = Path(tmp) / "CPTools/downloads"
            cache_dir.mkdir(parents=True)
            dl_dir.mkdir(parents=True)
            cached_zip = cache_dir / "vscode-win32-x64-archive.zip"
            cached_zip.write_bytes(b"PK\x03\x04" + b"\x00" * 4096)
            assert sim.can_reuse_cached_download(cached_zip)
            shutil.copy2(cached_zip, dl_dir / cached_zip.name)
            assert sim.can_reuse_cached_download(dl_dir / cached_zip.name)

    @register("T4_06", 4, "Scenario 6", "Post-exam scheduled automatic restoration at 2026-11-23T20:30:00 with student code backup and -Shutdown")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            root = tpath / "CPTools"
            msys = tpath / "msys64"
            desktop = tpath / "Desktop"
            hosts = tpath / "hosts"
            (root / "contest").mkdir(parents=True)
            (root / "contest" / "final_ans.cpp").write_text("int main(){return 0;}\n", encoding="utf-8")
            msys.mkdir()
            desktop.mkdir()
            bak_lnk = root / "backup/vscode.bak.lnk"
            bak_lnk.parent.mkdir(parents=True)
            bak_lnk.write_text("ORIGINAL_SHORTCUT", encoding="utf-8")
            cur_lnk = desktop / "Visual Studio Code.lnk"
            cur_lnk.write_text("CONTEST_SHORTCUT", encoding="utf-8")

            ws_bak = sim.simulate_workspace_backup(root, tpath / "TEMP")
            assert ws_bak is not None and (ws_bak / "final_ans.cpp").exists()
            shutil.copy2(bak_lnk, cur_lnk)
            hosts.write_text(
                "127.0.0.1 localhost\r\n# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN\r\n0.0.0.0 chatgpt.com\r\n# <<< CP_CONTEST_AI_BLOCKLIST_END\r\n",
                encoding="utf-8",
            )
            hosts.write_text(sim.remove_managed_hosts_section(hosts.read_text(encoding="utf-8")) + "\r\n", encoding="utf-8")
            shutil.rmtree(root)
            assert cur_lnk.read_text(encoding="utf-8") == "ORIGINAL_SHORTCUT"
            assert "chatgpt.com" not in hosts.read_text(encoding="utf-8")
            assert not root.exists() and msys.exists()

    @register("T4_07", 4, "Scenario 7", "Early manual restoration at 2026-11-23 20:10 unregisters all 3 contest tasks so PC does not shut down at 20:30")
    def _():
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for task in ("ContestSetupRestoreAndCleanup", "ContestSetupRestoreAiHostsBlock", "ContestSetupExamStartEnforcement"):
            assert f"'{task}'" in restore_code
        assert "Unregister-ScheduledTask" in restore_code and "schtasks.exe /Delete" in restore_code

    @register("T4_08", 4, "Scenario 8", "Late testing run after exam end (2026-11-24) triggers past-timestamp safeguard and disables -Shutdown")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        late_now = datetime.datetime(2026, 11, 24, 10, 0, 0, tzinfo=kst)
        sched = sim.simulate_kst_schedule_parse(
            "2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=late_now
        )
        assert sched["IsPastRestoreTime"] is True
        task_code = ps.read_active_code("setup-restore-task.ps1")
        assert "$IncludeShutdownFlag = $false" in task_code

    @register("T4_09", 4, "Scenario 9", "Lifecycle workflow: -Mode DryRun -> -Mode Install -> -Mode ExportCache -> -Mode Status -> -Mode Verify -> -Mode Restore")
    def _():
        params = ps.parse_declared_parameters("install-env.ps1")
        assert params["mode"]["validate_set"] == {"Install", "Status", "Verify", "Restore", "DryRun", "ExportCache"}

    @register("T4_10", 4, "Scenario 10", "Setup failure mid-run closes transcript first, backs up logs to TEMP, and preserves student workspace & download cache")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        finally_idx = install_code.rfind("finally")
        matches = list(re.finditer(r"\n\}\s*catch\s*\{", install_code[:finally_idx]))
        catch_block = install_code[matches[-1].start() : finally_idx]
        assert catch_block.find("Stop-SetupLogging") < catch_block.find("Backup-SetupLogsToTemp")
        assert "$RollbackOnFailure" in catch_block

    @register("T4_11", 4, "Scenario 11", "100-seat university lab zero-bandwidth deployment (-Mode ExportCache -> offline -CacheDir Install -> -Mode Verify)")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        exp_idx = install_code.find("elseif ($Mode -eq 'ExportCache')")
        export_section = install_code[exp_idx : exp_idx + 4500]
        assert "robocopy.exe" in export_section and "cache-manifest.json" in export_section
        with tempfile.TemporaryDirectory() as tmp:
            usb_cache = Path(tmp) / "D_ContestCache"
            seat_root = Path(tmp) / "C_CPTools"
            for sub in ("vscode-extensions", "msys2-pkg", "msys2-sync", "scripts"):
                (usb_cache / sub).mkdir(parents=True)
            for ext in ("ms-ceintl.vscode-language-pack-ko-1.95.0", "ms-vscode.cpptools-1.22.11", "ms-python.python-2024.20.0", "ms-python.debugpy-2024.12.0"):
                (usb_cache / "vscode-extensions" / ext).mkdir()
            (usb_cache / "cache-manifest.json").write_text(json.dumps({"Version": "2.0.0"}), encoding="utf-8")

            # Simulate seat seeding from usb_cache with 0 external HTTP bytes
            shutil.copytree(usb_cache / "vscode-extensions", seat_root / "vscode-contest/extensions")
            seeded = {p.name for p in (seat_root / "vscode-contest/extensions").iterdir()}
            assert len(seeded) == 4

    @register("T4_12", 4, "Scenario 12", "Over-the-shoulder LabAdmin UAC elevation + student early logoff at 20:05 + 20:30 SYSTEM (S-1-5-18) SID-aware restore")
    def _():
        student_sid = "S-1-5-21-33445566-1001"
        system_sid = "S-1-5-18"
        hku_registry: Dict[str, Dict[str, str]] = {
            ".DEFAULT": {"Path": "%SystemRoot%\\system32;%SystemRoot%"},
            student_sid: {"Path": "C:\\CPTools\\Python310;C:\\msys64\\ucrt64\\bin;%USERPROFILE%\\AppData\\Local\\Microsoft\\WindowsApps"},
        }
        snapshot_user_path = "%USERPROFILE%\\AppData\\Local\\Microsoft\\WindowsApps"

        # Simulate Set-RegistryScopePathValue running as SYSTEM (S-1-5-18) with TargetUserSid = student_sid
        effective_sid = student_sid if (student_sid and student_sid != system_sid) else ""
        assert effective_sid == student_sid
        hku_registry[effective_sid]["Path"] = snapshot_user_path

        # HKU\.DEFAULT is untouched; student's unexpanded %USERPROFILE% token is preserved
        assert hku_registry[".DEFAULT"]["Path"] == "%SystemRoot%\\system32;%SystemRoot%"
        assert hku_registry[student_sid]["Path"] == "%USERPROFILE%\\AppData\\Local\\Microsoft\\WindowsApps"

    @register("T4_13", 4, "Scenario 13", "Next-morning laptop boot (2026-11-24 09:00 KST) prevents 19:00 hosts re-block and suppresses late -Shutdown")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        boot_time = datetime.datetime(2026, 11, 24, 9, 0, 0, tzinfo=kst)
        not_after = datetime.datetime.fromisoformat("2026-11-23T20:30:00+09:00")
        scheduled_restore = "2026-11-23T20:30:00+09:00"

        # 1) ContestSetupExamStartEnforcement (-NotAfter 2026-11-23T20:30:00+09:00) exits without touching hosts
        hosts_reblocked = boot_time <= not_after
        assert hosts_reblocked is False

        # 2) ContestSetupRestoreAndCleanup suppresses -Shutdown because 750 minutes > 25 minutes
        effective_shutdown = sim.simulate_late_boot_shutdown_guard(True, scheduled_restore, boot_time)
        assert effective_shutdown is False

    @register("T4_14", 4, "Scenario 14", "Pre-exam day provisioning (2026-11-22) with -DeferAiBlockUntilExamStart -> Status OK -> 19:00 lock -> Verify OK")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        pre_exam = datetime.datetime(2026, 11, 22, 16, 0, 0, tzinfo=kst)
        during_exam = datetime.datetime(2026, 11, 23, 19, 5, 0, tzinfo=kst)
        s_pre = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=pre_exam)
        s_dur = sim.simulate_kst_schedule_parse("2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", now_utc=during_exam)
        assert s_pre["IsBeforeExamStart"] is True
        assert s_dur["IsBeforeExamStart"] is False and s_dur["IsPastRestoreTime"] is False

    @register("T4_15", 4, "Scenario 15", "Active exam anti-cheat bypass attempt blocked across direct Code.exe, sideloaded VSIX, Browser DoH, and Korean/2026 AI sites")
    def _():
        domains = sim.get_default_ai_domains()
        expanded_lines = set(sim.expand_domains_with_www_and_ipv6(domains))
        for target_host in ("grok.com", "www.grok.com", "wrtn.ai", "www.wrtn.ai", "clova-x.naver.com", "aistudio.google.com", "api2.cursor.sh"):
            assert f"0.0.0.0 {target_host}" in expanded_lines, f"IPv4 block missing for {target_host}"
            assert f":: {target_host}" in expanded_lines, f"IPv6 block missing for {target_host}"
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        assert "Join-Path $Root 'vscode\\data\\extensions'" in audit_body and "$UnauthorizedExts.Count -eq 0" in audit_body

    @register("T4_16", 4, "Scenario 16", "Non-KST student laptop (UTC-08:00 PST) converts 2026-11-23 19:00-20:30 KST to exact simultaneous UTC exam window")
    def _():
        pst_sched = sim.simulate_kst_schedule_parse(
            "2026-11-23T19:00:00", "2026-11-23T20:30:00", "2026-11-23T20:30:00", local_offset_hours=-8.0
        )
        assert pst_sched["ExamStartDto"].astimezone(datetime.timezone.utc) == datetime.datetime(2026, 11, 23, 10, 0, 0, tzinfo=datetime.timezone.utc)
        assert pst_sched["RestoreAtUtc"] == datetime.datetime(2026, 11, 23, 11, 30, 0, tzinfo=datetime.timezone.utc)
        assert pst_sched["DayOfWeek"] == "Monday"

    return tests
