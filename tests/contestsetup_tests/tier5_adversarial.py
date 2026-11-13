#!/usr/bin/env python3
"""Tier 5: Adversarial Security, Concurrency & Live PowerShell AST Tests (T5_01-T5_34)."""
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
    # TIER 5 — WHITE-BOX ADVERSARIAL & MUTATION HARDENING (20 TESTS: F16 + F23)
    # =========================================================================

    @register("T5_01", 5, "F16+F23", "Adversarial Win32 CommandLineToArgvW round-trip fuzzing of Quote-ProcessArgument across 30+ hostile inputs")
    def _():
        hostile_inputs = [
            "",
            " ",
            "   \t  ",
            "C:\\CPTools\\",
            "C:\\CPTools\\\\",
            "C:\\Users\\홍길동 (학부 1반)\\CPTools\\",
            'C:\\Lab "Room A"\\Sub\\',
            '\\"leading-and-trailing\\"',
            'a\\\\\\"b',
            'quote"in"middle',
            "path with (parentheses) & %TEMP% !bang! $dollar",
            "\\\\server\\share\\Contest Cache\\",
            "--override",
            "--add Microsoft.VisualStudio.Workload.NativeDesktop --quiet --wait --norestart",
            'nested \\"escaped\\" and trailing \\\\\\',
            "single'quote'and spaces\\",
            "line1_no_newline\twith_tab\\",
            "100%Pure&Evil|Meta<Chars>^Caret",
        ]
        # Test individual round-trip AND multi-argument vector round-trip
        for item in hostile_inputs:
            quoted = sim.quote_process_argument(item)
            parsed = sim.win32_command_line_to_argv(f"powershell.exe {quoted}")
            assert parsed == ["powershell.exe", item], f"Round-trip mismatch for {item!r}: got {parsed!r} from {quoted!r}"

        combined_cmd = " ".join(sim.quote_process_argument(x) for x in hostile_inputs)
        assert sim.win32_command_line_to_argv(combined_cmd) == hostile_inputs

    @register("T5_02", 5, "F16+F23", "Adversarial JSONC comment/escape/BOM/trailing-comma torture matrix on ConvertFrom-JsonSafe")
    def _():
        cases: List[Tuple[str, object]] = [
            ("", None),
            ("\ufeff   // comment only\n/* block only */  ", None),
            (
                '\ufeff{\n'
                '  "url": "https://127.0.0.1:8443/path?a=1&b=2#frag",\n'
                '  "winPath": "C:\\\\CPTools\\\\", // comment right after escaped trailing backslash!\n'
                '  "fakeBlock": "/* not a block */ // not a line",\n'
                '  "emptyComment": /**/ 42,\n'
                '  "nested": [{"x": 1,}, {"y": [true, false, ],},],\n'
                '}',
                {
                    "url": "https://127.0.0.1:8443/path?a=1&b=2#frag",
                    "winPath": "C:\\CPTools\\",
                    "fakeBlock": "/* not a block */ // not a line",
                    "emptyComment": 42,
                    "nested": [{"x": 1}, {"y": [True, False]}],
                },
            ),
        ]
        for raw_jsonc, expected in cases:
            actual = sim.simulate_jsonc_strip_and_parse(raw_jsonc)
            assert actual == expected, f"JSONC parse mismatch: got {actual!r}, expected {expected!r}"

    @register("T5_03", 5, "F16+F23", "Adversarial PS 5.1 array unwrapping & pipeline ban audit across all .ps1 files")
    def _():
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            assert not re.search(r"\|\s*ConvertTo-Json\b", code, re.IGNORECASE), (
                f"{fname} pipes into ConvertTo-Json (unwraps 1-element arrays in PS 5.1)"
            )
            assert not re.search(r"\|\s*ConvertFrom-Json\b", code, re.IGNORECASE), (
                f"{fname} pipes into ConvertFrom-Json (creates Object[][] on PS 5.1)"
            )
            # Only ConvertFrom-JsonSafe definitions may call raw ConvertFrom-Json
            for line_no, line in enumerate(code.splitlines(), 1):
                if re.search(r"\bConvertFrom-Json\b", line) and not re.search(r"ConvertFrom-Json(?:Safe|Array)", line):
                    assert "-InputObject" in line, f"{fname}:{line_no} calls ConvertFrom-Json without -InputObject"

    @register("T5_04", 5, "F16+F23", "Adversarial pure 7-bit ASCII & BOM mutation detector (verifies both repo cleanliness and negative detection)")
    def _():
        for fname in ps.all_ps1_files():
            ps.assert_pure_ascii_ps1(fname)

        # Negative mutation checks: ensure check_pure_ascii_bytes catches BOM, smart quotes, Korean bytes, and NUL
        for bad_bytes in (
            b"\xef\xbb\xbfWrite-Host 'hi'\n",
            "Write-Host “smart quote”\n".encode("utf-8"),
            "Write-Host '한글'\n".encode("utf-8"),
            b"Write-Host 'nul\x00byte'\n",
        ):
            caught = False
            try:
                ps.check_pure_ascii_bytes(bad_bytes, "synthetic_mutation.ps1")
            except AssertionError:
                caught = True
            assert caught, f"check_pure_ascii_bytes failed to catch hostile payload: {bad_bytes!r}"

    @register("T5_05", 5, "F16+F23", "Adversarial PowerShellInspector.extract_function_body torture with unbalanced braces inside here-strings & comments")
    def _():
        synthetic_ps = (
            "function Invoke-TrickyHereString {\n"
            "  # Unbalanced { in line comment\n"
            "  <# Unbalanced } in block comment #>\n"
            '  $CSharp = @"\n'
            "  public class Foo {\n"
            '    // Unbalanced braces {{{ inside double here-string\n'
            '"@\n'
            "  $Literal = @'\n"
            "  }}} unbalanced closing braces in single here-string\n"
            "'@\n"
            '  $Escaped = "quote `"{ brace } inside string"\n'
            "  return 123\n"
            "}\n"
            "function Next-Func { return 456 }\n"
        )
        extracted = ps.extract_function_body_from_source(synthetic_ps, "Invoke-TrickyHereString", "synthetic.ps1")
        assert "return 123" in extracted
        assert "Next-Func" not in extracted

        # Also extract Broadcast-EnvironmentChange C# here-string function from common.ps1
        bcast_body = ps.extract_function_body("common.ps1", "Broadcast-EnvironmentChange")
        assert "SendMessageTimeout" in bcast_body

    @register("T5_06", 5, "F16+F23", "Adversarial cross-script parameter-forwarding negative mutation test (detects undeclared & conflicting ParameterSet flags)")
    def _():
        # Verify undeclared flag is caught
        caught_undeclared = False
        try:
            ps.validate_script_invocation_args("restore-and-cleanup.ps1", ["-Root", "-NonExistentBogusSwitch"], "mutation_test")
        except AssertionError:
            caught_undeclared = True
        assert caught_undeclared, "validate_script_invocation_args failed to catch undeclared flag"

        # Verify conflicting ParameterSet flags (-Apply and -Restore together on ai-hosts-block.ps1) are caught
        caught_conflict = False
        try:
            ps.validate_script_invocation_args("ai-hosts-block.ps1", ["-Apply", "-Restore", "-Root"], "mutation_test")
        except AssertionError:
            caught_conflict = True
        assert caught_conflict, "validate_script_invocation_args failed to catch conflicting ParameterSet flags"

    @register("T5_07", 5, "F16+F23", "Adversarial Assert-SafeRemovalPath & Test-PathInside parent-traversal (..), slash, and sibling-prefix fuzzing")
    def _():
        traversal_attacks = [
            "",
            "   ",
            ".",
            "..",
            "CPTools",
            ".\\CPTools",
            "C:",
            "C:\\",
            "C:///",
            "D:\\",
            "C:\\CPTools\\..",
            "C:\\CPTools\\sub\\..\\..",
            "C:\\CPTools\\..\\Windows",
            "C:/CPTools/../Program Files",
            "C:\\CPTools\\..\\Users\\Student",
            "C:\\Windows",
            "C:\\ProgramData\\",
            "C:\\Program Files (x86)",
        ]
        for attack in traversal_attacks:
            caught = False
            try:
                sim.assert_safe_removal_path(attack)
            except ValueError:
                caught = True
            assert caught, f"Assert-SafeRemovalPath failed to block hostile path: {attack!r}"

        assert sim.assert_safe_removal_path("C:\\CPTools\\sub\\..\\") == "C:\\CPTools"
        assert not sim.test_path_inside("C:\\CPTools_Backup\\file.txt", "C:\\CPTools")
        assert not sim.test_path_inside("C:\\msys64_student\\usr\\bin\\bash.exe", "C:\\msys64")
        assert not sim.test_path_inside("", "C:\\CPTools")
        assert not sim.test_path_inside("C:\\CPTools", "")

    @register("T5_08", 5, "F16+F23", "Adversarial hosts file injection, wildcard/URL rejection, and commented-rule spoofing audit")
    def _():
        hostile_blocklist_lines = [
            "# Full-line comment",
            "0.0.0.0 chatgpt.com # inline comment",
            "*.openai.com",
            "https://claude.ai/login",
            "claude.ai/path/traversal",
            "127.0.0.1 localhost",
            "0.0.0.0 0.0.0.0",
            "bad..domain..org!",
            "wrtn.ai",
        ]
        parsed = sim.parse_and_expand_blocklist_domains(hostile_blocklist_lines)
        assert "chatgpt.com" in parsed and "www.chatgpt.com" in parsed
        assert "wrtn.ai" in parsed and "www.wrtn.ai" in parsed
        assert "localhost" not in parsed
        for bad in parsed:
            assert "*" not in bad and "/" not in bad and "\\" not in bad

        # Verify Invoke-ContestEnvironmentAudit regex does NOT count commented '# 0.0.0.0 chatgpt.com' lines as active rules
        spoofed_block = "\n".join([f"# 0.0.0.0 domain{i}.ai" for i in range(150)])
        active_count = sum(
            1 for ln in spoofed_block.splitlines() if re.match(r"^(0\.0\.0\.0|::)\s+\S+", ln.strip())
        )
        assert active_count == 0

    @register("T5_09", 5, "F16+F23", "Adversarial HKU\\.DEFAULT (S-1-5-18) write prohibition & REG_EXPAND_SZ SetValue enforcement across all User PATH writes")
    def _():
        common_get = ps.extract_function_body("common.ps1", "Get-UserPathForTargetUser")
        common_set = ps.extract_function_body("common.ps1", "Set-UserPathForTargetUser")
        common_mach = ps.extract_function_body("common.ps1", "Set-RawMachinePath")
        restore_get = ps.extract_function_body("restore-and-cleanup.ps1", "Get-RegistryScopePathValue")
        restore_set = ps.extract_function_body("restore-and-cleanup.ps1", "Set-RegistryScopePathValue")

        for body in (common_get, restore_get):
            assert "DoNotExpandEnvironmentNames" in body

        # common.ps1 Set-UserPathForTargetUser & Set-RawMachinePath must compute $TargetKind preserving ExpandString whenever '%' is present or existing kind is ExpandString, and never unconditionally pass RegistryValueKind::String to SetValue
        for fn_label, body in (("Set-UserPathForTargetUser", common_set), ("Set-RawMachinePath", common_mach)):
            assert "$PathValue -match '%'" in body and "$ExistingKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString" in body, (
                f"common.ps1 {fn_label} missing '%' / ExpandString preservation check"
            )
            assert re.search(r"\.SetValue\(\s*'Path'\s*,\s*\$PathValue\s*,\s*\$TargetKind\s*\)", body), (
                f"common.ps1 {fn_label} must pass $TargetKind to SetValue('Path', ...)"
            )
            assert not re.search(r"\.SetValue\(\s*'Path'\s*,\s*\$PathValue\s*,\s*\[Microsoft\.Win32\.RegistryValueKind\]::String\s*\)", body), (
                f"common.ps1 {fn_label} must never hardcode RegistryValueKind::String in SetValue"
            )

        # restore-and-cleanup.ps1 Set-RegistryScopePathValue must pass ExpandString on both Machine and User SetValue calls
        assert not re.search(r"RegistryValueKind\]::String\b", restore_set), (
            "restore-and-cleanup.ps1 Set-RegistryScopePathValue must never write Path with RegistryValueKind::String"
        )
        assert len(re.findall(r"\.SetValue\(\s*'Path'\s*,\s*\$PathValue\s*,\s*\[Microsoft\.Win32\.RegistryValueKind\]::ExpandString\s*\)", restore_set)) >= 2

        # Global active-code prohibition: zero registry OpenSubKey/CreateSubKey/Set-ItemProperty/New-ItemProperty writes targeting .DEFAULT
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            assert not re.search(
                r"(?:OpenSubKey|CreateSubKey|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty)[^\n]*\.DEFAULT",
                code,
                re.IGNORECASE,
            ), f"{fname} attempts a registry write/open on HKU\\.DEFAULT"

        # Under S-1-5-18 without interactive student SID, both functions must return early before touching HKU / HKCU
        assert "$Resolved.Sid -eq 'S-1-5-18'" in common_set and "return" in common_set
        assert "$EffectiveSid -eq 'S-1-5-18'" in restore_set and "return $false" in restore_set

    @register("T5_10", 5, "F16+F23", "Adversarial 6-window schedule state machine verification (dual -StartWhenAvailable + -NotAfter + >25m late-boot guard)")
    def _():
        kst = datetime.timezone(datetime.timedelta(hours=9))
        exam_start = datetime.datetime(2026, 11, 23, 19, 0, 0, tzinfo=kst)
        exam_end = datetime.datetime(2026, 11, 23, 20, 30, 0, tzinfo=kst)
        restore_iso = "2026-11-23T20:30:00+09:00"

        windows = [
            # (timestamp, expect_19h_allowed, expect_restore_shutdown)
            (datetime.datetime(2026, 11, 23, 18, 30, 0, tzinfo=kst), True, True),
            (exam_start, True, True),
            (datetime.datetime(2026, 11, 23, 19, 45, 0, tzinfo=kst), True, True),
            (exam_end, True, True),
            (datetime.datetime(2026, 11, 23, 20, 45, 0, tzinfo=kst), False, True),   # +15m late: 19h blocked, shutdown still allowed
            (datetime.datetime(2026, 11, 23, 20, 56, 0, tzinfo=kst), False, False),  # +26m late: 19h blocked AND shutdown suppressed
            (datetime.datetime(2026, 11, 24, 9, 0, 0, tzinfo=kst), False, False),    # Next morning: both safe!
        ]
        for ts, exp_19h, exp_shutdown in windows:
            allowed_19h = ts <= exam_end
            shutdown_ok = sim.simulate_late_boot_shutdown_guard(True, restore_iso, ts)
            assert allowed_19h is exp_19h, f"19:00 enforcement mismatch at {ts}: got {allowed_19h}"
            assert shutdown_ok is exp_shutdown, f"Shutdown guard mismatch at {ts}: got {shutdown_ok}"

    @register("T5_11", 5, "F16+F23", "Adversarial non-destructive call-graph audit of DryRun, Status, and Verify modes")
    def _():
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        sched_body = ps.extract_function_body("common.ps1", "Test-ExamScheduleConfiguration")
        for read_only_fn, body in (("Invoke-ContestEnvironmentAudit", audit_body), ("Test-ExamScheduleConfiguration", sched_body)):
            for forbidden_mutator in (
                "Remove-Item",
                "Set-RawMachinePath",
                "Set-UserPathForTargetUser",
                "Write-HostsFileWithRetry",
                "Write-JsonUtf8NoBom",
                "Write-TextUtf8NoBom",
                "Register-ScheduledTask",
                "Unregister-ScheduledTask",
                "Stop-Process",
                "MessageBox]::Show",
            ):
                assert forbidden_mutator not in body, f"Read-only function {read_only_fn} contains mutator '{forbidden_mutator}'"

    @register("T5_12", 5, "F16+F23", "Adversarial product.json Marketplace spoof & partial-lock detection")
    def _():
        # Case 1: Comment contains https://127.0.0.1 while actual serviceUrl points to marketplace -> audit MUST reject!
        spoofed_product = (
            '{\n'
            '  // "serviceUrl": "https://127.0.0.1"\n'
            '  "extensionsGallery": {\n'
            '    "serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery",\n'
            '    "itemUrl": "https://127.0.0.1"\n'
            '  }\n'
            '}'
        )
        parsed = sim.simulate_jsonc_strip_and_parse(spoofed_product)
        assert isinstance(parsed, dict)
        svc_url = parsed["extensionsGallery"]["serviceUrl"]
        item_url = parsed["extensionsGallery"]["itemUrl"]
        is_locked = (svc_url == "https://127.0.0.1") and (item_url == "https://127.0.0.1")
        assert is_locked is False

        # Case 2: serviceUrl locked, but itemUrl still unlocked -> Disable-VSCodeMarketplace post-write check rejects!
        half_locked = {"extensionsGallery": {"serviceUrl": "https://127.0.0.1", "itemUrl": "https://marketplace.visualstudio.com/items"}}
        assert not (
            half_locked["extensionsGallery"]["serviceUrl"] == "https://127.0.0.1"
            and half_locked["extensionsGallery"]["itemUrl"] == "https://127.0.0.1"
        )

    @register("T5_13", 5, "F16+F23", "Adversarial VS Code direct Code.exe portable-data bypass & unauthorized extension sweep audit")
    def _():
        audit_body = ps.extract_function_body("common.ps1", "Invoke-ContestEnvironmentAudit")
        rem_body = ps.extract_function_body("setup-vscode.ps1", "Remove-BlockedVSCodeExtensions")
        # Both setup sweep and audit inspect BOTH vscode-contest\extensions AND vscode\data\extensions
        assert "Get-ContestVSCodeExtensionsDir" in rem_body and "Get-PortableVSCodeDataDir" in rem_body
        assert "Join-Path $Root 'vscode-contest\\extensions'" in audit_body
        assert "Join-Path $Root 'vscode\\data\\extensions'" in audit_body

    @register("T5_14", 5, "F16+F23", "Adversarial CMD/Batch metacharacter & Session-0 safety audit (%% escaping, no timeout.exe, no (%*) blocks)")
    def _():
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "$EscapedRootForCmd = $Root.Replace('%', '%%')" in restore_code
        assert "timeout /t" not in restore_code.lower() and "timeout.exe" not in restore_code.lower()
        assert "ping 127.0.0.1" in restore_code

        for script in ("setup-wrappers.ps1", "setup-vscode.ps1"):
            code = ps.read_active_code(script)
            for line in code.splitlines():
                if "%*" in line:
                    assert ") else (" not in line, f"{script} uses unsafe cmd parenthesized block around %*"

    @register("T5_15", 5, "F16+F23", "Adversarial Python WiX Burn vs personal Python 3.10 uninstall isolation proof")
    def _():
        # Simulate registry scan from restore-and-cleanup.ps1 lines 1578-1625
        def select_python_uninstallers(
            installed_by_contest: bool,
            root_path: str,
            registry_items: List[Dict[str, str]],
        ) -> List[str]:
            if not installed_by_contest:
                return []
            all_py = [
                it for it in registry_items
                if it.get("DisplayName", "").startswith("Python 3.10")
            ]
            matching = [
                it for it in all_py
                if it.get("InstallLocation") and sim.test_path_inside(it["InstallLocation"], root_path)
            ]
            if len(matching) > 0:
                for cand in all_py:
                    if not cand.get("InstallLocation") and (
                        "Package Cache" in cand.get("QuietUninstallString", "")
                        or "Package Cache" in cand.get("UninstallString", "")
                    ):
                        matching.append(cand)
            return [m["DisplayName"] for m in matching]

        personal_entries = [
            {
                "DisplayName": "Python 3.10.11 (64-bit)",
                "InstallLocation": "",
                "QuietUninstallString": '"C:\\ProgramData\\Package Cache\\{guid}\\python-3.10.11-amd64.exe" /uninstall /quiet',
            },
            {
                "DisplayName": "Python 3.10.11 Core Interpreter (64-bit)",
                "InstallLocation": "C:\\Users\\Student\\AppData\\Local\\Programs\\Python\\Python310\\",
                "UninstallString": "MsiExec.exe /X{11111111-1111-1111-1111-111111111111}",
            },
        ]
        # Case A: Student had personal Python -> PythonInstalledByContestSetup=False -> ZERO uninstallers touched!
        assert select_python_uninstallers(False, "C:\\CPTools", personal_entries) == []
        # Case B: Even if manifest was missing (PythonInstalledByContestSetup=True), InstallLocation is outside C:\CPTools -> ZERO uninstallers touched!
        assert select_python_uninstallers(True, "C:\\CPTools", personal_entries) == []
        # Case C: ContestSetup installed Python inside C:\CPTools -> both sub-MSI and Burn bundle selected!
        contest_entries = [
            personal_entries[0],
            {
                "DisplayName": "Python 3.10.11 Core Interpreter (64-bit)",
                "InstallLocation": "C:\\CPTools\\Python310\\",
                "UninstallString": "MsiExec.exe /X{22222222-2222-2222-2222-222222222222}",
            },
        ]
        selected = select_python_uninstallers(True, "C:\\CPTools", contest_entries)
        assert len(selected) == 2

    @register("T5_16", 5, "F16+F23", "Adversarial captive-portal HTML / truncated / swapped-extension cache poisoning matrix")
    def _():
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            # 1) 64 KB captive portal HTML saved as .exe and .zip
            portal_exe = tpath / "python-3.10.11-amd64.exe"
            portal_exe.write_bytes(b"<!DOCTYPE html><html><body>Campus WiFi Login</body></html>" * 2000)
            portal_zip = tpath / "vscode-win32-x64-archive.zip"
            portal_zip.write_bytes(b"<!DOCTYPE html><html><body>Rate limit 429</body></html>" * 2000)
            # 2) Valid magic header but truncated below min_bytes (e.g., 100 bytes < 15 MB)
            tiny_exe = tpath / "truncated.exe"
            tiny_exe.write_bytes(b"MZ" + b"\x00" * 100)
            # 3) Swapped headers: ZIP header on .exe, MZ header on .zip
            zip_as_exe = tpath / "swapped.exe"
            zip_as_exe.write_bytes(b"PK\x03\x04" + b"\x00" * 4096)
            exe_as_zip = tpath / "swapped.zip"
            exe_as_zip.write_bytes(b"MZ\x90\x00" + b"\x00" * 4096)
            # 4) Valid .nupkg and .vsix (ZIP container format)
            good_nupkg = tpath / "python.3.10.11.nupkg"
            good_nupkg.write_bytes(b"PK\x03\x04" + b"\x00" * 4096)
            good_vsix = tpath / "cpptools.vsix"
            good_vsix.write_bytes(b"PK\x03\x04" + b"\x00" * 4096)

            assert not sim.can_reuse_cached_download(portal_exe, min_bytes=4096)
            assert not sim.can_reuse_cached_download(portal_zip, min_bytes=4096)
            assert not sim.can_reuse_cached_download(tiny_exe, min_bytes=15 * 1024 * 1024)
            assert not sim.can_reuse_cached_download(zip_as_exe, min_bytes=1024)
            assert not sim.can_reuse_cached_download(exe_as_zip, min_bytes=1024)
            assert sim.can_reuse_cached_download(good_nupkg, min_bytes=1024)
            assert sim.can_reuse_cached_download(good_vsix, min_bytes=1024)

    @register("T5_17", 5, "F16+F23", "Adversarial static audit for PS 5.1 StrictMode 2.0 & runtime anti-patterns across all .ps1 scripts")
    def _():
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            assert "-NoExit" not in code, f"{fname} contains -NoExit hang"
            assert "--includeRecommended" not in code, f"{fname} contains bloated --includeRecommended"
            assert "Encoding]::ASCII" not in code, f"{fname} uses lossy ASCII encoding"
            assert not re.search(r"Get-Command\s+['\"]?tar(?:\.exe)?['\"]?", code, re.IGNORECASE), (
                f"{fname} resolves tar via Get-Command (vulnerable to MSYS2/Git GNU tar shadowing)"
            )

    @register("T5_18", 5, "F16+F23", "Adversarial MSYS2 two-stage SyncFirst, active pacman lock protection, and offline archive fallback audit")
    def _():
        msys_code = ps.read_active_code("setup-msys2.ps1")
        lock_body = ps.extract_function_body("setup-msys2.ps1", "Remove-StaleMsys2Locks")
        pac_body = ps.extract_function_body("setup-msys2.ps1", "Invoke-PacmanChecked")
        # 1) Never remove db.lck when pacman inside $MsysRoot is running
        assert "if ($ActivePacman.Count -eq 0)" in lock_body
        # 2) Stage-2 toolchain install runs if Stage-1 exited 0 early due to SyncFirst runtime update
        stage1_pos = msys_code.find("Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc")
        syncfirst_pos = msys_code.find("if (-not (Test-Msys2RequiredBinariesExist))")
        stage2_pos = msys_code.rfind("Invoke-PacmanChecked '--needed -Syu mingw-w64-ucrt-x86_64-gcc")
        assert -1 < stage1_pos < syncfirst_pos < stage2_pos
        # 3) Offline package archive fallback when network is unreachable (excluding .sig detached signatures & PS 5.1 Legacy inner double quotes)
        assert 'pkgs=(/var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.xz)' in pac_body
        assert "pacman --noconfirm --needed --overwrite ''*'' -U ${pkgs[@]}" in pac_body

    @register("T5_19", 5, "F16+F23", "Adversarial restore-and-cleanup.ps1 TEMP self-relocation fork-bomb prevention (-ReinvokedFromTemp)")
    def _():
        code = ps.read_active_code("restore-and-cleanup.ps1")
        params = ps.parse_declared_parameters("restore-and-cleanup.ps1")
        assert "reinvokedfromtemp" in params
        assert "if ($PSCommandPath -and (-not $ReinvokedFromTemp) -and ($PreserveDirs.Count -eq 0) -and (Test-PathInside -ChildPath $PSCommandPath -ParentPath $Root))" in code
        fwd_body = ps.extract_function_body("restore-and-cleanup.ps1", "Build-RestoreForwardArgs")
        assert "if ($IncludeReinvokedFromTemp -or $ReinvokedFromTemp) { $ArgItems += '-ReinvokedFromTemp' }" in fwd_body

    @register("T5_20", 5, "F16+F23", "Adversarial documentation-to-code truthfulness audit across PROJECT.md, ARCHITECTURE_V2.md, README.md, and .ps1 scripts")
    def _():
        proj = ps.read_text("PROJECT.md")
        arch = ps.read_text("ARCHITECTURE_V2.md")
        readme = ps.read_text("README.md")

        # 1) Every .ps1 file in repo is documented in PROJECT.md Code Layout
        for fname in PS1_FILES:
            assert fname in proj, f"PROJECT.md Code Layout missing {fname}"
            assert (REPO_ROOT / fname).is_file(), f"Missing script file {fname}"

        # 2) All 28 stability defect IDs (S-01..S-28) and all 10 optimization IDs (O1..O10) documented in ARCHITECTURE_V2.md
        for i in range(1, 29):
            assert f"**S-{i:02d}**" in arch, f"ARCHITECTURE_V2.md table missing **S-{i:02d}**"
        for i in range(1, 11):
            assert f"**O{i}**" in arch, f"ARCHITECTURE_V2.md table missing **O{i}**"

        # 3) All 3 Scheduled Task names match across PROJECT.md, README.md, ARCHITECTURE_V2.md, and restore-and-cleanup.ps1
        restore_code = ps.read_active_code("restore-and-cleanup.ps1")
        for task_name in ("ContestSetupRestoreAndCleanup", "ContestSetupRestoreAiHostsBlock", "ContestSetupExamStartEnforcement"):
            assert task_name in proj and task_name in readme and task_name in arch and task_name in restore_code

    @register("T5_21", 5, "F16+F23", "Adversarial collateral-damage guard: zero Online Judge or installer/mirror domains in $DefaultAiBlockDomains")
    def _():
        base_domains = sim.get_default_ai_domains()
        expanded_domains = set(sim.parse_and_expand_blocklist_domains([f"0.0.0.0 {d}" for d in base_domains]))

        # Subtree-protected domains: neither apex nor ANY subdomain may ever be blocked
        protected_subtrees = (
            "acmicpc.net",
            "solved.ac",
            "codeforces.com",
            "atcoder.jp",
            "programmers.co.kr",
            "codeup.kr",
            "swexpertacademy.com",
            "jungol.co.kr",
            "raw.githubusercontent.com",
            "objects.githubusercontent.com",
            "python.org",
            "files.pythonhosted.org",
            "pypi.org",
            "nuget.org",
            "msys2.org",
            "kaist.ac.kr",
            "harukasan.org",
            "visualstudio.com",
        )
        for blocked in expanded_domains:
            for protected in protected_subtrees:
                assert not (blocked == protected or blocked.endswith("." + protected)), (
                    f"CRITICAL COLLATERAL DAMAGE: '{blocked}' in $DefaultAiBlockDomains blocks judge/installer domain '{protected}'"
                )

        # Exact-host protected apexes/installers (note: copilot.github.com and copilot.microsoft.com are intentionally blocked AI subdomains)
        protected_exact_hosts = {
            "github.com",
            "www.github.com",
            "api.github.com",
            "codeload.github.com",
            "gist.github.com",
            "microsoft.com",
            "www.microsoft.com",
            "download.microsoft.com",
            "learn.microsoft.com",
            "aka.ms",
            "www.aka.ms",
            "google.com",
            "www.google.com",
            "naver.com",
            "www.naver.com",
        }
        overlap = sorted(expanded_domains & protected_exact_hosts)
        assert not overlap, f"CRITICAL COLLATERAL DAMAGE: $DefaultAiBlockDomains blocks essential exact hosts: {overlap}"

    @register("T5_22", 5, "F16+F23", "Adversarial StrictMode 2.0 unbraced $Variable? interpolation ban across all .ps1 scripts (F-1 / C1-01)")
    def _():
        # In PowerShell double-quoted strings, "$AiScriptUrl?cb=..." parses "AiScriptUrl?" as the variable name because '?' is a legal identifier char!
        for fname in ps.all_ps1_files():
            code = ps.read_active_code(fname)
            offenders = re.findall(r"(?<!`)\$[A-Za-z_][A-Za-z0-9_]*\?", code)
            assert not offenders, (
                f"{fname} contains StrictMode-fatal unbraced '$Var?' interpolation {offenders}; use '${{Var}}?'"
            )
        inst_ai = ps.read_active_code("install-ai-hosts.ps1")
        assert '"${AiScriptUrl}?cb=$CacheBust"' in inst_ai

    @register("T5_23", 5, "F16+F23", "Adversarial function-scope $PSBoundParameters ban in parameterless functions & -DurationHours <= 0 guard (C1-02)")
    def _():
        ai_code = ps.read_active_code("ai-hosts-block.ps1")
        assert "$Script:ScriptBoundParameters = @{}" in ai_code

        for fn_name in ("Ensure-Admin", "Get-RestoreTime"):
            fn_body = ps.extract_function_body("ai-hosts-block.ps1", fn_name)
            assert "$PSBoundParameters" not in fn_body, (
                f"Parameterless function {fn_name} in ai-hosts-block.ps1 references empty local $PSBoundParameters instead of $Script:ScriptBoundParameters"
            )
            assert "$Script:ScriptBoundParameters.ContainsKey('DurationHours')" in fn_body

        restore_time_body = ps.extract_function_body("ai-hosts-block.ps1", "Get-RestoreTime")
        assert "if ($ExplicitDuration)" in restore_time_body
        assert "if ($DurationHours -lt 1)" in restore_time_body and "throw '-DurationHours must be at least 1.'" in restore_time_body

    @register("T5_24", 5, "F16+F23", "Adversarial PS 5.1 StrictMode 2.0 scalar-unwrapping .Count guard across setup-vscode, ai-hosts-block, and restore (M-1 / C1-02)")
    def _():
        ext_body = ps.extract_function_body("setup-vscode.ps1", "Install-VSCodeExtensions")
        assert "$ExtensionsToInstall = @(if ($ForceExtUpdate) { $RequiredExtensions } else { $Missing })" in ext_body

        apply_body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        assert "$Domains = @(Get-BlockDomains)" in apply_body

        rc_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert "[string[]]$Lines = @(Read-LinesUtf8 -Path $SnapshotFile)" in rc_code
        assert "$Entries = @(ConvertFrom-JsonArray -Json $RawJson)" in ps.extract_function_body("ai-hosts-block.ps1", "Restore-ContestBrowserPolicies")
        assert "$PolicyEntries = @(ConvertFrom-JsonArray -Json $RawPolicyJson)" in ps.extract_function_body("restore-and-cleanup.ps1", "Restore-BrowserPoliciesFallback")

    @register("T5_25", 5, "F16+F23", "Adversarial wildcard path injection (-LiteralPath) & StrictMode shortcut-manifest .PSObject.Properties guards (M-3 / C1-03)")
    def _():
        sha_body = ps.extract_function_body("common.ps1", "Assert-FileSha256")
        auth_body = ps.extract_function_body("common.ps1", "Assert-AuthenticodeValid")
        assert "Get-FileHash -LiteralPath $Path" in sha_body and "Get-FileHash -Path" not in sha_body
        assert "Get-AuthenticodeSignature -LiteralPath $Path" in auth_body and "Get-AuthenticodeSignature -FilePath" not in auth_body
        assert "$null -eq $Signature" in auth_body and "$null -ne $Signature.SignerCertificate" in auth_body

        for fn_name in ("Write-VSCodeShortcutManifest", "Get-VSCodeShortcutManifestItem", "Set-ContestVSCodeShortcut", "Restore-NormalVSCodeShortcut"):
            fn_body = ps.extract_function_body("setup-vscode.ps1", fn_name)
            assert "PSObject.Properties[" in fn_body, (
                f"setup-vscode.ps1 {fn_name} missing StrictMode-safe .PSObject.Properties[...] guard on deserialized manifest object"
            )

    @register("T5_26", 5, "F16+F23", "Adversarial JSONC leading-whitespace + multi-BOM, null input, and unterminated /* comment EOF resilience (C1-04 / C1-05)")
    def _():
        for script in ("common.ps1", "setup-vscode.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            safe_body = ps.extract_function_body(script, "ConvertFrom-JsonSafe")
            arr_body = ps.extract_function_body(script, "ConvertFrom-JsonArray")
            assert "AllowNull" in safe_body and "AllowNull" in arr_body, f"{script} missing [AllowNull()] on JSON helpers"
            strip_target = ps.extract_function_body(script, "Strip-JsonComments") if "Strip-JsonComments" in ps.read_active_code(script) else safe_body
            assert "TrimStart([char]0xFEFF" in strip_target, f"{script} missing multi-BOM + whitespace TrimStart([char]0xFEFF, ...)"

        # Behavioral simulation on whitespace-before-BOM, double-BOM, null, and unterminated /* at EOF
        assert sim.simulate_jsonc_strip_and_parse(None) is None
        assert sim.simulate_jsonc_strip_and_parse("  \r\n\t \ufeff\ufeff /* unterminated block comment at EOF") is None
        parsed = sim.simulate_jsonc_strip_and_parse('  \ufeff\ufeff {"ok": true, } /* trailing unterminated comment')
        assert parsed == {"ok": True}

    @register("T5_27", 5, "F16+F23", "Adversarial hosts post-write read-back AV/Defender tamper detection & .*\\z orphan-marker EOF regex (N-2 / N-6)")
    def _():
        apply_body = ps.extract_function_body("ai-hosts-block.ps1", "Apply-AiHostsBlock")
        write_pos = apply_body.find("Write-HostsFileWithRetry -Path $HostsPath -Content $NewHostsContent")
        verify_pos = apply_body.find("$PostWriteHosts = Read-TextUtf8 -Path $HostsPath")
        throw_pos = apply_body.find("Post-write hosts verification failed")
        assert -1 < write_pos < verify_pos < throw_pos
        assert apply_body.count("$PostWriteHosts = Read-TextUtf8 -Path $HostsPath") >= 2

        rem_body = ps.extract_function_body("ai-hosts-block.ps1", "Remove-ManagedHostsSectionFromText")
        rc_code = ps.read_active_code("restore-and-cleanup.ps1")
        assert ".*\\z" in rem_body, "Remove-ManagedHostsSectionFromText must use .*\\z (not .*$) to strip orphan BEGIN markers through absolute EOF"
        assert ".*\\z" in rc_code, "restore-and-cleanup.ps1 direct hosts fallback must use .*\\z for orphan BEGIN markers"

    @register("T5_28", 5, "F16+F23", "Adversarial Expand-ArchiveFast Tier-2 & Tier-3 pre-clean destination anti-merge audit (N-2)")
    def _():
        body = ps.extract_function_body("common.ps1", "Expand-ArchiveFast")
        clean_calls = len(
            re.findall(
                r"Get-ChildItem\s+-LiteralPath\s+\$DestinationPath\s+-Force[^\n]*\|\s*Remove-Item\s+-Recurse\s+-Force",
                body,
            )
        )
        assert clean_calls >= 2, (
            f"Expand-ArchiveFast must clean partial files in $DestinationPath before BOTH Tier-2 ZipFile AND Tier-3 Expand-Archive (found {clean_calls})"
        )

    @register("T5_29", 5, "F16+F23", "Adversarial CONTEST_MUTEX_OWNER_PID spoofing & dead/self-PID rejection simulation (F-3)")
    def _():
        def should_skip_child_mutex(env_pid_raw: str, current_pid: int, live_pids: Set[int]) -> bool:
            raw = (env_pid_raw or "").strip()
            if not raw:
                return False
            try:
                owner_pid = int(raw)
            except ValueError:
                return False
            return owner_pid > 0 and owner_pid != current_pid and (owner_pid in live_pids)

        # Live parent PID -> skip mutex wait (0s stall)
        assert should_skip_child_mutex("4242", 5000, {1, 4242, 5000}) is True
        # Self PID -> MUST NOT skip (prevents env inheritance bug on same PID reuse)
        assert should_skip_child_mutex("5000", 5000, {1, 5000}) is False
        # Dead/stale PID -> MUST NOT skip (acquires mutex normally)
        assert should_skip_child_mutex("9999", 5000, {1, 5000}) is False
        # Invalid/negative/zero/non-numeric strings -> MUST NOT skip
        for bogus in ("", "   ", "0", "-10", "not-a-pid", "4242;calc.exe"):
            assert should_skip_child_mutex(bogus, 5000, {1, 4242, 5000}) is False

        # Verify restore-and-cleanup.ps1 acquires mutex INSIDE try { ... } finally { ... }
        rc_code = ps.read_active_code("restore-and-cleanup.ps1")
        outer_try_pos = rc_code.find("$RestoreMutex = New-Object System.Threading.Mutex")
        preceding_try = rc_code.rfind("try", 0, outer_try_pos)
        finally_pos = rc_code.rfind("finally")
        assert -1 < preceding_try < outer_try_pos < finally_pos

    @register("T5_30", 5, "F16+F23", "Adversarial VS Code 1.97+ multi-layout product.json resolution & -KeepVSCode unlock simulation (C-1 / N-8)")
    def _():
        def sim_resolve_product_json(vsc_root: Path) -> Optional[Path]:
            flat = vsc_root / "resources" / "app" / "product.json"
            if flat.is_file():
                return flat
            code_cmd = vsc_root / "bin" / "code.cmd"
            if code_cmd.is_file():
                txt = code_cmd.read_text(encoding="utf-8")
                m = re.search(r"(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js", txt)
                if m:
                    cand = vsc_root / m.group(1) / "resources" / "app" / "product.json"
                    if cand.is_file():
                        return cand
            excluded = {"data", "bin", "tools", "policies", "appx"}
            subdirs = sorted(
                [d for d in vsc_root.iterdir() if d.is_dir() and d.name.lower() not in excluded],
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            for d in subdirs:
                cand = d / "resources" / "app" / "product.json"
                if cand.is_file():
                    return cand
            root_pj = vsc_root / "product.json"
            return root_pj if root_pj.is_file() else None

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "vscode"
            # Adversarially plant a decoy product.json inside excluded 'data' trap directory — must be ignored!
            decoy = root / "data" / "resources" / "app" / "product.json"
            decoy.parent.mkdir(parents=True)
            decoy.write_text('{"decoy": true}', encoding="utf-8")

            commit = "deadbeef1234567890"
            real_prod = root / commit / "resources" / "app" / "product.json"
            real_orig = root / commit / "resources" / "app" / "product.json.contest-orig"
            real_prod.parent.mkdir(parents=True)
            real_prod.write_text('{"extensionsGallery":{"serviceUrl":"https://127.0.0.1"}}', encoding="utf-8")
            real_orig.write_text('{"extensionsGallery":{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery"}}', encoding="utf-8")

            resolved = sim_resolve_product_json(root)
            assert resolved == real_prod and resolved != decoy

            # Simulate Restore-VSCodeProductJsonWhenKept
            shutil.copy2(real_orig, real_prod)
            real_orig.unlink()
            unlocked = json.loads(real_prod.read_text(encoding="utf-8"))
            assert "marketplace.visualstudio.com" in unlocked["extensionsGallery"]["serviceUrl"]
            assert not real_orig.exists()

    @register("T5_31", 5, "F16+F23", "Adversarial negative mutation meta-test proving simulator/AST guards catch .ps1 literal drift")
    def _():
        # Prove that our regex/value extractors immediately fail if .ps1 constants or operators are mutated
        mutated_late = "if ($LateMinutes -gt 250) { $Shutdown = [switch]$false }"
        assert not re.search(r"\$LateMinutes\s+-gt\s+25\b", mutated_late)

        mutated_pth = "$UpdatedPth = [regex]::Replace($RawPth, '(?m)^#\\s*import\\s+site\\b', '#import site')"
        assert not re.search(
            r"\[regex\]::Replace\(\s*\$RawPth\s*,\s*'\(\?m\)\^#\\s\*import\\s\+site\\b'\s*,\s*'import site'\s*\)",
            mutated_pth,
        )

        mutated_pol = "@{ KeyPath = 'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'automatic' }"
        m = re.search(
            r"@\{\s*KeyPath\s*=\s*'([^']+)'\s*;\s*Name\s*=\s*'([^']+)'\s*;\s*Type\s*=\s*'([^']+)'\s*;\s*Value\s*=\s*('[^']*'|[-+]?\d+)\s*\}",
            mutated_pol,
        )
        assert m and m.group(4).strip("'") != "off"

        mutated_minbytes = "if ($Item.Length -lt 0) { return $false }"
        assert not re.search(r"\$Item\.Length\s+-lt\s+\$MinBytes\b", mutated_minbytes)

    @register("T5_32", 5, "F16+F23", "Adversarial Set-StrictMode -Version 2.0 & PSNativeCommandUseErrorActionPreference enforcement across standalone scripts and lib/*.ps1")
    def _():
        for fname in ps.all_ps1_files():
            raw_code = ps.strip_comments(ps.read_text(fname))
            is_lib = fname.startswith("lib/")
            if is_lib or fname in ("common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
                assert "Set-StrictMode -Version 2.0" in raw_code, f"Standalone library/script {fname} missing Set-StrictMode -Version 2.0"
            if is_lib or fname in ("install-env.ps1", "common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
                assert "$global:PSNativeCommandUseErrorActionPreference = $false" in raw_code, (
                    f"{fname} missing PS 7+ native stderr guard $global:PSNativeCommandUseErrorActionPreference = $false"
                )
            if is_lib or fname in ("install-env.ps1", "common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1"):
                assert "$ErrorActionPreference = 'Stop'" in raw_code, f"{fname} missing $ErrorActionPreference = 'Stop'"
            # Zero Set-StrictMode -Off anywhere in the repository
            assert not re.search(r"Set-StrictMode\s+-Off\b", raw_code, re.IGNORECASE), f"{fname} disables StrictMode"

    @register("T5_33", 5, "F18", "Regression: Get-ContestVariableValue survives shallow call stacks (top-level irm|iex) where Get-Variable -Scope 2 throws ArgumentOutOfRange")
    def _():
        body = ps.extract_function_body("common.ps1", "Get-ContestVariableValue")
        guarded = re.search(
            r"try\s*\{\s*\$Variable\s*=\s*Get-Variable\s+-Name\s+\$Name\s+-Scope\s+\$Scope\s+-ErrorAction\s+Stop\s*\}\s*catch\s*\{\s*\$Variable\s*=\s*\$null\s*\}",
            body,
        )
        assert guarded, "Numeric-scope Get-Variable lookup must be wrapped in try/catch (ArgumentOutOfRange is not suppressible via -ErrorAction)"

        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("live check needs pwsh (set CONTEST_PWSH or put pwsh on PATH); static guard check passed")

        common_code = ps.read_text("common.ps1")
        # -Command executes at the global scope, so from inside the function Scope 1 == Global and Scope 2 is out of range,
        # exactly like `irm .../install-env.ps1 | iex` from an interactive prompt (a -File script would add a scope and mask the bug).
        probe = (
            "$ErrorActionPreference = 'Stop'; "
            "Invoke-Expression ([System.IO.File]::ReadAllText($env:CS_REGRESSION_COMMON)); "
            "$r1 = Get-ContestVariableValue -Name 'CsRegressionMissingVar' -DefaultValue 'fallback'; "
            "$CsRegressionTopVar = 'from-top'; "
            "$r2 = Get-ContestVariableValue -Name 'CsRegressionTopVar' -DefaultValue 'fallback'; "
            "$env:CS_REGRESSION_ENV = 'from-env'; "
            "$r3 = Get-ContestVariableValue -Name 'CsRegressionMissingVar2' -DefaultValue 'fallback' -EnvVar 'CS_REGRESSION_ENV'; "
            "$r4 = Get-ContestVariableValue -Name 'CsRegressionMissingVar3' -DefaultValue $true; "
            "Write-Output ('RESULT:{0}|{1}|{2}|{3}' -f $r1, $r2, $r3, $r4)"
        )

        def run_probe(mutate: bool) -> "subprocess.CompletedProcess[str]":
            with tempfile.TemporaryDirectory(prefix="cs_t5_33_") as tmp:
                tmp_path = Path(tmp)
                src = tmp_path / "common.ps1"
                replacement = "$Variable = Get-Variable -Name $Name -Scope $Scope -ErrorAction SilentlyContinue"
                mutated_any = False
                c_txt = common_code
                if mutate and guarded.group(0) in c_txt:
                    c_txt = c_txt.replace(guarded.group(0), replacement, 1)
                    mutated_any = True
                src.write_text(c_txt, encoding="utf-8")
                lib_dir = repo_root / "lib"
                if lib_dir.is_dir():
                    dst_lib = tmp_path / "lib"
                    shutil.copytree(lib_dir, dst_lib)
                    if mutate:
                        for lp in sorted(dst_lib.glob("*.ps1")):
                            ltxt = lp.read_text(encoding="utf-8")
                            if guarded.group(0) in ltxt:
                                lp.write_text(ltxt.replace(guarded.group(0), replacement, 1), encoding="utf-8")
                                mutated_any = True
                if mutate:
                    assert mutated_any, "Failed to locate guarded Get-Variable block in common.ps1 or lib/*.ps1 for mutation"
                env = dict(os.environ, CS_REGRESSION_COMMON=str(src))
                return subprocess.run(
                    [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-WorkingDirectory", str(tmp_path), "-Command", probe],
                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, env=env,
                )

        fixed = run_probe(False)
        assert fixed.returncode == 0, f"fixed common.ps1 probe failed (rc={fixed.returncode}): {fixed.stderr.strip()[-600:]}"
        assert "RESULT:fallback|from-top|from-env|True" in fixed.stdout, f"unexpected probe output: {fixed.stdout.strip()[-600:]}"

        broken = run_probe(True)
        assert broken.returncode != 0 and "RESULT:" not in broken.stdout, (
            "pre-fix (unguarded Get-Variable -Scope 2) variant unexpectedly succeeded; probe no longer reproduces the shallow-scope bug"
        )

    @register("T5_34", 5, "F18+F21+F6", "Live pwsh all-script AST/PS5.1/switch audit + C-1 StrictMode standalone dot-source & C-2 offline pacman -U .sig exclusion regressions")
    def _():
        # Static C-1 & C-2 checks first
        common_code = ps.read_active_code("common.ps1")
        assert "$RawBase = ([string](Get-ContestVariableValue -Name 'RawBase'" in common_code
        for gname in ("ProgressIdOuter", "ProgressIdInner", "SetupStepCurrent", "SetupStepTotal"):
            assert f"Get-Variable -Scope Global -Name '{gname}'" in common_code, f"common.ps1 missing StrictMode default guard for $Global:{gname}"

        msys_code = ps.read_active_code("setup-msys2.ps1")
        assert "-U /var/cache/pacman/pkg/*.pkg.tar.*" not in msys_code, (
            "pacman -U must not glob *.pkg.tar.* directly because *.pkg.tar.zst.sig signature files abort pacman -U"
        )
        assert msys_code.count('pkgs=(/var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.xz)') >= 2
        assert msys_code.count("IFS=$''\\n''") >= 2
        assert "Where-Object { $_.Name -notlike '*.sig' }" in msys_code

        install_code = ps.read_active_code("install-env.ps1")
        assert "if ($PkgFile.Name -notlike '*.sig') { $ExportedPkgCount++ }" in install_code

        pwsh = find_pwsh()
        if pwsh is None:
            raise TestSkipped("live AST & StrictMode check needs pwsh (set CONTEST_PWSH or put pwsh on PATH); static C-1/C-2 checks passed")

        all_files = ps.all_ps1_files()
        audit_script = r"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = $env:CS_REPO_ROOT
$files = $env:CS_PS1_LIST -split ';'
$astMap = @{}
$scriptSwitches = @{}
$funcSwitches = @{}

foreach ($f in $files) {
    $full = Join-Path $repo $f
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "AST parse error in ${f}: $($errors[0].Message)"
    }
    $astMap[$f] = $ast

    $ps7Nodes = $ast.FindAll({
        param($n)
        $n.GetType().Name -in @(
            'TernaryExpressionAst', 'PipelineChainAst', 'NullCoalescingExpressionAst',
            'NullConditionalExpressionAst', 'NullConditionalMemberExpressionAst', 'NullConditionalIndexExpressionAst'
        )
    }, $true)
    if ($ps7Nodes.Count -gt 0) {
        throw "PS 7-only syntax in ${f}:$($ps7Nodes[0].Extent.StartLineNumber): $($ps7Nodes[0].Extent.Text)"
    }
    $nullCondMembers = $ast.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.MemberExpressionAst]) -and
        $n.PSObject.Properties['NullConditional'] -and $n.NullConditional
    }, $true)
    if ($nullCondMembers.Count -gt 0) {
        throw "PS 7-only ?. member access in ${f}:$($nullCondMembers[0].Extent.StartLineNumber)"
    }

    $sw = @()
    if ($null -ne $ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            foreach ($a in $p.Attributes) {
                if (($a -is [System.Management.Automation.Language.TypeConstraintAst]) -and ($a.TypeName.FullName -match '^(?i)switch(parameter)?$')) {
                    $sw += $p.Name.VariablePath.UserPath
                }
            }
        }
    }
    $scriptSwitches[$f] = $sw

    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $fns) {
        $fsw = @()
        if ($null -ne $fn.Body.ParamBlock) {
            foreach ($p in $fn.Body.ParamBlock.Parameters) {
                foreach ($a in $p.Attributes) {
                    if (($a -is [System.Management.Automation.Language.TypeConstraintAst]) -and ($a.TypeName.FullName -match '^(?i)switch(parameter)?$')) {
                        $fsw += $p.Name.VariablePath.UserPath
                    }
                }
            }
        }
        if ($funcSwitches.ContainsKey($fn.Name)) {
            $funcSwitches[$fn.Name] = @($funcSwitches[$fn.Name] + $fsw | Select-Object -Unique)
        } else {
            $funcSwitches[$fn.Name] = $fsw
        }
    }
}

