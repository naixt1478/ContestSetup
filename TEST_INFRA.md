# Test Infrastructure — ContestSetup v2.0 (Round 2 5-Tier Suite)

## Overview
- **Project**: ContestSetup v2.0 (Modular, Idempotent, Classroom-Scale Windows PowerShell Provisioning & Anti-Cheat Suite for the **Monday, 2026-11-23 19:00–20:30 KST** Exam)
- **Test Runner**: `python3 -B tests/run_tests.py`
- **Supported CLI Flags**: `--tier 1|2|3|4|5|all` (default: `all`), `--verbose`, `--json`
- **Verification Engine**: Hybrid PowerShell AST/Lexical/Parameter-Set Contract Inspector (`PowerShellInspector`) + Python Behavioral Reference Model & `.ps1` Constant/AST-Coupled State Verifier (`BehavioralSimulator`) + optional live `pwsh` regression probes (`T5_33`, `T5_34`; skipped when no `pwsh` is found, failed under `--strict`) + White-Box Adversarial & Mutation Hardening Suite (`--tier 5`). Every test inspects the actual `.ps1` scripts, `README.md`, `ARCHITECTURE_V2.md`, `PROJECT.md`, `.editorconfig`, and `.gitignore` in the repository root and executes deterministic behavioral simulations against isolated temporary directory trees using thresholds, domain lists, and policy tuples extracted directly from `.ps1` code.

---

## Feature Inventory (`F1`–`F23`)

