"""
Python behavioral reference model & .ps1 constant/AST-coupled state verifier.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import re
import shutil
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from .inspector import PowerShellInspector


class BehavioralSimulator:
    """Python behavioral reference model & .ps1 constant/AST-coupled state verifier."""

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
        if not results and func_name != "Get-BrowserPolicySpecifications" and "Get-BrowserPolicySpecifications" in body:
            return self.parse_browser_policy_tuples(rel_path, "Get-BrowserPolicySpecifications")
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
        assert (
            "$Parent + '\\'" in restore_body
            or 'StartsWith("$Parent\\"' in restore_body
            or 'StartsWith("$ParentNorm\\"' in restore_body
        ) and "StartsWith(" in restore_body, (
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
