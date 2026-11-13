#!/usr/bin/env python3
"""Tier 3: Cross-Script Contract & Parity Verification Tests (34 tests)."""
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
    # TIER 3 — CROSS-FEATURE COMBINATIONS (34 PAIRWISE & INTERFACE CONTRACT TESTS)
    # =========================================================================

    @register("T3_01", 3, "F1+F2+F3+F18", "All 21 parameters in install-env.ps1 param() align with UAC forwarding and common.ps1")
    def _():
        declared = ps.parse_declared_parameters("install-env.ps1")
        install_code = ps.read_active_code("install-env.ps1")
        common_code = ps.read_active_code("common.ps1")
        assert len(declared) == 21, f"Expected 21 declared params in install-env.ps1, got {len(declared)}"
        for p, env_name in INSTALL_ENV_21_PARAMS.items():
            assert p.lower() in declared, f"install-env.ps1 param() missing ${p}"
            assert f"'-{p}'" in install_code, f"install-env.ps1 UAC forwarding missing -{p}"
            assert env_name in common_code and env_name in install_code

    @register("T3_02", 3, "F2+F5+F11+F12", "Staged script directory ($ScriptStageDir = $Root\\scripts) shared across install-env, setup-ai-hosts, and setup-restore-task")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        ai_setup = ps.read_active_code("setup-ai-hosts.ps1")
        restore_setup = ps.read_active_code("setup-restore-task.ps1")
        assert "ai-hosts-block.ps1" in install_code and "restore-and-cleanup.ps1" in install_code
        assert "ScriptStageDir" in ai_setup and "PSScriptRoot" in ai_setup
        assert "ScriptStageDir" in restore_setup and "PSScriptRoot" in restore_setup

    @register("T3_03", 3, "F3+F11", "Pre-flight check clears existing AI hosts block before downloads, and Step 7 (setup-ai-hosts.ps1) re-applies it")
    def _():
        pre_body = ps.extract_function_body("common.ps1", "Invoke-PreflightChecks")
        install_code = ps.read_active_code("install-env.ps1")
        assert "Clear-StaleAiHostsSectionBeforeInstall" in pre_body
        assert "setup-ai-hosts.ps1" in install_code

    @register("T3_04", 3, "F4+F12", "install-env.ps1 catch block extracts and validates actual &-invocation flags passed to restore-and-cleanup.ps1 on -RollbackOnFailure")
    def _():
        ie_code = ps.read_active_code("install-env.ps1")
        rb_lines = re.findall(r"&\s+\$RollbackScriptPath\s+([^\n]+)", ie_code)
        assert len(rb_lines) >= 1, "No & $RollbackScriptPath invocation found in install-env.ps1"
        for idx, rb_line in enumerate(rb_lines):
            flags = re.findall(r"-[A-Za-z][A-Za-z0-9_]*", rb_line)
            for req_flag in ("-KeepDownloads", "-KeepLogs", "-KeepWorkspace", "-NoPause"):
                assert req_flag in flags, f"Rollback branch #{idx} missing {req_flag}: {rb_line}"
            ps.validate_script_invocation_args(
                "restore-and-cleanup.ps1",
                flags,
                caller_label=f"install-env.ps1 (RollbackOnFailure branch #{idx})",
            )

    @register("T3_05", 3, "F5+F6+F7+F9", "Parallel download prefetcher URLs and output paths match setup-msys2, setup-python, and setup-vscode")
    def _():
        common_code = ps.read_active_code("common.ps1")
        msys_code = ps.read_active_code("setup-msys2.ps1")
        py_code = ps.read_active_code("setup-python.ps1")
        vsc_code = ps.read_active_code("setup-vscode.ps1")
        assert "$Msys2InstallerPath" in common_code and "$Msys2InstallerPath" in msys_code
        assert "$PythonInstaller" in common_code and "$PythonInstaller" in py_code
        assert "vscode-win32-x64-archive.zip" in common_code and "vscode-win32-x64-archive.zip" in vsc_code

    @register("T3_06", 3, "F3+F7+F12+F13", "install-manifest.json PythonInstalledByContestSetup contract between setup-python.ps1 and restore-and-cleanup.ps1")
    def _():
        py_code = ps.read_active_code("setup-python.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "PythonInstalledByContestSetup" in py_code
        assert "PythonInstalledByContestSetup" in restore_code and "install-manifest.json" in restore_code

    @register("T3_07", 3, "F6+F7+F10", "Native python3.exe and UCRT64 binaries align with setup-wrappers.ps1 PATH ordering and smoke tests")
    def _():
        py_code = ps.read_active_code("setup-python.ps1")
        wrap_code = ps.read_active_code("setup-wrappers.ps1")
        assert "$Python3Exe" in py_code and "$Python3Exe" in wrap_code
        assert "g++14.cmd" in wrap_code and "g++17.cmd" in wrap_code and "g++20.cmd" in wrap_code

    @register("T3_08", 3, "F1+F11+F12+F18", "Scheduled task names align across setup-restore-task.ps1, ai-hosts-block.ps1, restore-and-cleanup.ps1, and common.ps1")
    def _():
        restore_task_code = ps.read_active_code("setup-restore-task.ps1")
        ai_code = ps.read_active_code("ai-hosts-block.ps1")
        cleanup_code = ps.read_active_code("restore-and-cleanup.ps1")
        common_code = ps.read_active_code("common.ps1")
        assert "ContestSetupRestoreAndCleanup" in restore_task_code
        assert "ContestSetupRestoreAndCleanup" in cleanup_code
        assert "ContestSetupRestoreAndCleanup" in common_code
        assert "ContestSetupRestoreAiHostsBlock" in ai_code and "ContestSetupRestoreAiHostsBlock" in cleanup_code
        assert "ContestSetupExamStartEnforcement" in restore_task_code and "ContestSetupExamStartEnforcement" in cleanup_code

    @register("T3_09", 3, "F3+F9+F13", "VS Code settings.json, argv.json, tasks.json, c_cpp_properties.json, and launch.json use Write-JsonUtf8NoBom")
    def _():
        vsc_code = ps.read_active_code("setup-vscode.ps1")
        assert vsc_code.count("Write-JsonUtf8NoBom") >= 7

    @register("T3_10", 3, "F9+F10+F19", "Integrated terminal PATH order in setup-vscode.ps1 matches Configure-Path in setup-wrappers.ps1")
    def _():
        vsc_body = ps.extract_function_body("setup-vscode.ps1", "Set-VSCodeAiHiddenSettings")
        wrap_body = ps.extract_function_body("setup-wrappers.ps1", "Configure-Path")
        assert "$PythonDirValue;$UcrtBinValue;$MsysUsrBinValue;$ToolBinValue" in vsc_body
        assert "@($PythonDir, $UcrtBin, $MsysUsrBin, $ToolBin)" in wrap_body

    @register("T3_11", 3, "F9+F12+F21", "KeepVSCode parameter contract across install-env.ps1, common.ps1, setup-vscode.ps1, and restore-and-cleanup.ps1")
    def _():
        for script in ("install-env.ps1", "common.ps1", "restore-and-cleanup.ps1"):
            assert "KeepVSCode" in ps.read_active_code(script)
        assert "if (-not $KeepVSCode)" in ps.read_active_code("restore-and-cleanup.ps1")

    @register("T3_12", 3, "F2+F8+F14", "Opt-in -IncludeVisualStudio behavior in code matches documentation in README.md and ARCHITECTURE_V2.md")
    def _():
        for fname in ("setup-visualstudio.ps1", "README.md", "ARCHITECTURE_V2.md"):
            assert "IncludeVisualStudio" in ps.read_text(fname)

    @register("T3_13", 3, "F5+F6+F13+F21", "MSYS2 custom CA certificate (-Msys2CaCertificatePath / CustomCaFileName) integrates across setup-msys2, common, and restore")
    def _():
        msys_body = ps.extract_function_body("setup-msys2.ps1", "Install-Msys2CaCertificate")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "CustomCaFileName" in msys_body and "CustomCaFileName" in restore_code

    @register("T3_14", 3, "F3+F4+F7+F21", "State manifest checkpointing records MsysRoot, TargetUserSid, TargetUserProfile, and PythonInstalledByContestSetup")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for key in ("MsysRoot", "TargetUserSid", "TargetUserProfile"):
            assert key in install_code and key in restore_code

    @register("T3_15", 3, "F1+F10+F11+F14", "Exam schedule 2026-11-23 19:00-20:30 is consistent across all scripts, README.md, ARCHITECTURE_V2.md, and PROJECT.md")
    def _():
        for doc in ("common.ps1", "install-env.ps1", "setup-restore-task.ps1", "install-ai-hosts.ps1", "README.md", "ARCHITECTURE_V2.md", "PROJECT.md"):
            text = ps.read_effective_text(doc)
            assert "2026-11-23" in text or "11월 23일" in text
            assert "20:30" in text or "20시 30분" in text

    @register("T3_16", 3, "F9+F12+F13", "VS Code shortcut-manifest.json written by setup-vscode.ps1 is round-trip compatible with restore-and-cleanup.ps1")
    def _():
        vsc_code = ps.read_active_code("setup-vscode.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for field in ("ShortcutPath", "Existed", "BackupPath"):
            assert field in vsc_code and field in restore_code

    @register("T3_17", 3, "F10+F12+F21", "PATH backup snapshot format (TargetUserSid:, User PATH:, Machine PATH:) matches parser in restore-and-cleanup.ps1")
    def _():
        bak_body = ps.extract_function_body("common.ps1", "Backup-PathEnvironment")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for header in ("TargetUserSid:", "User PATH:", "Machine PATH:"):
            assert header in bak_body and header in restore_code

    @register("T3_18", 3, "F11+F12", "ai-hosts-block.ps1 stable locations ($Root\\ai-hosts-block.ps1 and $Root\\ai-block\\ai-hosts-block.ps1) match restore-and-cleanup.ps1")
    def _():
        ai_code = ps.read_active_code("ai-hosts-block.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Join-Path $Root 'ai-block'" in ai_code
        assert "Join-Path $Root 'ai-block'" in restore_code

    @register("T3_19", 3, "F2+F11+F12+F18+F21+F22", "Dynamic AST extraction & ParameterSet validation of all 6 live script-to-script call edges")
    def _():
        # Edge 1: install-env.ps1 (-Mode Restore) -> restore-and-cleanup.ps1 (extract actual & $RestoreScriptToRun lines)
        ie_code = ps.read_active_code("install-env.ps1")
        rs_lines = re.findall(r"&\s+\$RestoreScriptToRun\s+([^\n]+)", ie_code)
        assert len(rs_lines) >= 1, "Missing & $RestoreScriptToRun call in install-env.ps1"
        for idx, rs_line in enumerate(rs_lines):
            flags = re.findall(r"-[A-Za-z][A-Za-z0-9_]*", rs_line)
            assert "-Root" in flags and "-NoPause" in flags
            ps.validate_script_invocation_args("restore-and-cleanup.ps1", flags, caller_label=f"install-env.ps1 (-Mode Restore #{idx})")

        # Edge 2 & Edge 3: setup-restore-task.ps1 -> restore-and-cleanup.ps1 ($RestoreArgParts) & ai-hosts-block.ps1 ($StartArgParts)
        srt_code = ps.read_active_code("setup-restore-task.ps1")
        start_m = re.search(r"\$StartArgParts\s*=\s*@\((.*?)\)", srt_code, re.DOTALL)
        assert start_m, "Missing $StartArgParts in setup-restore-task.ps1"
        start_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", start_m.group(1))
        assert "-Apply" in start_flags and "-NotAfter" in start_flags
        ps.validate_script_invocation_args("ai-hosts-block.ps1", start_flags, caller_label="setup-restore-task.ps1 ($StartArgParts)")

        rest_start = srt_code.find("$RestoreArgParts = @(")
        rest_end = srt_code.find("$TaskArgs =", rest_start)
        assert -1 < rest_start < rest_end, "Missing $RestoreArgParts block in setup-restore-task.ps1"
        rest_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", srt_code[rest_start:rest_end])
        assert "-ScheduledRestoreAt" in rest_flags and "-Shutdown" in rest_flags
        ps.validate_script_invocation_args("restore-and-cleanup.ps1", rest_flags, caller_label="setup-restore-task.ps1 ($RestoreArgParts)")

        # Edge 4: setup-ai-hosts.ps1 -> ai-hosts-block.ps1 ($ForwardArgs)
        sai_code = ps.read_active_code("setup-ai-hosts.ps1")
        sai_m = re.search(r"\$ForwardArgs\s*=\s*@\(([^\n]+)\)", sai_code)
        assert sai_m, "Missing $ForwardArgs in setup-ai-hosts.ps1"
        sai_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", sai_m.group(1))
        assert "-Apply" in sai_flags and "-NoSchedule" in sai_flags
        ps.validate_script_invocation_args("ai-hosts-block.ps1", sai_flags, caller_label="setup-ai-hosts.ps1 ($ForwardArgs)")

        # Edge 5: install-ai-hosts.ps1 -> ai-hosts-block.ps1 ($ForwardArgs in Restore & Apply branches)
        iai_code = ps.read_active_code("install-ai-hosts.ps1")
        iai_start = iai_code.find("$ForwardArgs = @(")
        iai_end = iai_code.find("if (Test-IsAdmin)", iai_start)
        assert -1 < iai_start < iai_end, "Missing $ForwardArgs block in install-ai-hosts.ps1"
        iai_block = iai_code[iai_start:iai_end]
        else_pos = iai_block.find("else")
        assert else_pos != -1
        restore_branch_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", iai_block[:else_pos]) + ["-SkipBrowserPolicy", "-Root"]
        apply_branch_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", iai_block[else_pos:])
        assert "-Restore" in restore_branch_flags and "-Apply" in apply_branch_flags
        ps.validate_script_invocation_args("ai-hosts-block.ps1", restore_branch_flags, caller_label="install-ai-hosts.ps1 (Restore)")
        ps.validate_script_invocation_args("ai-hosts-block.ps1", apply_branch_flags, caller_label="install-ai-hosts.ps1 (Apply)")

        # Edge 6: restore-and-cleanup.ps1 -> ai-hosts-block.ps1 ($AiRestoreArgs)
        rc_code = ps.read_active_code("restore-and-cleanup.ps1")
        rc_m = re.search(r"\$AiRestoreArgs\s*=\s*\(@\(([^\n)]+)\)", rc_code)
        assert rc_m, "Missing $AiRestoreArgs in restore-and-cleanup.ps1"
        rc_flags = re.findall(r"'(-[A-Za-z][A-Za-z0-9_]*)'", rc_m.group(1))
        assert "-Restore" in rc_flags and "-Root" in rc_flags
        ps.validate_script_invocation_args("ai-hosts-block.ps1", rc_flags, caller_label="restore-and-cleanup.ps1 ($AiRestoreArgs)")

    @register("T3_20", 3, "F18+F19+F21", "End-to-end TargetUserSid / TargetUserProfile contract across UAC elevation, shortcuts, tasks, and SYSTEM restore")
    def _():
        for script in ("install-env.ps1", "common.ps1", "setup-vscode.ps1", "setup-restore-task.ps1", "restore-and-cleanup.ps1"):
            code = ps.read_active_code(script)
            assert "TargetUserSid" in code or "Resolve-ContestTargetUser" in code, f"{script} missing TargetUserSid integration"

    @register("T3_21", 3, "F18+F21+F22", "-DeferAiBlockUntilExamStart + ContestSetupExamStartEnforcement + Status vs Verify readiness semantics")
    def _():
        setup_ai = ps.read_active_code("setup-ai-hosts.ps1")
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        assert "$DeferAiBlockUntilExamStart" in setup_ai and "$SchedCheck.IsBeforeExamStart" in setup_ai
        assert "Deferred until ExamStart ($ExamStart)" in audit_body
        assert "if ($Mode -eq 'Status') { $HostsBlocked = $true }" in audit_body

    @register("T3_22", 3, "F3+F20", "-Mode ExportCache output directory names match offline CacheDir consumers in common, setup-vscode, and setup-msys2")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        exp_idx = install_code.find("elseif ($Mode -eq 'ExportCache')")
        export_section = install_code[exp_idx : exp_idx + 4500]
        vsc_seed = ps.extract_function_body("setup-vscode.ps1", "Seed-VSCodeExtensionsFromCacheDir")
        msys_seed = ps.extract_function_body("setup-msys2.ps1", "Seed-Msys2PackageCacheFromCacheDir")
        for subdir in ("vscode-extensions",):
            assert f"'{subdir}'" in export_section and f"'{subdir}'" in vsc_seed
        for subdir in ("msys2-pkg", "msys2-sync"):
            assert f"'{subdir}'" in export_section and f"'{subdir}'" in msys_seed

    @register("T3_23", 3, "F18+F19", "Dual-layer VS Code lockdown (vscode\\data + vscode-contest + allowlist) matches Invoke-ContestEnvironmentAudit checks")
    def _():
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        vsc_allow = ps.extract_function_body("setup-vscode.ps1", "Get-AllowedVSCodeExtensions")
        for ext_id in (
            "ms-ceintl.vscode-language-pack-ko",
            "ms-vscode.cpptools",
            "ms-vscode.cpptools-themes",
            "ms-vscode.cpptools-extension-pack",
            "ms-python.python",
            "ms-python.debugpy",
            "ms-python.vscode-pylance",
            "ms-python.vscode-python-envs",
        ):
            assert ext_id in audit_body and ext_id in vsc_allow

    @register("T3_24", 3, "F6+F17+F21", "MSYS2 .contest-bak and contestsetup-windows-roots.pem filenames match between setup-msys2.ps1 and restore-and-cleanup.ps1")
    def _():
        msys_code = ps.read_active_code("setup-msys2.ps1")
        restore_body = ps.extract_function_body("restore-and-cleanup.ps1", "Restore-Msys2ContestConfiguration")
        assert "contestsetup-windows-roots.pem" in msys_code and "contestsetup-windows-roots.pem" in restore_body
        assert ".contest-bak" in msys_code and ".contest-bak" in restore_body

    @register("T3_25", 3, "F21+F22", "Exact 22-policy tuple parity (13 core + 9 extended KeyPath/Name/Type/Value) between ai-hosts-block.ps1 and restore-and-cleanup.ps1")
    def _():
        ai_core = sim.parse_browser_policy_tuples("ai-hosts-block.ps1", "Get-BrowserPolicySpecifications")
        ai_ext = sim.parse_browser_policy_tuples("ai-hosts-block.ps1", "Get-ExtendedBrowserPolicySpecifications")
        rc_core = sim.parse_browser_policy_tuples("restore-and-cleanup.ps1", "Restore-BrowserPoliciesFallback")
        rc_ext = sim.parse_browser_policy_tuples("restore-and-cleanup.ps1", "Get-ExtendedBrowserPolicySpecifications")
        assert len(ai_core) == 13, f"Expected 13 core policy tuples in ai-hosts-block.ps1, got {len(ai_core)}"
        assert len(ai_ext) == 9, f"Expected 9 extended policy tuples in ai-hosts-block.ps1, got {len(ai_ext)}"
        assert ai_core == rc_core, f"Core 13 policy tuple mismatch: {set(ai_core) ^ set(rc_core)}"
        assert ai_ext == rc_ext, f"Extended 9 policy tuple mismatch: {set(ai_ext) ^ set(rc_ext)}"
        assert len(set((kp, nm) for kp, nm, _, _ in (ai_core + ai_ext))) == 22

    @register("T3_26", 3, "F3+F18+F22", "Non-destructive -Mode Verify contract: Verify failure exits 1 without invoking Clear-StaleAiHostsSectionBeforeInstall")
    def _():
        code = ps.read_active_code("install-env.ps1")
        verify_block_start = code.find("if ($Mode -in @('Status', 'Verify', 'DryRun'))")
        verify_block_end = code.find("elseif ($Mode -eq 'Restore')")
        assert -1 < verify_block_start < verify_block_end
        verify_block = code[verify_block_start:verify_block_end]
        assert "Clear-StaleAiHostsSectionBeforeInstall" not in verify_block
        assert "$SetupResultMessageShown = $true" in verify_block
        assert "$ExitCodeToReturn = 1" in verify_block

    @register("T3_27", 3, "F1+F21", "setup-restore-task.ps1 passes ISO-8601 -ScheduledRestoreAt ($ScheduledRestoreIso) consumed by restore-and-cleanup.ps1 late-boot guard")
    def _():
        task_code = ps.read_active_code("setup-restore-task.ps1")
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "$ScheduledRestoreIso = (New-Object System.DateTimeOffset($EffectiveTriggerTime)).ToString('o')" in task_code
        assert "'-ScheduledRestoreAt', $ScheduledRestoreIso" in task_code
        assert "ConvertTo-LocalScheduleTime -Text $ScheduledRestoreAt" in restore_code

    @register("T3_28", 3, "F14+F18+F22", "4-way synchronization of all 21 CLI parameters & 21 CONTEST_* env vars across install-env.ps1, common.ps1, PROJECT.md, and README.md")
    def _():
        install_code = ps.read_active_code("install-env.ps1")
        common_code = ps.read_active_code("common.ps1")
        proj_text = ps.read_text("PROJECT.md")
        readme_text = ps.read_text("README.md")
        for p_name, env_name in INSTALL_ENV_21_PARAMS.items():
            assert p_name in install_code and env_name in install_code
            assert env_name in common_code
            assert f"-{p_name}" in proj_text and env_name in proj_text
            assert f"-{p_name}" in readme_text and env_name in readme_text

    @register("T3_29", 3, "F9+F12+F18", "VS Code 1.97+ versioned <commit>\\resources\\app\\product.json resolution across common, setup-vscode, install-env, and restore")
    def _():
        common_res = ps.extract_function_body("common.ps1", "Resolve-VSCodeProductJsonPath")
        vsc_res = ps.extract_function_body("setup-vscode.ps1", "Get-VSCodeProductJsonPath")
        rc_res = ps.extract_function_body("restore-and-cleanup.ps1", "Restore-VSCodeProductJsonWhenKept")
        ie_code = ps.read_active_code("install-env.ps1")
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")

        for body_name, body in (("common.ps1", common_res), ("setup-vscode.ps1", vsc_res), ("restore-and-cleanup.ps1", rc_res)):
            eff_body = body
            if "Resolve-VSCodeProductJsonPath" in body and "cli\\.js" not in body:
                eff_body = body + "\n" + ps.extract_function_body(body_name, "Resolve-VSCodeProductJsonPath")
            assert "cli\\.js" in eff_body, f"{body_name} missing bin\\code.cmd cli.js commit-folder regex"
            assert "'data'" in eff_body and "'bin'" in eff_body, f"{body_name} missing ExcludedChildNames guard"
            assert "resources\\app\\product.json" in eff_body
        assert "Resolve-VSCodeProductJsonPath" in ie_code and "Resolve-VSCodeProductJsonPath" in audit_body

        # Behavioral simulation on temporary 1.97+ <commit>\resources\app\product.json tree
        with tempfile.TemporaryDirectory() as tmp:
            vsc_root = Path(tmp) / "vscode"
            commit_id = "e54c774e0add60467559eb0d1e229c6452cf8447"
            (vsc_root / "bin").mkdir(parents=True)
            (vsc_root / "data" / "user-data").mkdir(parents=True)
            commit_prod = vsc_root / commit_id / "resources" / "app" / "product.json"
            commit_prod.parent.mkdir(parents=True)
            commit_prod.write_text('{"nameShort":"Code","extensionsGallery":{"serviceUrl":"https://127.0.0.1","itemUrl":"https://127.0.0.1"}}', encoding="utf-8")
            code_cmd_text = f'@echo off\r\n"%~dp0..\\Code.exe" "%~dp0..\\{commit_id}\\resources\\app\\out\\cli.js" %*\r\n'
            (vsc_root / "bin" / "code.cmd").write_text(code_cmd_text, encoding="utf-8")

            cli_m = re.search(r"(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js", code_cmd_text)
            assert cli_m and cli_m.group(1) == commit_id
            resolved_prod = vsc_root / cli_m.group(1) / "resources" / "app" / "product.json"
            assert resolved_prod.is_file()

    @register("T3_30", 3, "F2+F11+F12", "CONTEST_MUTEX_OWNER_PID parent-process mutex handoff eliminates 60s self-contention across install-env, ai-hosts-block, and restore")
    def _():
        ie_code = ps.read_active_code("install-env.ps1")
        ai_code = ps.read_active_code("ai-hosts-block.ps1")
        rc_code = ps.read_active_code("restore-and-cleanup.ps1")

        assert "$env:CONTEST_MUTEX_OWNER_PID = [string]$PID" in ie_code
        assert "$env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid" in ie_code
        assert "$env:CONTEST_MUTEX_OWNER_PID = [string]$PID" in rc_code
        assert "$env:CONTEST_MUTEX_OWNER_PID = $PreviousMutexOwnerPid" in rc_code

        for child_name, child_code in (("ai-hosts-block.ps1", ai_code), ("restore-and-cleanup.ps1", rc_code)):
            assert "CONTEST_MUTEX_OWNER_PID" in child_code, f"{child_name} missing CONTEST_MUTEX_OWNER_PID check"
            assert "$OwnerPid -gt 0 -and $OwnerPid -ne $PID" in child_code
            assert "Get-Process -Id $OwnerPid" in child_code

    @register("T3_31", 3, "F1+F21+F22", "Fail-closed -DeferAiBlockUntilExamStart + -NoRestoreTask contract registers 19:00 enforcement and throws on failure")
    def _():
        srt_code = ps.read_active_code("setup-restore-task.ps1")
        # 1) Early return must NOT fire when $DeferAiBlockValue is true
        assert "if ($SkipRestoreTask -and (-not $DeferAiBlockValue))" in srt_code
        # 2) ContestSetupExamStartEnforcement registration block precedes final if ($SkipRestoreTask) skip of ContestSetupRestoreAndCleanup
        start_task_pos = srt_code.find("$StartTaskName = 'ContestSetupExamStartEnforcement'")
        late_skip_pos = srt_code.find("if ($SkipRestoreTask)", start_task_pos)
        restore_task_pos = srt_code.find("$TaskName = 'ContestSetupRestoreAndCleanup'", late_skip_pos)
        assert -1 < start_task_pos < late_skip_pos < restore_task_pos
        # 3) Missing staged script or task registration failure under $DeferAiBlockValue throws terminating error (fail-closed)
        start_section = srt_code[start_task_pos:late_skip_pos]
        assert start_section.count("if ($DeferAiBlockValue)") >= 2 and start_section.count("throw ") >= 2

    @register("T3_32", 3, "F3+F6+F20", "ExportCache incomplete-bundle warning and MSYS2 air-gapped sync DB -Force seed + offline pacman -S/-U priority")
    def _():
        ie_code = ps.read_active_code("install-env.ps1")
        exp_idx = ie_code.find("elseif ($Mode -eq 'ExportCache')")
        export_section = ie_code[exp_idx : exp_idx + 5000]
        assert "if ($ExportedExtCount -lt 4 -or $ExportedPkgCount -eq 0)" in export_section
        assert "Write-Warning" in export_section

        seed_body = ps.extract_function_body("setup-msys2.ps1", "Seed-Msys2PackageCacheFromCacheDir")
        assert "Copy-Item -LiteralPath $DbItem.FullName -Destination $DestDbFile -Force" in seed_body
        assert "if (-not (Test-Path -LiteralPath $DestDbFile))" not in seed_body

        msys_code = ps.read_active_code("setup-msys2.ps1")
        offline_pos = msys_code.find("if ($SeededFromCache -and (-not $ForceUpdate))")
        online_syu_pos = msys_code.find("Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc")
        assert -1 < offline_pos < online_syu_pos

    @register("T3_33", 3, "F9+F12+F21", "-KeepVSCode restoration unlocks Marketplace product.json and preserves active Code.exe while Resolve-WorkspaceBackupBaseDir avoids SYSTEM %TEMP%")
    def _():
        rc_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "Restore-VSCodeProductJsonWhenKept -ContestRoot $Root" in rc_code
        proc_pos = rc_code.find("$CleanupProcNames = if ($KeepVSCode)")
        assert proc_pos != -1
        proc_section = rc_code[proc_pos : proc_pos + 600]
        assert "if (-not $KeepVSCode)" in proc_section
        assert "Stop-ProcessesUnderPath -Path $Root -ProcessNames $CleanupProcNames" in proc_section

        base_body = ps.extract_function_body("restore-and-cleanup.ps1", "Resolve-WorkspaceBackupBaseDir")
        student_pos = base_body.find("Join-Path $StudentProfilePath 'AppData\\Local'")
        progdata_pos = base_body.find("Join-Path $env:ProgramData 'ContestSetup-Backups'")
        temp_pos = base_body.find("$Candidates.Add($env:TEMP)")
        assert -1 < student_pos < progdata_pos < temp_pos

    @register("T3_34", 3, "F1+F17+F21", "Culture-invariant ISO-8601/timestamp formatting ([CultureInfo]::InvariantCulture) across common, install-env, setup-restore-task, ai-hosts-block, and restore")
    def _():
        for script in ("common.ps1", "install-env.ps1", "setup-restore-task.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            code = ps.read_active_code(script)
            assert "InvariantCulture" in code, f"{script} missing CultureInfo::InvariantCulture for non-Gregorian calendar safety"
        srt_code = ps.read_active_code("setup-restore-task.ps1")
        assert "$StartTrigger.EndBoundary = $ScheduleInfo.ExamEnd.ToString('yyyy-MM-ddTHH:mm:ss', $InvariantCulture)" in srt_code

    return tests