| # | Feature | Source | Tier 1 Tests (Feature Coverage) | Tier 2 Tests (Boundary & Corner) | Tier 3 Tests (Cross-Feature) | Tier 4 Tests (Real-World Scenarios) | Tier 5 Tests (White-Box Adversarial) |
|---|---------|--------|---------------------------------|----------------------------------|------------------------------|-------------------------------------|--------------------------------------|
| F1 | **Exam Schedule Alignment (`2026-11-23` Mon `19:00`–`20:30` KST)** | `PROJECT.md` | `T1_F1_01`–`05` (5) | `T2_F1_01`–`05` (5) | `T3_01`, `T3_08`, `T3_15`, `T3_27`, `T3_31`, `T3_34` | `T4_01`, `T4_06`, `T4_08`, `T4_16` | `T5_10`, `T5_20` |
| F2 | **Hybrid Local-First + Staged Module Loader (`install-env.ps1`)** | `PROJECT.md` | `T1_F2_01`–`05` (5) | `T2_F2_01`–`05` (5) | `T3_01`, `T3_02`, `T3_12`, `T3_19`, `T3_30` | `T4_01`, `T4_05`, `T4_11` | `T5_01`, `T5_05`, `T5_06`, `T5_17`, `T5_29` |
| F3 | **Lifecycle Modes (`Install`, `Verify`, `Status`, `DryRun`, `Restore`, `ExportCache`)** | `PROJECT.md` | `T1_F3_01`–`05` (5) | `T2_F3_01`–`05` (5) | `T3_01`, `T3_03`, `T3_14`, `T3_22`, `T3_26`, `T3_32` | `T4_01`, `T4_09`, `T4_11`, `T4_14` | `T5_11` |
| F4 | **Non-Destructive Failure Handling & Log/Cache Preservation (`S-02`)** | `PROJECT.md` | `T1_F4_01`–`05` (5) | `T2_F4_01`–`05` (5) | `T3_04`, `T3_14` | `T4_10` | `T5_11` |
| F5 | **Parallel Download Prefetcher & Smart Cache Reuse (`O5`, `S-16`)** | `PROJECT.md` | `T1_F5_01`–`05` (5) | `T2_F5_01`–`05` (5) | `T3_02`, `T3_05`, `T3_13` | `T4_01`, `T4_05`, `T4_11` | `T5_16`, `T5_25` |
| F6 | **Fast & Self-Healing MSYS2 Provisioning (`S-04`, `S-13`, `O2`–`O4`)** | `PROJECT.md` | `T1_F6_01`–`05` (5) | `T2_F6_01`–`05` (5) | `T3_05`, `T3_07`, `T3_13`, `T3_24`, `T3_32` | `T4_01`, `T4_03`, `T4_11` | `T5_18`, `T5_34` |
| F7 | **Conflict-Free Python 3.10 Provisioning (`S-03`)** | `PROJECT.md` | `T1_F7_01`–`05` (5) | `T2_F7_01`–`05` (5) | `T3_06`, `T3_07`, `T3_14` | `T4_01`, `T4_04`, `T4_06` | `T5_15` |
| F8 | **Opt-In Visual Studio 2022 & `vswhere.exe` Detection (`S-14`, `O1`)** | `PROJECT.md` | `T1_F8_01`–`05` (5) | `T2_F8_01`–`05` (5) | `T3_01`, `T3_12` | `T4_01`, `T4_04` | `T5_17` |
| F9 | **Bulletproof Portable VS Code & Batched Extensions (`S-01`, `O6`, 1.97+ Layout)** | `PROJECT.md` | `T1_F9_01`–`05` (5) | `T2_F9_01`–`05` (5) | `T3_05`, `T3_09`, `T3_10`, `T3_11`, `T3_16`, `T3_29`, `T3_33` | `T4_01`, `T4_02`, `T4_06` | `T5_12`, `T5_13`, `T5_24`, `T5_25`, `T5_30` |
| F10 | **Clean Command Wrappers & Machine/User PATH Precedence (`S-05`, `S-12`)** | `PROJECT.md` | `T1_F10_01`–`05` (5) | `T2_F10_01`–`05` (5) | `T3_07`, `T3_10`, `T3_17` | `T4_01`, `T4_04`, `T4_06` | `T5_14` |
| F11 | **Resilient IPv4+IPv6 AI Hosts Blocking (`S-11`, `S-17`)** | `PROJECT.md` | `T1_F11_01`–`05` (5) | `T2_F11_01`–`05` (5) | `T3_02`, `T3_03`, `T3_08`, `T3_18`, `T3_19`, `T3_30` | `T4_01`, `T4_06`, `T4_07`, `T4_15` | `T5_08`, `T5_21`–`T5_23`, `T5_27` |
| F12 | **Admin-Checked Complete Restoration (`S-07`, `S-10`, `S-15`)** | `PROJECT.md` | `T1_F12_01`–`05` (5) | `T2_F12_01`–`05` (5) | `T3_04`, `T3_06`, `T3_08`, `T3_11`, `T3_16`–`T3_19`, `T3_29`, `T3_30`, `T3_33` | `T4_06`, `T4_07`, `T4_08`, `T4_12`, `T4_13` | `T5_07`, `T5_14`, `T5_15`, `T5_19`, `T5_30` |
| F13 | **JSON Serialization & Shared Helper Deduplication (`S-18`)** | `PROJECT.md` | `T1_F13_01`–`05` (5) | `T2_F13_01`–`05` (5) | `T3_06`, `T3_09`, `T3_13`, `T3_16` | `T4_01`, `T4_02`, `T4_09` | `T5_02`, `T5_03`, `T5_26` |
| F14 | **v2.0 Architecture & Speed Optimization Docs (`ARCHITECTURE_V2.md`, `README.md`)** | `PROJECT.md` | `T1_F14_01`–`05` (5) | `T2_F14_01`–`05` (5) | `T3_12`, `T3_15`, `T3_28` | `T4_01`, `T4_09` | `T5_20` |
| F15 | **Requirement-Driven E2E & Verification Suite (`tests/run_tests.py`)** | `PROJECT.md` | Tiers 1–4 Baseline (168) | Tiers 1–4 Baseline | Tiers 1–4 Baseline | Tiers 1–4 Baseline | `T5_05`, `T5_06`, `T5_31` |
| F16 | **Tier 5 Adversarial Coverage Hardening** | `PROJECT.md` | Integrated in `F17`–`F22` | Integrated in `F17`–`F22` | `T3_19`–`T3_34` | `T4_11`–`T4_16` | `T5_01`–`T5_34` (34) |
| F17 | **PS 5.1 Encoding, JSONC/Array & `PSCustomObject` Safety (`S-19`, `S-20`, `S-26`, `S-28`)** | R2 Survey 1, 3 | `T1_F17_01`–`05` (5) | `T2_F17_01`–`05` (5) | `T3_24`, `T3_34` | `T4_03`, `T4_04` | `T5_02`–`T5_04`, `T5_12`, `T5_18`, `T5_22`–`T5_26`, `T5_32` |
| F18 | **CLI/`CONTEST_*` Env Binding, Non-Destructive `-Mode Verify` & Exit Codes (`S-21`)** | R2 Survey 1, 2, 3 | `T1_F18_01`–`05` (5) | `T2_F18_01`–`05` (5) | `T3_01`, `T3_08`, `T3_19`–`T3_21`, `T3_23`, `T3_26`, `T3_28`, `T3_29` | `T4_09`, `T4_11`, `T4_14`, `T4_15` | `T5_06`, `T5_08`, `T5_11`, `T5_17`, `T5_33`, `T5_34` |
| F19 | **VS Code `--locale ko`, Portable `vscode\data` Trap & Extension Allowlist (`S-22`, `S-27`)** | R2 Survey 1, 2, 3 | `T1_F19_01`–`05` (5) | `T2_F19_01`–`05` (5) | `T3_10`, `T3_20`, `T3_23`, `T3_29` | `T4_01`, `T4_11`, `T4_15` | `T5_12`, `T5_13`, `T5_14`, `T5_30` |
| F20 | **Classroom Speed & Scale Optimizations (`O8`, `O9`, `O10`)** | R2 Survey 1, 3 | `T1_F20_01`–`05` (5) | `T2_F20_01`–`05` (5) | `T3_22`, `T3_32` | `T4_05`, `T4_11` | `T5_16`, `T5_17`, `T5_18`, `T5_28` |
| F21 | **SID-Aware `SYSTEM` Scheduled Tasks, Dual-Trigger/Late-Shutdown Guards & Restore (`S-23`–`S-26`)** | R2 Survey 1, 2, 3 | `T1_F21_01`–`05` (5) | `T2_F21_01`–`05` (5) | `T3_11`, `T3_13`, `T3_14`, `T3_17`, `T3_19`–`T3_21`, `T3_24`, `T3_25`, `T3_27`, `T3_31`, `T3_33`, `T3_34` | `T4_06`, `T4_12`, `T4_13`, `T4_16` | `T5_07`, `T5_09`, `T5_10`, `T5_14`, `T5_15`, `T5_19`, `T5_34` |
| F22 | **Anti-Cheat Browser DoH/Copilot Lockdown & 2025–2026/KR AI Domain Expansion (`S-27`)** | R2 Survey 2, 3 | `T1_F22_01`–`05` (5) | `T2_F22_01`–`05` (5) | `T3_19`, `T3_21`, `T3_25`, `T3_26`, `T3_28`, `T3_31` | `T4_01`, `T4_14`, `T4_15` | `T5_08`, `T5_10`, `T5_20`–`T5_23`, `T5_27` |
| F23 | **Expanded 5-Tier Automated Verification & Mutation Suite (`tests/run_tests.py`)** | R2 Survey 1, 2, 3 | 100 Tests | 100 Tests | 34 Tests | 16 Tests | `T5_01`–`T5_34` (34) |

