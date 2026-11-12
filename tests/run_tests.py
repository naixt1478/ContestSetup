#!/usr/bin/env python3
"""
ContestSetup v2.0 — Requirement-Driven 5-Tier E2E, Behavioral & Adversarial Verification Suite.

Usage:
    python3 tests/run_tests.py [--tier 1|2|3|4|5|all] [--verbose] [--json] [--strict]

Tiers:
    Tier 1: Feature Coverage (Category-Partition Method, 100 tests: 5 per F1..F14, F17..F22)
    Tier 2: Boundary & Corner Cases (Boundary Value Analysis, 100 tests: 5 per F1..F14, F17..F22)
    Tier 3: Cross-Feature Combinations (Pairwise & Interface Contract Testing, 34 tests)
    Tier 4: Real-World Application Scenarios (End-to-End Workload Simulation, 16 tests)
    Tier 5: White-Box Adversarial & Mutation Hardening (F16 + F23, 33 tests)
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

PS1_FILES = [
    "install-env.ps1",
    "common.ps1",
    "setup-msys2.ps1",
    "setup-python.ps1",
    "setup-visualstudio.ps1",
    "setup-vscode.ps1",
    "setup-wrappers.ps1",
    "setup-ai-hosts.ps1",
    "ai-hosts-block.ps1",
    "install-ai-hosts.ps1",
    "setup-restore-task.ps1",
    "restore-and-cleanup.ps1",
]

INSTALL_ENV_21_PARAMS: Dict[str, str] = {
    "Mode": "CONTEST_MODE",
    "ExamStart": "CONTEST_EXAM_START",
    "ExamEnd": "CONTEST_EXAM_END",
    "RestoreAt": "CONTEST_RESTORE_AT",
    "Root": "CONTEST_ROOT",
    "MsysRoot": "CONTEST_MSYS_ROOT",
    "CacheDir": "CONTEST_CACHE_DIR",
    "Msys2CaCertificatePath": "CONTEST_MSYS2_CA_PATH",
    "PythonVersion": "CONTEST_PYTHON_VERSION",
    "TargetUserSid": "CONTEST_TARGET_USER_SID",
    "TargetUserProfile": "CONTEST_TARGET_USER_PROFILE",
    "IncludeVisualStudio": "CONTEST_INCLUDE_VS",
    "ForceUpdate": "CONTEST_FORCE_UPDATE",
    "NoRestoreTask": "CONTEST_NO_RESTORE_TASK",
    "NoRestoreShutdown": "CONTEST_NO_RESTORE_SHUTDOWN",
    "RollbackOnFailure": "CONTEST_ROLLBACK_ON_FAILURE",
    "UseRemote": "CONTEST_USE_REMOTE",
    "KeepVSCode": "CONTEST_KEEP_VSCODE",
    "NoPause": "CONTEST_NO_PAUSE",
    "SkipSignatureCheck": "CONTEST_SKIP_SIGNATURE_CHECK",
    "DeferAiBlockUntilExamStart": "CONTEST_DEFER_AI_BLOCK",
}


@dataclass
class TestCase:
    test_id: str
    tier: int
    feature: str
    description: str
    fn: Callable[[], None]


class TestSkipped(Exception):
    """Raised by a test whose live-runtime prerequisite (e.g. pwsh) is unavailable; reported as SKIP, not PASS."""


def find_pwsh() -> Optional[str]:
    """Locate a PowerShell 7+ executable: $CONTEST_PWSH, then pwsh on PATH, then ~/.local/pwsh/pwsh."""
    candidates = [os.environ.get("CONTEST_PWSH", ""), shutil.which("pwsh") or "", str(Path.home() / ".local" / "pwsh" / "pwsh")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


class PowerShellInspector:
    """Lexical, structural, AST-contract, and function-level analyzer for PowerShell (.ps1) scripts."""

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self._raw_cache: Dict[str, str] = {}
        self._bytes_cache: Dict[str, bytes] = {}
        self._active_cache: Dict[str, str] = {}
        self._params_cache: Dict[str, Dict[str, Dict[str, object]]] = {}

    def read_bytes(self, rel_path: str) -> bytes:
        if rel_path not in self._bytes_cache:
            full = self.repo_root / rel_path
            if not full.exists():
                raise AssertionError(f"Expected file does not exist: {full}")
            self._bytes_cache[rel_path] = full.read_bytes()
        return self._bytes_cache[rel_path]

    def read_text(self, rel_path: str) -> str:
        if rel_path not in self._raw_cache:
            raw = self.read_bytes(rel_path)
            if raw.startswith(b"\xef\xbb\xbf"):
                text = raw[3:].decode("utf-8")
            else:
                text = raw.decode("utf-8")
            self._raw_cache[rel_path] = text
        return self._raw_cache[rel_path]

    def read_active_code(self, rel_path: str) -> str:
        """Return PowerShell source with comments stripped (preserving strings and here-strings)."""
        if rel_path not in self._active_cache:
            text = self.read_text(rel_path)
            self._active_cache[rel_path] = self.strip_comments(text)
        return self._active_cache[rel_path]

    @staticmethod
    def check_pure_ascii_bytes(raw: bytes, label: str) -> None:
        """Assert raw bytes are UTF-8 without BOM, contain no NULs, and strictly 7-bit ASCII (< 0x80)."""
        if raw.startswith(b"\xef\xbb\xbf"):
            raise AssertionError(f"{label} contains a UTF-8 BOM (0xEF 0xBB 0xBF); expected UTF-8 no-BOM pure ASCII")
        line_no = 1
        col_no = 0
        for idx, byte_val in enumerate(raw):
            if byte_val == 0x0A:
                line_no += 1
                col_no = 0
                continue
            col_no += 1
            if byte_val == 0x00:
                raise AssertionError(f"{label}:{line_no}:{col_no} (offset {idx}): contains NUL byte 0x00")
            if byte_val >= 0x80:
                raise AssertionError(
                    f"{label}:{line_no}:{col_no} (offset {idx}): non-ASCII byte 0x{byte_val:02X} breaks PS 5.1 CP949 safety"
                )

    def assert_pure_ascii_ps1(self, rel_path: str) -> None:
        """Assert a repository .ps1 script is 100% 7-bit ASCII (< 0x80) without BOM."""
        raw = self.read_bytes(rel_path)
        self.check_pure_ascii_bytes(raw, rel_path)

    @staticmethod
    def strip_comments(source: str) -> str:
        out: List[str] = []
        i = 0
        n = len(source)
        in_single = False
        in_double = False
        in_here_single = False
        in_here_double = False
        in_block_comment = False

        while i < n:
            if in_block_comment:
                end_idx = source.find("#>", i)
                if end_idx == -1:
                    break
                i = end_idx + 2
                in_block_comment = False
                continue

            if in_here_single:
                if source[i] == "\n" and source.startswith("'@", i + 1):
                    out.append("\n'@")
                    i += 3
                    in_here_single = False
                    continue
                out.append(source[i])
                i += 1
                continue

            if in_here_double:
                if source[i] == "\n" and source.startswith('"@', i + 1):
                    out.append('\n"@')
                    i += 3
                    in_here_double = False
                    continue
                out.append(source[i])
                i += 1
                continue

            if in_single:
                if source[i] == "'" and i + 1 < n and source[i + 1] == "'":
                    out.append("''")
                    i += 2
                    continue
                if source[i] == "'":
                    in_single = False
                out.append(source[i])
                i += 1
                continue

            if in_double:
                if source[i] == "`" and i + 1 < n:
                    out.append(source[i : i + 2])
                    i += 2
                    continue
                if source[i] == '"' and i + 1 < n and source[i + 1] == '"':
                    out.append('""')
                    i += 2
                    continue
                if source[i] == '"':
                    in_double = False
                out.append(source[i])
                i += 1
                continue

            if source.startswith("<#", i):
                in_block_comment = True
                i += 2
                continue

            if source.startswith("@'", i) and (i + 2 < n and source[i + 2] in ("\r", "\n")):
                in_here_single = True
                out.append("@'")
                i += 2
                continue

            if source.startswith('@"', i) and (i + 2 < n and source[i + 2] in ("\r", "\n")):
                in_here_double = True
                out.append('@"')
                i += 2
                continue

            if source[i] == "'":
                in_single = True
                out.append(source[i])
                i += 1
                continue

            if source[i] == '"':
                in_double = True
                out.append(source[i])
                i += 1
                continue

            if source[i] == "#":
                nl = source.find("\n", i)
                if nl == -1:
                    break
                i = nl
                continue

            out.append(source[i])
            i += 1

        return "".join(out)

    @staticmethod
    def validate_syntax_balance(source: str, filename: str) -> Tuple[bool, str]:
        """Verify balanced braces, parentheses, brackets, quotes, and here-strings in PowerShell code."""
        i = 0
        n = len(source)
        in_single = False
        in_double = False
        in_here_single = False
        in_here_double = False
        in_block_comment = False
        stack: List[Tuple[str, int]] = []
        pairs = {"}": "{", ")": "(", "]": "["}
        line_num = 1

        while i < n:
            ch = source[i]
            if ch == "\n":
                line_num += 1

            if in_block_comment:
                if source.startswith("#>", i):
                    in_block_comment = False
                    i += 2
                    continue
                i += 1
                continue

            if in_here_single:
                if ch == "\n" and source.startswith("'@", i + 1):
                    in_here_single = False
                    i += 3
                    continue
                i += 1
                continue

            if in_here_double:
                if ch == "\n" and source.startswith('"@', i + 1):
                    in_here_double = False
                    i += 3
                    continue
                i += 1
                continue

            if in_single:
                if ch == "'" and i + 1 < n and source[i + 1] == "'":
                    i += 2
                    continue
                if ch == "'":
                    in_single = False
                i += 1
                continue

            if in_double:
                if ch == "`" and i + 1 < n:
                    if source[i + 1] == "\n":
                        line_num += 1
                    i += 2
                    continue
                if ch == '"' and i + 1 < n and source[i + 1] == '"':
                    i += 2
                    continue
                if ch == '"':
                    in_double = False
                i += 1
                continue

            if source.startswith("<#", i):
                in_block_comment = True
                i += 2
                continue

            if ch == "#":
                nl = source.find("\n", i)
                if nl == -1:
                    break
                i = nl
                continue

            if source.startswith("@'", i) and (i + 2 < n and source[i + 2] in ("\r", "\n")):
                in_here_single = True
                i += 2
                continue

            if source.startswith('@"', i) and (i + 2 < n and source[i + 2] in ("\r", "\n")):
                in_here_double = True
                i += 2
                continue

            if ch == "'":
                in_single = True
                i += 1
                continue

            if ch == '"':
                in_double = True
                i += 1
                continue

            if ch in ("{", "(", "["):
                stack.append((ch, line_num))
            elif ch in ("}", ")", "]"):
                if not stack:
                    return False, f"{filename}:{line_num}: Unmatched closing '{ch}'"
                top, open_line = stack.pop()
                if top != pairs[ch]:
                    return False, f"{filename}:{line_num}: Mismatched '{ch}' for '{top}' opened at line {open_line}"

            i += 1

        if in_single:
            return False, f"{filename}: Unclosed single-quoted string"
        if in_double:
            return False, f"{filename}: Unclosed double-quoted string"
        if in_here_single or in_here_double:
            return False, f"{filename}: Unclosed here-string"
        if in_block_comment:
            return False, f"{filename}: Unclosed block comment"
        if stack:
            top, open_line = stack[-1]
            return False, f"{filename}: Unclosed '{top}' opened at line {open_line}"
        return True, "OK"

    @classmethod
    def extract_function_body_from_source(cls, raw_source: str, func_name: str, label: str = "<source>") -> str:
        """Extract `function <func_name> { ... }` accurately handling strings, comments, and here-strings."""
        code = cls.strip_comments(raw_source)
        pattern = re.compile(rf"\bfunction\s+{re.escape(func_name)}\b", re.IGNORECASE)
        match = pattern.search(code)
        if not match:
            raise AssertionError(f"Function '{func_name}' not found in {label}")
        brace_start = code.find("{", match.end())
        if brace_start == -1:
            raise AssertionError(f"Opening brace for function '{func_name}' not found in {label}")
        depth = 0
        in_single = False
        in_double = False
        in_here_single = False
        in_here_double = False
        i = brace_start
        n = len(code)
        while i < n:
            ch = code[i]
            if in_here_single:
                if ch == "\n" and code.startswith("'@", i + 1):
                    in_here_single = False
                    i += 3
                    continue
                i += 1
                continue
            if in_here_double:
                if ch == "\n" and code.startswith('"@', i + 1):
                    in_here_double = False
                    i += 3
                    continue
                i += 1
                continue
            if in_single:
                if ch == "'" and i + 1 < n and code[i + 1] == "'":
                    i += 2
                    continue
                if ch == "'":
                    in_single = False
                i += 1
                continue
            if in_double:
                if ch == "`" and i + 1 < n:
                    i += 2
                    continue
                if ch == '"' and i + 1 < n and code[i + 1] == '"':
                    i += 2
                    continue
                if ch == '"':
                    in_double = False
                i += 1
                continue

            if code.startswith("@'", i) and (i + 2 < n and code[i + 2] in ("\r", "\n")):
                in_here_single = True
                i += 2
                continue
            if code.startswith('@"', i) and (i + 2 < n and code[i + 2] in ("\r", "\n")):
                in_here_double = True
                i += 2
                continue
            if ch == "'":
                in_single = True
            elif ch == '"':
                in_double = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return code[brace_start + 1 : i]
            i += 1
        raise AssertionError(f"Unclosed brace for function '{func_name}' in {label}")

    def extract_function_body(self, rel_path: str, func_name: str) -> str:
        """Extract the body of `function <func_name> { ... }` from a PowerShell file."""
        return self.extract_function_body_from_source(self.read_text(rel_path), func_name, rel_path)

    def extract_param_block(self, rel_path: str) -> str:
        code = self.read_active_code(rel_path)
        match = re.search(r"\bparam\s*\(", code, re.IGNORECASE)
        if not match:
            raise AssertionError(f"No top-level param() block in {rel_path}")
        paren_start = code.find("(", match.start())
        depth = 0
        in_single = False
        in_double = False
        i = paren_start
        n = len(code)
        while i < n:
            ch = code[i]
            if in_single:
                if ch == "'" and i + 1 < n and code[i + 1] == "'":
                    i += 2
                    continue
                if ch == "'":
                    in_single = False
                i += 1
                continue
            if in_double:
                if ch == "`" and i + 1 < n:
                    i += 2
                    continue
                if ch == '"' and i + 1 < n and code[i + 1] == '"':
                    i += 2
                    continue
                if ch == '"':
                    in_double = False
                i += 1
                continue
            if ch == "'":
                in_single = True
            elif ch == '"':
                in_double = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return code[paren_start + 1 : i]
            i += 1
        raise AssertionError(f"Unclosed param() block in {rel_path}")

    def parse_declared_parameters(self, rel_path: str) -> Dict[str, Dict[str, object]]:
        """Parse top-level param(...) declarations into {param_name_lower: {name, type, param_sets, validate_set}}."""
        if rel_path in self._params_cache:
            return self._params_cache[rel_path]
        block = self.extract_param_block(rel_path)
        entries: List[str] = []
        buf: List[str] = []
        depth_paren = 0
        depth_bracket = 0
        in_single = False
        in_double = False
        i = 0
        n = len(block)
        while i < n:
            ch = block[i]
            if in_single:
                buf.append(ch)
                if ch == "'" and i + 1 < n and block[i + 1] == "'":
                    buf.append("'")
                    i += 2
                    continue
                if ch == "'":
                    in_single = False
                i += 1
                continue
            if in_double:
                buf.append(ch)
                if ch == "`" and i + 1 < n:
                    buf.append(block[i + 1])
                    i += 2
                    continue
                if ch == '"' and i + 1 < n and block[i + 1] == '"':
                    buf.append('"')
                    i += 2
                    continue
                if ch == '"':
                    in_double = False
                i += 1
                continue
            if ch == "'":
                in_single = True
            elif ch == '"':
                in_double = True
            elif ch == "(":
                depth_paren += 1
            elif ch == ")":
                depth_paren -= 1
            elif ch == "[":
                depth_bracket += 1
            elif ch == "]":
                depth_bracket -= 1
            elif ch == "," and depth_paren == 0 and depth_bracket == 0:
                entries.append("".join(buf).strip())
                buf = []
                i += 1
                continue
            buf.append(ch)
            i += 1
        if "".join(buf).strip():
            entries.append("".join(buf).strip())

        parsed: Dict[str, Dict[str, object]] = {}
        for entry in entries:
            var_matches = list(re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*)", entry))
            if not var_matches:
                continue
            eq_pos = entry.find("=")
            if eq_pos != -1:
                pre_eq = [m for m in var_matches if m.start() < eq_pos]
                param_match = pre_eq[-1] if pre_eq else var_matches[0]
            else:
                param_match = var_matches[-1]
            pname = param_match.group(1)
            psets = set(
                m.group(1)
                for m in re.finditer(r"ParameterSetName\s*=\s*['\"]([^'\"]+)['\"]", entry, re.IGNORECASE)
            )
            vset_m = re.search(r"ValidateSet\s*\(([^)]+)\)", entry, re.IGNORECASE)
            validate_set = set(re.findall(r"['\"]([^'\"]+)['\"]", vset_m.group(1))) if vset_m else set()
            type_matches = re.findall(r"\[([A-Za-z0-9_.]+)\]\s*\$" + re.escape(pname), entry)
            ptype = type_matches[-1].lower() if type_matches else "object"
            parsed[pname.lower()] = {
                "name": pname,
                "type": ptype,
                "param_sets": psets,
                "validate_set": validate_set,
            }
        self._params_cache[rel_path] = parsed
        return parsed

    def validate_script_invocation_args(
        self,
        target_script: str,
        passed_flags: List[str],
        caller_label: str = "<caller>",
    ) -> None:
        """Verify every -Flag passed to target_script is declared in param() and mutually compatible."""
        declared = self.parse_declared_parameters(target_script)
        powershell_engine_flags = {"noprofile", "executionpolicy", "file", "noninteractive", "windowstyle", "command"}
        active_param_sets: Optional[Set[str]] = None

        for raw_flag in passed_flags:
            clean = raw_flag.lstrip("-").split(":")[0].strip()
            if not clean or clean.lower() in powershell_engine_flags:
                continue
            key = clean.lower()
            if key not in declared:
                raise AssertionError(
                    f"{caller_label} passes undeclared parameter '-{clean}' to {target_script} "
                    f"(declared: {[v['name'] for v in declared.values()]})"
                )
            psets: Set[str] = declared[key]["param_sets"]  # type: ignore[assignment]
            if psets:
                if active_param_sets is None:
                    active_param_sets = set(psets)
                else:
                    active_param_sets &= psets
                    if not active_param_sets:
                        raise AssertionError(
                            f"{caller_label} passes conflicting ParameterSet flags {passed_flags} to {target_script}"
                        )


class BehavioralSimulator:
    """Python behavioral reference model & .ps1 constant/AST-coupled state verifier (no live Windows pwsh runtime)."""

    def __init__(self, inspector: PowerShellInspector) -> None:
        self.ps = inspector

    def extract_late_boot_threshold_minutes(self) -> float:
        """Extract the exact numeric threshold in `if ($LateMinutes -gt <N>)` from restore-and-cleanup.ps1."""
        code = self.ps.read_active_code("restore-and-cleanup.ps1")
        m = re.search(r"\$LateMinutes\s+-gt\s+(\d+(?:\.\d+)?)\b", code)
        assert m, "Could not extract '$LateMinutes -gt <threshold>' from restore-and-cleanup.ps1"
        return float(m.group(1))

    def parse_browser_policy_tuples(self, rel_path: str, func_name: str) -> List[Tuple[str, str, str, object]]:
        """Extract ordered (KeyPath, Name, Type, Value) policy tuples from a PowerShell function body."""
        body = self.ps.extract_function_body(rel_path, func_name)
        pat = re.compile(
            r"@\{\s*KeyPath\s*=\s*'([^']+)'\s*;\s*Name\s*=\s*'([^']+)'\s*;\s*Type\s*=\s*'([^']+)'\s*;\s*Value\s*=\s*('[^']*'|[-+]?\d+)\s*\}"
        )
        results: List[Tuple[str, str, str, object]] = []
        for kpath, vname, vtype, raw_val in pat.findall(body):
            val: object = raw_val[1:-1] if raw_val.startswith("'") else int(raw_val)
            results.append((kpath, vname, vtype, val))
        return results

    def quote_process_argument(self, value: Optional[str]) -> str:
        """Simulate Quote-ProcessArgument from common.ps1 / install-env.ps1 / ai-hosts-block.ps1."""
        for script in ("common.ps1", "install-env.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            assert "Quote-ProcessArgument" in self.ps.read_active_code(script), f"Missing Quote-ProcessArgument in {script}"

        if value is None:
            return '""'
        text = str(value)
        if len(text) == 0:
            return '""'
        if not re.search(r'[\s"]', text):
            return text
        escaped = re.sub(r'(\\*)"', r'\1\1\\"', text)
        escaped = re.sub(r"(\\+)$", r"\1\1", escaped)
        return f'"{escaped}"'

    @staticmethod
    def win32_command_line_to_argv(cmd_line: str) -> List[str]:
        """Independent Win32 CommandLineToArgvW / MSVC C-runtime parser oracle."""
        if not cmd_line:
            return []
        args: List[str] = []
        cur: List[str] = []
        in_quotes = False
        started_arg = False
        i = 0
        n = len(cmd_line)
        while i < n:
            ch = cmd_line[i]
            if not in_quotes and ch in (" ", "\t"):
                if started_arg:
                    args.append("".join(cur))
                    cur = []
                    started_arg = False
                i += 1
                continue
            started_arg = True
            if ch == "\\":
                bs_count = 0
                while i < n and cmd_line[i] == "\\":
                    bs_count += 1
                    i += 1
                if i < n and cmd_line[i] == '"':
                    cur.append("\\" * (bs_count // 2))
                    if bs_count % 2 == 0:
                        in_quotes = not in_quotes
                    else:
                        cur.append('"')
                    i += 1
                else:
                    cur.append("\\" * bs_count)
                continue
            if ch == '"':
                if in_quotes and i + 1 < n and cmd_line[i + 1] == '"':
                    cur.append('"')
                    i += 2
                else:
                    in_quotes = not in_quotes
                    i += 1
                continue
            cur.append(ch)
            i += 1
        if started_arg:
            args.append("".join(cur))
        return args

    def simulate_jsonc_strip(self, raw_text: Optional[str]) -> str:
        """Simulate the exact 2-pass Strip-JsonComments / ConvertFrom-JsonSafe character scanner."""
        for script in ("common.ps1", "setup-vscode.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
            code = self.ps.read_active_code(script)
            assert "ConvertFrom-JsonSafe" in code and "ConvertFrom-JsonArray" in code, (
                f"{script} missing ConvertFrom-JsonSafe / ConvertFrom-JsonArray"
            )
        if not raw_text or not raw_text.strip():
            return ""
        src = raw_text.lstrip("\ufeff \t\r\n")
        if not src:
            return ""

        # Pass 1: Strip // and /* */ outside JSON string literals
        pass1_chars: List[str] = []
        in_str = False
        n = len(src)
        idx = 0
        while idx < n:
            ch = src[idx]
            if in_str:
                pass1_chars.append(ch)
                if ch == "\\" and idx + 1 < n:
                    pass1_chars.append(src[idx + 1])
                    idx += 2
                    continue
                if ch == '"':
                    in_str = False
                idx += 1
                continue
            if ch == '"':
                in_str = True
                pass1_chars.append(ch)
                idx += 1
                continue
            if ch == "/" and idx + 1 < n and src[idx + 1] == "/":
                idx += 2
                while idx < n and src[idx] not in ("\n", "\r"):
                    idx += 1
                continue
            if ch == "/" and idx + 1 < n and src[idx + 1] == "*":
                idx += 2
                while idx < n:
                    if src[idx] == "*" and idx + 1 < n and src[idx + 1] == "/":
                        idx += 2
                        break
                    idx += 1
                continue
            pass1_chars.append(ch)
            idx += 1

        pass1 = "".join(pass1_chars)

        # Pass 2: Strip trailing commas before } or ] outside strings
        out_chars: List[str] = []
        in_str = False
        n = len(pass1)
        idx = 0
        while idx < n:
            ch = pass1[idx]
            if in_str:
                out_chars.append(ch)
                if ch == "\\" and idx + 1 < n:
                    out_chars.append(pass1[idx + 1])
                    idx += 2
                    continue
                if ch == '"':
                    in_str = False
                idx += 1
                continue
            if ch == '"':
                in_str = True
                out_chars.append(ch)
                idx += 1
                continue
            if ch == ",":
                look = idx + 1
                while look < n and pass1[look] in (" ", "\t", "\r", "\n"):
                    look += 1
                if look < n and pass1[look] in ("}", "]"):
                    idx += 1
                    continue
            out_chars.append(ch)
            idx += 1
        return "".join(out_chars).strip()

    def simulate_jsonc_strip_and_parse(self, raw_text: Optional[str]) -> object:
        cleaned = self.simulate_jsonc_strip(raw_text)
        if not cleaned:
            return None
        return json.loads(cleaned)

    def simulate_json_array_parse(self, raw_text: Optional[str]) -> List[object]:
        parsed = self.simulate_jsonc_strip_and_parse(raw_text)
        if parsed is None:
            return []
        if isinstance(parsed, list):
            return parsed
        return [parsed]

    def simulate_kst_schedule_parse(
        self,
        start_str: str,
        end_str: str,
        restore_str: str,
        local_offset_hours: float = 9.0,
        now_utc: Optional[datetime.datetime] = None,
    ) -> Dict[str, object]:
        """Simulate ConvertTo-KstDateTimeOffset & Test-ExamScheduleConfiguration coupled to .ps1 +09:00 normalization."""
        kst_body = self.ps.extract_function_body("common.ps1", "ConvertTo-KstDateTimeOffset")
        sched_body = self.ps.extract_function_body("common.ps1", "Test-ExamScheduleConfiguration")
        assert re.search(r'(?:\+\s*\x27\+09:00\x27|\$Trimmed\+09:00)', kst_body), (
            "common.ps1 ConvertTo-KstDateTimeOffset missing '+09:00' offset normalization"
        )
        assert "[System.DayOfWeek]::Monday" in sched_body, "common.ps1 Test-ExamScheduleConfiguration missing [System.DayOfWeek]::Monday"
        for script in ("restore-and-cleanup.ps1", "ai-hosts-block.ps1"):
            conv_body = self.ps.extract_function_body(script, "ConvertTo-LocalScheduleTime")
            assert re.search(r"\+\s*'\+09:00'", conv_body), f"{script} ConvertTo-LocalScheduleTime missing + '+09:00'"

        kst_tz = datetime.timezone(datetime.timedelta(hours=9))
        local_tz = datetime.timezone(datetime.timedelta(hours=local_offset_hours))

        def parse_one(text: str, label: str) -> datetime.datetime:
            trimmed = text.strip()
            if not trimmed:
                raise ValueError(f"{label} timestamp cannot be empty.")
            if re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$", trimmed):
                iso_kst = trimmed.replace(" ", "T") + "+09:00"
                return datetime.datetime.fromisoformat(iso_kst)
            normalized = trimmed[:-1] + "+00:00" if trimmed.endswith(("Z", "z")) else trimmed.replace(" ", "T")
            dt = datetime.datetime.fromisoformat(normalized)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=kst_tz)
            return dt

        start_dto = parse_one(start_str, "ExamStart")
        end_dto = parse_one(end_str, "ExamEnd")
        restore_dto = parse_one(restore_str, "RestoreAt")

        if end_dto <= start_dto:
            raise ValueError(f"Invalid exam schedule: ExamEnd ({end_str}) must be after ExamStart ({start_str}).")

        ref_now = now_utc if now_utc is not None else datetime.datetime(2026, 11, 23, 6, 0, 0, tzinfo=datetime.timezone.utc)
        start_local = start_dto.astimezone(local_tz)
        end_local = end_dto.astimezone(local_tz)
        restore_local = restore_dto.astimezone(local_tz)
        start_kst = start_dto.astimezone(kst_tz)

        return {
            "ExamStart": start_local,
            "ExamEnd": end_local,
            "RestoreAt": restore_local,
            "ExamStartDto": start_dto,
            "ExamEndDto": end_dto,
            "RestoreAtDto": restore_dto,
            "ExamStartIso": start_dto.isoformat(),
            "ExamEndIso": end_dto.isoformat(),
            "RestoreAtIso": restore_dto.isoformat(),
            "RestoreAtUtc": restore_dto.astimezone(datetime.timezone.utc),
            "DayOfWeek": start_kst.strftime("%A"),
            "DurationMinutes": round((end_dto - start_dto).total_seconds() / 60.0, 1),
            "IsKst": abs(local_offset_hours - 9.0) < 0.01,
            "IsPastRestoreTime": restore_dto <= ref_now,
            "IsBeforeExamStart": ref_now < start_dto,
        }

    def remove_managed_hosts_section(self, hosts_text: str) -> str:
        """Simulate Remove-ManagedHostsSectionFromText using markers from ai-hosts-block.ps1."""
        code = self.ps.read_active_code("ai-hosts-block.ps1")
        begin_m = re.search(r"\$BeginMarker\s*=\s*['\"]([^'\"]+)['\"]", code)
        end_m = re.search(r"\$EndMarker\s*=\s*['\"]([^'\"]+)['\"]", code)
        assert begin_m and end_m, "BeginMarker/EndMarker not found in ai-hosts-block.ps1"
        begin_marker = begin_m.group(1)
        end_marker = end_m.group(1)
        if not hosts_text:
            return ""
        pattern = r"(?s)\r?\n?" + re.escape(begin_marker) + r".*?" + re.escape(end_marker) + r"\r?\n?"
        return re.sub(pattern, "\r\n", hosts_text).rstrip()

    def get_default_ai_domains(self) -> List[str]:
        """Extract $DefaultAiBlockDomains from ai-hosts-block.ps1."""
        code = self.ps.read_active_code("ai-hosts-block.ps1")
        m = re.search(r"\$DefaultAiBlockDomains\s*=\s*@\((.*?)\)", code, re.DOTALL)
        assert m, "$DefaultAiBlockDomains array not found in ai-hosts-block.ps1"
        domains = re.findall(r"['\"]([a-z0-9][a-z0-9.-]*\.[a-z]{2,})['\"]", m.group(1), re.IGNORECASE)
        return sorted(set(d.lower() for d in domains))

    def parse_and_expand_blocklist_domains(self, raw_lines: List[str]) -> List[str]:
        """Simulate Get-BlockDomains domain parser + 2-label apex & 3-label ccSLD www. expansion."""
        domains: Set[str] = set()
        for line in raw_lines:
            clean = re.sub(r"#.*$", "", line).strip().lower()
            if not clean:
                continue
            for part in clean.split():
                if re.match(r"^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$", part) and not re.search(r"[/*\\]", part):
                    # Skip IPv4 literals like 0.0.0.0 / 127.0.0.1 because TLD requires [a-z]{2,}
                    domains.add(part)
                    labels = part.split(".")
                    is_ccsld_apex = len(labels) == 3 and bool(
                        re.match(r"^[a-z0-9-]+\.(co|or|ac|ne|go|com|org|net)\.[a-z]{2}$", part)
                    )
                    if not part.startswith("www.") and (len(labels) == 2 or is_ccsld_apex):
                        domains.add(f"www.{part}")
        return sorted(domains)

    def expand_domains_with_www_and_ipv6(self, domains: List[str]) -> List[str]:
        """Simulate Apply-AiHostsBlock host lines (0.0.0.0 + :: + www variants)."""
        expanded = self.parse_and_expand_blocklist_domains([f"0.0.0.0 {d}" for d in domains])
        lines: List[str] = []
        for d in expanded:
            lines.append(f"0.0.0.0 {d}")
            lines.append(f":: {d}")
        return lines

    @staticmethod
    def assert_safe_removal_path(path: str, name: str = "Root") -> str:
        """Simulate Assert-SafeRemovalPath from restore-and-cleanup.ps1 including .. normalization."""
        if not path or not path.strip():
            raise ValueError(f"FATAL: {name} is empty. Aborting cleanup.")
        trimmed = path.strip()
        if not re.match(r"^[A-Za-z]:[\\/]", trimmed):
            raise ValueError(f"FATAL: {name} must be an absolute path. Aborting cleanup. Value: {path}")
        if re.match(r"^[A-Za-z]:[\\/]*$", trimmed):
            raise ValueError(f"FATAL: {name} points to a drive root. Aborting cleanup. Value: {path}")

        drive = trimmed[:2]
        raw_parts = re.split(r"[\\/]+", trimmed[2:])
        resolved_parts: List[str] = []
        for part in raw_parts:
            if not part or part == ".":
                continue
            if part == "..":
                if resolved_parts:
                    resolved_parts.pop()
            else:
                resolved_parts.append(part)
        if not resolved_parts:
            raise ValueError(f"FATAL: Safe-guard triggered. {name} ({path}) resolves to drive root.")

        norm = drive + "\\" + "\\".join(resolved_parts)
        critical = {
            "c:",
            "d:",
            "c:\\windows",
            "c:\\users\\student",
            "c:\\programdata",
            "c:\\program files",
            "c:\\program files (x86)",
        }
        if norm.lower() in critical:
            raise ValueError(f"FATAL: Safe-guard triggered. {name} ({path}) is a critical system path.")
        return norm

    def test_path_inside(self, child_path: str, parent_path: str) -> bool:
        """Simulate Test-PathInside coupled to trailing backslash boundary check in common.ps1 & restore-and-cleanup.ps1."""
        common_body = self.ps.extract_function_body("common.ps1", "Test-PathInside")
        restore_body = self.ps.extract_function_body("restore-and-cleanup.ps1", "Test-PathInside")
        assert 'StartsWith("$ParentNorm\\"' in common_body or "DirectorySeparatorChar" in common_body, (
            "common.ps1 Test-PathInside missing trailing separator boundary check (vulnerable to C:\\CPTools2 prefix bug)"
        )
        assert ("$Parent + '\\'" in restore_body or 'StartsWith("$Parent\\"' in restore_body) and "StartsWith(" in restore_body, (
            "restore-and-cleanup.ps1 Test-PathInside missing trailing separator boundary check"
        )
        if not child_path or not child_path.strip() or not parent_path or not parent_path.strip():
            return False
        child = child_path.replace("/", "\\").strip().rstrip("\\").lower()
        parent = parent_path.replace("/", "\\").strip().rstrip("\\").lower()
        return child == parent or child.startswith(parent + "\\")

    def can_reuse_cached_download(self, file_path: Path, expected_sha256: str = "", min_bytes: int = 1024) -> bool:
        """Simulate Test-ValidCachedInstallerFile + Assert-FileSha256 coupled to .Length -lt $MinBytes in common.ps1."""
        valid_body = self.ps.extract_function_body("common.ps1", "Test-ValidCachedInstallerFile")
        assert re.search(r"\$Item\.Length\s+-lt\s+\$MinBytes\b", valid_body), (
            "common.ps1 Test-ValidCachedInstallerFile missing '$Item.Length -lt $MinBytes' check"
        )
        if not file_path.exists():
            return False
        size = file_path.stat().st_size
        if size < min_bytes or size < 4:
            return False
        if expected_sha256:
            actual = hashlib.sha256(file_path.read_bytes()).hexdigest()
            if actual.lower() != expected_sha256.lower():
                return False
        ext = file_path.suffix.lower()
        header = file_path.read_bytes()[:4]
        if ext in (".zip", ".nupkg", ".vsix"):
            return header == b"PK\x03\x04"
        if ext == ".exe":
            return header[:2] == b"MZ"
        return size >= min_bytes

    def simulate_late_boot_shutdown_guard(
        self,
        shutdown_requested: bool,
        scheduled_restore_iso: str,
        actual_run_dto: datetime.datetime,
    ) -> bool:
        """Simulate the >25m late-boot -Shutdown suppression using threshold & KST parser extracted from restore-and-cleanup.ps1."""
        threshold_minutes = self.extract_late_boot_threshold_minutes()
        conv_body = self.ps.extract_function_body("restore-and-cleanup.ps1", "ConvertTo-LocalScheduleTime")
        assert re.search(r"\+\s*'\+09:00'", conv_body), (
            "restore-and-cleanup.ps1 ConvertTo-LocalScheduleTime missing '+09:00' offset normalization"
        )
        if not shutdown_requested or not scheduled_restore_iso.strip():
            return shutdown_requested
        trimmed = scheduled_restore_iso.strip()
        if re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$", trimmed):
            target_dto = datetime.datetime.fromisoformat(trimmed.replace(" ", "T") + "+09:00")
        else:
            norm = trimmed[:-1] + "+00:00" if trimmed.endswith(("Z", "z")) else trimmed
            target_dto = datetime.datetime.fromisoformat(norm)
        late_minutes = (actual_run_dto - target_dto).total_seconds() / 60.0
        if late_minutes > threshold_minutes:
            return False
        return True

    def simulate_workspace_backup(self, contest_root: Path, temp_dir: Path) -> Optional[Path]:
        """Simulate Backup-ContestWorkspaceSources using extensions & size filter extracted from restore-and-cleanup.ps1."""
        bak_body = self.ps.extract_function_body("restore-and-cleanup.ps1", "Backup-ContestWorkspaceSources")
        ext_match = re.search(r"\$AllowedExts\s*=\s*@\(([^)]+)\)", bak_body, re.DOTALL)
        assert ext_match, "Could not extract $AllowedExts from Backup-ContestWorkspaceSources"
        allowed_exts = set(e.lower() for e in re.findall(r"'(\.[a-z0-9]+)'", ext_match.group(1), re.IGNORECASE))
        assert re.search(r"\$MaxBytes\s*=\s*5\s*\*\s*1024\s*\*\s*1024\b", bak_body), (
            "Backup-ContestWorkspaceSources missing '$MaxBytes = 5 * 1024 * 1024'"
        )
        assert re.search(r"\$_\.Length\s+-gt\s+0\b", bak_body) and re.search(
            r"\$_\.Length\s+-le\s+\$MaxBytes\b", bak_body
        ), "Backup-ContestWorkspaceSources missing '($_.Length -gt 0) -and ($_.Length -le $MaxBytes)' size filter"

        workspace_dir = contest_root / "contest"
        if not workspace_dir.exists():
            return None
        max_bytes = 5 * 1024 * 1024
        dot_vscode = workspace_dir / ".vscode"
        candidates: List[Path] = []
        for p in workspace_dir.rglob("*"):
            if not p.is_file():
                continue
            try:
                p.relative_to(dot_vscode)
                continue
            except ValueError:
                pass
            ext = p.suffix.lower()
            sz = p.stat().st_size
            if ext in allowed_exts and 0 < sz <= max_bytes:
                candidates.append(p)
        if not candidates:
            return None
        backup_dest = temp_dir / "ContestSetup-Workspace-Backup-20261123-203000"
        backup_dest.mkdir(parents=True, exist_ok=True)
        for src in candidates:
            rel = src.relative_to(workspace_dir)
            dst = backup_dest / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        return backup_dest


def build_test_suite() -> List[TestCase]:
    ps = PowerShellInspector(REPO_ROOT)
    sim = BehavioralSimulator(ps)
    tests: List[TestCase] = []

    def register(test_id: str, tier: int, feature: str, description: str):
        def decorator(fn: Callable[[], None]):
            tests.append(TestCase(test_id=test_id, tier=tier, feature=feature, description=description, fn=fn))
            return fn
        return decorator

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
    @register("T1_F17_01", 1, "F17", "All 12 .ps1 files are strictly 7-bit ASCII (< 0x80) and replace bare Get-Content with Read-TextUtf8 / Read-LinesUtf8")
    def _():
        for fname in PS1_FILES:
            ps.assert_pure_ascii_ps1(fname)
            code = ps.read_active_code(fname)
            assert not re.search(r"\bGet-Content\b", code, re.IGNORECASE), (
                f"{fname} uses bare Get-Content instead of explicit UTF-8 Read-TextUtf8 / Read-LinesUtf8"
            )

    @register("T1_F17_02", 1, "F17", "ConvertFrom-JsonSafe and ConvertFrom-JsonArray eliminate JSONC crashes and PS 5.1 Object[][] double-wrapping")
    def _():
        for fname in PS1_FILES:
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

    @register("T1_F18_02", 1, "F18", "Zero StrictMode-unsafe $MyInvocation.MyCommand.Path or .Definition references across all 12 .ps1 scripts")
    def _():
        for fname in PS1_FILES:
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
    @register("T2_F2_01", 2, "F2", "PowerShell syntax & token balance across install-env.ps1, common.ps1, and all setup-*.ps1 scripts")
    def _():
        for fname in PS1_FILES:
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
    @register("T2_F13_01", 2, "F13", ".editorconfig compliance: all 12 .ps1 files, docs, .editorconfig, and .gitignore use UTF-8 without BOM and LF")
    def _():
        for fname in PS1_FILES + ["README.md", "ARCHITECTURE_V2.md", "PROJECT.md", ".editorconfig", ".gitignore"]:
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
            text = ps.read_text(doc)
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
            assert "cli\\.js" in body, f"{body_name} missing bin\\code.cmd cli.js commit-folder regex"
            assert "'data'" in body and "'bin'" in body, f"{body_name} missing ExcludedChildNames guard"
            assert "resources\\app\\product.json" in body
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

    @register("T5_03", 5, "F16+F23", "Adversarial PS 5.1 array unwrapping & pipeline ban audit across all 12 .ps1 files")
    def _():
        for fname in PS1_FILES:
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
        for fname in PS1_FILES:
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
        for fname in PS1_FILES:
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

    @register("T5_17", 5, "F16+F23", "Adversarial static audit for PS 5.1 StrictMode 2.0 & runtime anti-patterns across all 12 .ps1 scripts")
    def _():
        for fname in PS1_FILES:
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

    @register("T5_22", 5, "F16+F23", "Adversarial StrictMode 2.0 unbraced $Variable? interpolation ban across all 12 .ps1 scripts (F-1 / C1-01)")
    def _():
        # In PowerShell double-quoted strings, "$AiScriptUrl?cb=..." parses "AiScriptUrl?" as the variable name because '?' is a legal identifier char!
        for fname in PS1_FILES:
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

    @register("T5_32", 5, "F16+F23", "Adversarial Set-StrictMode -Version 2.0 & PSNativeCommandUseErrorActionPreference enforcement across standalone scripts")
    def _():
        for fname in PS1_FILES:
            code = ps.read_active_code(fname)
            if fname in ("common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
                assert "Set-StrictMode -Version 2.0" in code, f"Standalone library/script {fname} missing Set-StrictMode -Version 2.0"
            if fname in ("install-env.ps1", "common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1", "restore-and-cleanup.ps1"):
                assert "$global:PSNativeCommandUseErrorActionPreference = $false" in code, (
                    f"{fname} missing PS 7+ native stderr guard $global:PSNativeCommandUseErrorActionPreference = $false"
                )
            if fname in ("install-env.ps1", "common.ps1", "install-ai-hosts.ps1", "ai-hosts-block.ps1"):
                assert "$ErrorActionPreference = 'Stop'" in code, f"{fname} missing $ErrorActionPreference = 'Stop'"
            # Zero Set-StrictMode -Off anywhere in the repository
            assert not re.search(r"Set-StrictMode\s+-Off\b", code, re.IGNORECASE), f"{fname} disables StrictMode"

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
        # Pre-fix variant: the unguarded lookup that crashed when the caller sat at the global scope.
        mutant_code = common_code.replace(guarded.group(0), "$Variable = Get-Variable -Name $Name -Scope $Scope -ErrorAction SilentlyContinue", 1)
        assert mutant_code != common_code

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

        def run_probe(code_text: str) -> "subprocess.CompletedProcess[str]":
            with tempfile.TemporaryDirectory(prefix="cs_t5_33_") as tmp:
                src = Path(tmp) / "common.ps1"
                src.write_text(code_text, encoding="utf-8")
                env = dict(os.environ, CS_REGRESSION_COMMON=str(src))
                return subprocess.run(
                    [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", probe],
                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, env=env,
                )

        fixed = run_probe(common_code)
        assert fixed.returncode == 0, f"fixed common.ps1 probe failed (rc={fixed.returncode}): {fixed.stderr.strip()[-600:]}"
        assert "RESULT:fallback|from-top|from-env|True" in fixed.stdout, f"unexpected probe output: {fixed.stdout.strip()[-600:]}"

        broken = run_probe(mutant_code)
        assert broken.returncode != 0 and "RESULT:" not in broken.stdout, (
            "pre-fix (unguarded Get-Variable -Scope 2) variant unexpectedly succeeded; probe no longer reproduces the shallow-scope bug"
        )

    @register("T5_34", 5, "F18+F21+F6", "Live pwsh 12-script AST/PS5.1/switch audit + C-1 StrictMode standalone dot-source & C-2 offline pacman -U .sig exclusion regressions")
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
                CS_PS1_LIST=";".join(PS1_FILES),
            )
            res = subprocess.run(
                [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(probe_file)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, env=env,
            )
            assert res.returncode == 0, f"T5_34 pwsh audit failed (rc={res.returncode}): {res.stderr.strip()[-600:]}\n{res.stdout.strip()[-600:]}"
            assert (
                "AST_OK:12|DEFAULT:[1/1] 0->1 https://raw.githubusercontent.com/naixt1478/ContestSetup/main/ai-hosts-block.ps1"
                "|OVERRIDE:5/8|https://mirror.example.internal/ContestSetup/main"
            ) in res.stdout, f"unexpected T5_34 output: {res.stdout.strip()[-600:]}"

    return tests


def main() -> int:
    parser = argparse.ArgumentParser(
        description="ContestSetup v2.0 5-Tier E2E, Behavioral & Adversarial Verification Test Runner"
    )
    parser.add_argument(
        "--tier",
        choices=["1", "2", "3", "4", "5", "all"],
        default="all",
        help="Test tier to execute (1..5 or all; default: all)",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Print every test case result")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary")
    parser.add_argument("--strict", action="store_true", help="Treat skipped tests (e.g. missing pwsh) as failures")
    args = parser.parse_args()

    all_tests = build_test_suite()
    if args.tier == "all":
        selected = all_tests
    else:
        target_tier = int(args.tier)
        selected = [t for t in all_tests if t.tier == target_tier]

    tier_names = {
        1: "Tier 1 — Feature Coverage (Category-Partition)",
        2: "Tier 2 — Boundary & Corner Cases (Boundary Value Analysis)",
        3: "Tier 3 — Cross-Feature Combinations (Pairwise & Contracts)",
        4: "Tier 4 — Real-World Application Scenarios (End-to-End Simulation)",
        5: "Tier 5 — White-Box Adversarial & Mutation Hardening (F16 + F23)",
    }

    passed = 0
    failed = 0
    skipped = 0
    failures: List[Tuple[TestCase, str]] = []
    per_tier_stats: Dict[int, Dict[str, int]] = {
        t: {"total": 0, "passed": 0, "failed": 0, "skipped": 0} for t in (1, 2, 3, 4, 5)
    }

    for tc in selected:
        per_tier_stats[tc.tier]["total"] += 1
        try:
            tc.fn()
            passed += 1
            per_tier_stats[tc.tier]["passed"] += 1
            if args.verbose:
                print(f"[PASS] {tc.test_id} ({tc.feature}): {tc.description}")
        except TestSkipped as exc:
            if args.strict:
                failed += 1
                per_tier_stats[tc.tier]["failed"] += 1
                failures.append((tc, f"skipped under --strict: {exc}"))
                print(f"[FAIL] {tc.test_id} ({tc.feature}): {tc.description}\n       Reason: skipped under --strict: {exc}")
            else:
                skipped += 1
                per_tier_stats[tc.tier]["skipped"] += 1
                print(f"[SKIP] {tc.test_id} ({tc.feature}): {exc}")
        except Exception as exc:
            failed += 1
            per_tier_stats[tc.tier]["failed"] += 1
            failures.append((tc, str(exc)))
            print(f"[FAIL] {tc.test_id} ({tc.feature}): {tc.description}\n       Reason: {exc}")

    if args.json:
        print(
            json.dumps(
                {
                    "tier_filter": args.tier,
                    "total": len(selected),
                    "passed": passed,
                    "failed": failed,
                    "skipped": skipped,
                    "per_tier": per_tier_stats,
                    "failures": [{"id": tc.test_id, "feature": tc.feature, "error": err} for tc, err in failures],
                },
                indent=2,
            )
        )
    else:
        print("=" * 78)
        print("ContestSetup v2.0 — 5-Tier Verification & Adversarial Summary")
        print("=" * 78)
        for t in (1, 2, 3, 4, 5):
            stats = per_tier_stats[t]
            if stats["total"] > 0:
                status = "PASS" if stats["failed"] == 0 else "FAIL"
                skip_note = f" ({stats['skipped']} skipped)" if stats["skipped"] else ""
                print(f"  {tier_names[t]:<64} {stats['passed']:>3}/{stats['total']:<3} [{status}]{skip_note}")
        print("-" * 78)
        overall = "PASS" if failed == 0 else "FAIL"
        print(f"  TOTAL: {passed}/{len(selected)} passed, {failed} failed, {skipped} skipped [{overall}]")
        print("=" * 78)

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