foreach ($f in $files) {
    $cmds = $astMap[$f].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $cName = $cmd.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($cName)) { continue }
        $elems = $cmd.CommandElements
        for ($i = 1; $i -lt $elems.Count; $i++) {
            $el = $elems[$i]
            if (($el -is [System.Management.Automation.Language.CommandParameterAst]) -and ($null -eq $el.Argument) -and (($i + 1) -lt $elems.Count)) {
                $nxt = $elems[$i + 1]
                if (-not ($nxt -is [System.Management.Automation.Language.CommandParameterAst])) {
                    $pName = $el.ParameterName
                    $leaf = Split-Path -Path $cName -Leaf -ErrorAction SilentlyContinue
                    $known = ($null -ne $leaf -and $scriptSwitches.ContainsKey($leaf) -and ($scriptSwitches[$leaf] -contains $pName)) -or
                             ($funcSwitches.ContainsKey($cName) -and ($funcSwitches[$cName] -contains $pName))
                    if ($known) {
                        throw "PS 5.1 space-separated switch binding in ${f}:$($el.Extent.StartLineNumber): $cName -$pName $($nxt.Extent.Text)"
                    }
                }
            }
        }
    }
}

# C-2 PS 5.1 Legacy native argument passing check: no Invoke-MsysBash* string argument in setup-msys2.ps1 may contain raw '"'
$msysCmds = $astMap['setup-msys2.ps1'].FindAll({
    param($n)
    ($n -is [System.Management.Automation.Language.CommandAst]) -and
    ($n.GetCommandName() -in @('Invoke-MsysBashOutput', 'Invoke-MsysBashChecked'))
}, $true)
if ($msysCmds.Count -lt 6) {
    throw "Expected at least 6 Invoke-MsysBash* call sites in setup-msys2.ps1, found $($msysCmds.Count)"
}
foreach ($mc in $msysCmds) {
    foreach ($ce in ($mc.CommandElements | Select-Object -Skip 1)) {
        if ($ce -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if ($ce.Value.Contains('"')) {
                throw "PS 5.1 Legacy quote-stripping hazard at setup-msys2.ps1:$($ce.Extent.StartLineNumber): raw double-quote inside Invoke-MsysBash* command string"
            }
        } elseif ($ce -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            if ($ce.Value.Contains('"')) {
                throw "PS 5.1 Legacy quote-stripping hazard at setup-msys2.ps1:$($ce.Extent.StartLineNumber): raw double-quote inside expandable Invoke-MsysBash* command string"
            }
        }
    }
}