---

## Test Tiers (`284` Total Automated Tests)

### Tier 1 — Feature Coverage (`100` Tests: Category-Partition Method)
- **Volume**: **100 test cases** (5 test cases per feature across `F1`–`F14` and `F17`–`F22`).
- **Scope**: Verifies primary functional behavior, exact `.ps1` literals, AST function bodies, parameter sets, exact 22-policy HKLM tuples (`13` core + `9` extended), frozen core AI domains (`>= 161` base domains), primary `S-1-5-18` `ServiceAccount` task principals, and design invariants across all 12 `.ps1` scripts and documentation (`README.md`, `ARCHITECTURE_V2.md`, `PROJECT.md`).

### Tier 2 — Boundary & Corner Cases (`100` Tests: Boundary Value Analysis)
- **Volume**: **100 test cases** (5 boundary/corner test cases per feature across `F1`–`F14` and `F17`–`F22`).
- **Scope**: Tests 0/1/N collection boundaries, JSONC BOM/comment/trailing-comma edge cases, `Object[][]` prevention, modern `product.json` missing-key mutation, NuGet `._pth` `import site` repair, KST `+09:00` cross-timezone conversion, `25.0` vs `25.1` minute late-boot shutdown boundary (coupled to extracted `.ps1` threshold), `5 MB` workspace backup size cap (coupled to extracted `.ps1` `$AllowedExts` and `$MaxBytes`), 2-label & 3-label ccSLD `www.` expansion, reversible HKLM browser DoH policy pruning, and `.editorconfig` / `.gitignore` hygiene.

