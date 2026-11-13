"""
Lexical, structural, AST-contract, and module-aware analyzer for PowerShell (.ps1) scripts.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from . import PS1_FILES


class PowerShellInspector:
    """Lexical, structural, AST-contract, and function-level analyzer for PowerShell (.ps1) scripts."""

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self._raw_cache: Dict[str, str] = {}
        self._bytes_cache: Dict[str, bytes] = {}
        self._effective_cache: Dict[str, str] = {}
        self._active_cache: Dict[str, str] = {}
        self._params_cache: Dict[str, Dict[str, Dict[str, object]]] = {}

    def lib_ps1_files(self) -> List[str]:
        """Dynamically discover all `lib/*.ps1` module files relative to `repo_root`."""
        lib_dir = self.repo_root / "lib"
        if not lib_dir.is_dir():
            return []
        return sorted(
            str(p.relative_to(self.repo_root).as_posix())
            for p in lib_dir.glob("*.ps1")
            if p.is_file()
        )

    def all_ps1_files(self) -> List[str]:
        """Return root `PS1_FILES` plus any discovered `lib/*.ps1` modules."""
        return list(PS1_FILES) + self.lib_ps1_files()

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

    def _expand_effective_text(self, rel_path: str, visited: Set[str]) -> str:
        raw_text = self.read_text(rel_path)
        import_pat = re.compile(
            r"^[ \t]*Import-ContestLibraryModule\b[^\r\n]*?(?:-ModuleName\s+)?['\"]([^'\"]+)['\"][^\r\n]*$",
            re.MULTILINE,
        )
        out_chunks: List[str] = []
        for line in raw_text.splitlines(keepends=True):
            out_chunks.append(line)
            m = import_pat.match(line.rstrip("\r\n"))
            if m:
                mod_name = m.group(1).strip().replace("\\", "/")
                mod_rel = mod_name if mod_name.startswith("lib/") else f"lib/{mod_name}"
                mod_full = self.repo_root / mod_rel
                if mod_rel not in visited and mod_full.is_file():
                    visited.add(mod_rel)
                    inlined = self._expand_effective_text(mod_rel, visited)
                    out_chunks.append(f"\n# --- BEGIN INLINED {mod_rel} ---\n")
                    out_chunks.append(inlined)
                    if not inlined.endswith("\n"):
                        out_chunks.append("\n")
                    out_chunks.append(f"# --- END INLINED {mod_rel} ---\n")
        return "".join(out_chunks)

    def read_effective_text(self, rel_path: str) -> str:
        """Return PowerShell source with `Import-ContestLibraryModule` modules expanded inline (cycle-safe)."""
        if rel_path not in self._effective_cache:
            self._effective_cache[rel_path] = self._expand_effective_text(rel_path, {rel_path})
        return self._effective_cache[rel_path]

    def read_active_code(self, rel_path: str) -> str:
        """Return effective PowerShell source with comments stripped (preserving strings and here-strings)."""
        if rel_path not in self._active_cache:
            text = self.read_effective_text(rel_path)
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
    def _extract_single_body(cls, code: str, match_end: int, func_name: str, label: str) -> str:
        brace_start = code.find("{", match_end)
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

    @classmethod
    def extract_function_body_from_source(cls, raw_source: str, func_name: str, label: str = "<source>") -> str:
        """Extract `function <func_name> { ... }` accurately handling strings, comments, here-strings, and fallback stubs."""
        code = cls.strip_comments(raw_source)
        pattern = re.compile(rf"\bfunction\s+{re.escape(func_name)}\b", re.IGNORECASE)
        matches = list(pattern.finditer(code))
        if not matches:
            raise AssertionError(f"Function '{func_name}' not found in {label}")
        bodies = [cls._extract_single_body(code, m.end(), func_name, label) for m in matches]
        return max(bodies, key=len)

    def extract_function_body(self, rel_path: str, func_name: str) -> str:
        """Extract the body of `function <func_name> { ... }` from a PowerShell file (including imported `lib/` modules)."""
        return self.extract_function_body_from_source(self.read_effective_text(rel_path), func_name, rel_path)

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