# Live Legacy native argument passing check against bash if available (Linux/macOS or Git/MSYS bash)
if (Test-Path -LiteralPath '/bin/bash') {
    $oldPassing = $PSNativeCommandArgumentPassing
    $legTmp = Join-Path ([IO.Path]::GetTempPath()) ('cs_t5_34_leg_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $legTmp | Out-Null
    try {
        $PSNativeCommandArgumentPassing = 'Legacy'
        Set-Content -LiteralPath (Join-Path $legTmp 'decoy file.txt') -Value 'decoy'
        Set-Content -LiteralPath (Join-Path $legTmp 'gcc-14-any.pkg.tar.zst') -Value 'pkg1'
        Set-Content -LiteralPath (Join-Path $legTmp 'coreutils-9-any.pkg.tar.xz') -Value 'pkg2'
        Set-Content -LiteralPath (Join-Path $legTmp 'gcc-14-any.pkg.tar.zst.sig') -Value 'sig'
        Push-Location $legTmp
        $bashSnippet = ('shopt -s nullglob; IFS=$''\n''; pkgs=({0}/*.pkg.tar.zst {0}/*.pkg.tar.xz); [ ${{#pkgs[@]}} -gt 0 ] && printf ''%s\n'' --noconfirm --needed --overwrite ''*'' -U ${{pkgs[@]}}' -f $legTmp)
        $bashArgs = @('-lc', $bashSnippet)
        $bashOut = @(& /bin/bash @bashArgs)
        $joined = ($bashOut -join '|')
        if ($joined -notmatch '\-\-overwrite\|\*\|-U\|.*gcc-14-any\.pkg\.tar\.zst\|.*coreutils-9-any\.pkg\.tar\.xz$' -or $joined -match '\.sig' -or $joined -match 'decoy') {
            throw "Legacy argument passing probe failed: $joined"
        }
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        $PSNativeCommandArgumentPassing = $oldPassing
        Remove-Item -LiteralPath $legTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# C-1 live StrictMode 2.0 standalone dot-source check (unset globals + $RawBase)
Remove-Variable -Scope Global -Name ProgressIdOuter, ProgressIdInner, SetupStepCurrent, SetupStepTotal -ErrorAction SilentlyContinue
Remove-Variable -Name RawBase -ErrorAction SilentlyContinue
. (Join-Path $repo 'common.ps1')
$banner = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] $Global:ProgressIdOuter->$Global:ProgressIdInner $RawBase/ai-hosts-block.ps1"

# Verify caller-preset $RawBase & $Global:SetupStepCurrent are preserved when common.ps1 is dot-sourced
$RawBase = 'https://mirror.example.internal/ContestSetup/main/'
$Global:SetupStepCurrent = 5
$Global:SetupStepTotal = 8
. (Join-Path $repo 'common.ps1')
Write-Output ("AST_OK:{0}|DEFAULT:{1}|OVERRIDE:{2}/{3}|{4}" -f $files.Count, $banner, $Global:SetupStepCurrent, $Global:SetupStepTotal, $RawBase)
"""
        with tempfile.TemporaryDirectory(prefix="cs_t5_34_") as tmp:
            probe_file = Path(tmp) / "t5_34_audit.ps1"
            probe_file.write_text(audit_script, encoding="utf-8")
            env = dict(
                os.environ,
                CS_REPO_ROOT=str(REPO_ROOT),
                CS_PS1_LIST=";".join(all_files),
            )
            res = subprocess.run(
                [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(probe_file)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, env=env,
            )
            assert res.returncode == 0, f"T5_34 pwsh audit failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert (
                f"AST_OK:{len(all_files)}|DEFAULT:[1/1] 0->1 https://raw.githubusercontent.com/naixt1478/ContestSetup/main/ai-hosts-block.ps1"
                "|OVERRIDE:5/8|https://mirror.example.internal/ContestSetup/main"
            ) in res.stdout, f"unexpected T5_34 output: {res.stdout.strip()[-600:]}"

    return tests