### Tier 3 — Cross-Feature Combinations (`34` Tests: Pairwise & Interface Contracts)
- **Volume**: **34 test cases** (`T3_01`–`T3_34`).
- **Scope**: Dynamically extracts actual caller flags across all 6 script-to-script invocation edges and `-RollbackOnFailure` against declared `param()` blocks and `ParameterSetName` rules (`T3_04`, `T3_19`); verifies 4-way synchronization of all 21 CLI parameters and 21 `CONTEST_*` env vars (`T3_28`), exact 22-policy tuple parity (`13` core + `9` extended `(KeyPath, Name, Type, Value)`) between `ai-hosts-block.ps1` and `restore-and-cleanup.ps1` (`T3_25`), VS Code 1.97+ `<commit>\resources\app\product.json` resolution across all 4 modules (`T3_29`), `CONTEST_MUTEX_OWNER_PID` parent-process mutex handoff (`T3_30`), fail-closed `-DeferAiBlockUntilExamStart` + `-NoRestoreTask` interaction (`T3_31`), `-Mode ExportCache` incomplete-bundle warning + MSYS2 air-gapped sync DB `-Force` seed & offline `pacman -S`/`-U` priority (`T3_32`), `-KeepVSCode` `product.json` unlock & student-accessible backup path resolution (`T3_33`), and `CultureInfo::InvariantCulture` non-Gregorian calendar safety (`T3_34`).

### Tier 4 — Real-World Application Scenarios (`16` Tests: End-to-End Workload Simulation)
- **Volume**: **16 end-to-end scenario tests** (`T4_01`–`T4_16`):
  - `T4_01`–`T4_10`: Cold install, warm 18:50 re-run, `pacman` `db.lck` crash recovery, personal Python/VS2022/Machine PATH coexistence, USB cache reuse, 20:30 scheduled restore, 20:10 early manual restore, 11/24 post-exam past-timestamp guard, lifecycle modes, and mid-run failure preservation.
  - `T4_11`: 100-seat university lab zero-bandwidth deployment (`-Mode ExportCache` → `-CacheDir` offline install → `-Mode Verify`).
  - `T4_12`: Over-the-shoulder `LabAdmin` UAC elevation + student early logoff at `20:05` + `20:30` `SYSTEM` (`S-1-5-18`) SID-aware restoration preserving `HKU\.DEFAULT` and `%USERPROFILE%` `REG_EXPAND_SZ`.
  - `T4_13`: Next-morning laptop boot (`2026-11-24 09:00 KST`) preventing `19:00` `hosts` re-block (`-NotAfter`) and suppressing late `-Shutdown` (`750m > 25m`).
  - `T4_14`: Day-before provisioning (`2026-11-22`) with `-DeferAiBlockUntilExamStart` → `Status` OK → `19:00` enforcement → `Verify` OK.
  - `T4_15`: Active exam anti-cheat bypass attempt blocked across direct `Code.exe`, sideloaded VSIX, Browser DoH, and 2026/Korean AI domains (`grok.com`, `wrtn.ai`, `clova-x.naver.com`, `aistudio.google.com`, `api2.cursor.sh`).
  - `T4_16`: Non-KST student laptop (`UTC-08:00` PST) normalized to simultaneous `2026-11-23T10:00:00Z`–`11:30:00Z` UTC exam window.

### Tier 5 — White-Box Adversarial & Mutation Hardening (`34` Tests: `F16` + `F23`)
- **Volume**: **34 adversarial & mutation tests** (`T5_01`–`T5_34`).
- **Scope**: Win32 `CommandLineToArgvW` round-trip fuzzing of `Quote-ProcessArgument`; JSONC multi-BOM/whitespace/unterminated-`/*` EOF torture (`T5_02`, `T5_26`); PS 5.1 `ConvertTo-Json`/`ConvertFrom-Json` pipeline ban; pure 7-bit ASCII negative mutation checks; `extract_function_body` here-string torture; negative parameter-set conflict mutation tests; `..` path-traversal & sibling-prefix fuzzing; `hosts` post-write AV/Defender tamper read-back & `.*\z` orphan-marker regex (`T5_08`, `T5_27`); `HKU\.DEFAULT` (`S-1-5-18`) write prohibition & `REG_EXPAND_SZ` `SetValue` enforcement (`T5_09`); 6-window dual `-StartWhenAvailable` state machine (`T5_10`); non-destructive `DryRun`/`Status`/`Verify` call-graph audit (`T5_11`); `product.json` comment-spoof & VS Code 1.97+ decoy `data` trap rejection (`T5_12`, `T5_30`); Online Judge & installer collateral-damage guard (`T5_21`); StrictMode unbraced `$Var?` interpolation ban (`T5_22`); function-scope `$PSBoundParameters` ban & `-DurationHours <= 0` guard (`T5_23`); PS 5.1 scalar-unwrapping `@(...)` `.Count` guard (`T5_24`); `-LiteralPath` & `.PSObject.Properties` shortcut-manifest guards (`T5_25`); `Expand-ArchiveFast` Tier-2/3 pre-clean (`T5_28`); `CONTEST_MUTEX_OWNER_PID` dead/self-PID spoofing simulation (`T5_29`); negative mutation meta-test (`T5_31`); `Set-StrictMode -Version 2.0` enforcement (`T5_32`); live-`pwsh` shallow-scope regression for `Get-ContestVariableValue` (`T5_33`: top-level `irm | iex` probe passes on the fixed code and a pre-fix unguarded `Get-Variable -Scope 2` mutant must crash); and live-`pwsh` 12-script AST / PS 5.1 syntax & switch-binding audit plus `C-1` standalone `StrictMode 2.0` dot-source defaults and `C-2` air-gapped `pacman -U` `.sig` exclusion (`T5_34`).

---

## Running the Test Suite

```bash
# Run all 5 tiers (284 total tests, without creating __pycache__)
python3 -B tests/run_tests.py --tier all

# CI mode: fail instead of skip when the live pwsh probes (T5_33, T5_34) cannot run
python3 -B tests/run_tests.py --tier all --strict

# Run individual tiers
python3 -B tests/run_tests.py --tier 1
python3 -B tests/run_tests.py --tier 2
python3 -B tests/run_tests.py --tier 3
python3 -B tests/run_tests.py --tier 4
python3 -B tests/run_tests.py --tier 5
```
