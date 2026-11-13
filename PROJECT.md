# Project: ContestSetup v2.0

## Architecture

### Overview
`ContestSetup v2.0` is a modular, idempotent, self-verifying Windows PowerShell provisioning and anti-cheat suite for competitive programming exams (50–200 PC university labs and student laptops). It provisions an isolated C/C++ (MSYS2 UCRT64 GCC/GDB) and Python (`3.10.11`) environment under `C:\CPTools` and `C:\msys64`, configures a dual-layer locked-down portable VS Code profile (`C:\CPTools\vscode\data` + `C:\CPTools\vscode-contest`) with Korean locale (`--locale ko`), strict extension allowlist, and disabled AI/Marketplace features, enforces an IPv4+IPv6+`www.` AI domain blocklist in Windows `hosts` paired with reversible HKLM Browser DNS-over-HTTPS (DoH) & Copilot policy lockdown, and schedules SID-aware `NT AUTHORITY\SYSTEM` (`S-1-5-18`) post-exam environment cleanup and restoration for **Monday, November 23, 2026, 19:00–20:30 (`2026-11-23T19:00:00` to `2026-11-23T20:30:00` KST)**.

### Structural & Reliability Architecture in v2.0 (Round 1 + Round 2 Hardening + Modular `lib/` & Live E2E)
1. **Local-First + Single-Pass Staged Script & `lib/` Module Loader (`install-env.ps1`, `common.ps1`, `docs/STRUCTURE.md`)**:
   - Replaces v1.x's unconditional remote `Invoke-RestMethod ... | Invoke-Expression` loop and decomposes shared logic into 8 single-responsibility domain modules under `lib/*.ps1` (`< 600` lines each, imported via `Import-ContestLibraryModule` in `< 300`-line `common.ps1`).
   - **Local Mode**: When run from a local checkout or USB drive (`$PSScriptRoot` contains all root module `.ps1` and `lib/*.ps1` files) and `-UseRemote` is not set, modules are validated and dot-sourced directly from `$PSScriptRoot`.
   - **Remote Stage Mode (`irm ... | iex`)**: Downloads required root `.ps1` and `lib/*.ps1` scripts once into `$Root\scripts` and `$Root\scripts\lib` (`C:\CPTools\scripts`, cached via `$Script:StagedScriptPaths`) with retry, UTF-8 stream decoding, and PowerShell AST syntax validation (`[System.Management.Automation.Language.Parser]::ParseFile`), then dot-sources them from disk.
2. **100% 7-Bit ASCII `.ps1` Source + Explicit UTF-8 I/O & PS 5.1 JSON Safety (`S-19`, `S-20`)**:
   - All 20 `.ps1` files (`12` root scripts + `8` `lib/*.ps1` modules) are UTF-8 without BOM AND strictly 7-bit ASCII (`< 0x80`) so Windows PowerShell 5.1 on Korean Windows (`CP949`) never suffers `UnicodeDecodeError` or quote corruption.
   - All file reads use `Read-TextUtf8` / `Read-LinesUtf8` (`[System.IO.File]::ReadAllText(..., [System.Text.Encoding]::UTF8)`) and `ConvertFrom-JsonSafe` / `ConvertFrom-JsonArray` in `lib/core-primitives.ps1` (stripping JSONC comments and preventing PS 5.1 `Object[][]` double-wrapped arrays).
3. **Centralized KST (`+09:00`) Schedule & `$PSBoundParameters`-Aware `CONTEST_*` Configuration (`common.ps1` + `install-env.ps1`)**:
   - Centralizes exam schedule defaults to **Monday, 2026-11-23 19:00–20:30 KST**:
     - `$ExamStart = '2026-11-23T19:00:00'`
     - `$ExamEnd   = '2026-11-23T20:30:00'`
     - `$RestoreAt = '2026-11-23T20:30:00'`
   - Normalizes offset-less schedule strings to KST (`+09:00`) via `DateTimeOffset` so laptops in non-KST timezones convert to the exact UTC instant (`2026-11-23T11:30:00Z`), and checks HTTPS `Date` header clock skew during preflight.
   - Exposes all 21 CLI parameters (`-Mode`, `-ExamStart`, `-ExamEnd`, `-RestoreAt`, `-Root`, `-MsysRoot`, `-CacheDir`, `-Msys2CaCertificatePath`, `-PythonVersion`, `-TargetUserSid`, `-TargetUserProfile`, `-IncludeVisualStudio`, `-ForceUpdate`, `-NoRestoreTask`, `-NoRestoreShutdown`, `-RollbackOnFailure`, `-UseRemote`, `-KeepVSCode`, `-NoPause`, `-SkipSignatureCheck`, `-DeferAiBlockUntilExamStart`) AND their 21 `CONTEST_*` environment variable overrides (`CONTEST_MODE`, `CONTEST_EXAM_START`, `CONTEST_EXAM_END`, `CONTEST_RESTORE_AT`, `CONTEST_ROOT`, `CONTEST_MSYS_ROOT`, `CONTEST_CACHE_DIR`, `CONTEST_MSYS2_CA_PATH`, `CONTEST_PYTHON_VERSION`, `CONTEST_TARGET_USER_SID`, `CONTEST_TARGET_USER_PROFILE`, `CONTEST_INCLUDE_VS`, `CONTEST_FORCE_UPDATE`, `CONTEST_NO_RESTORE_TASK`, `CONTEST_NO_RESTORE_SHUTDOWN`, `CONTEST_ROLLBACK_ON_FAILURE`, `CONTEST_USE_REMOTE`, `CONTEST_KEEP_VSCODE`, `CONTEST_NO_PAUSE`, `CONTEST_SKIP_SIGNATURE_CHECK`, `CONTEST_DEFER_AI_BLOCK`).
4. **First-Class Lifecycle Modes & Zero-Bandwidth Classroom Deployment (`O8`–`O10`)**:
   - `-Mode Install` (default): Runs pre-flight checks, concurrent async `CopyToAsync` prefetch, 3-tier `Expand-ArchiveFast` (`System32\tar.exe` -> `ZipFile` -> silent `Expand-Archive`), offline cache seeding, and 8 setup stages, writing checkpoint state to `C:\CPTools\state\install-manifest.json`.
   - `-Mode ExportCache`: Builds a complete zero-bandwidth classroom USB/LAN deployment bundle (`$CacheDir` containing verified base installers, `vscode-extensions` / `.vsix`, `msys2-pkg` `.pkg.tar.zst` archives, `scripts`, and `cache-manifest.json`) eliminating external internet traffic and Marketplace HTTP 429 rate-limits across 50–200 PCs.
   - `-Mode Status` / `-Mode Verify`: Non-destructively audits all components (compilers, Python, VS Code + 4 required extensions + allowlist + `--locale ko` + `serviceUrl == 127.0.0.1`, all 10 wrappers, `>=100` `hosts` AI rules, and Scheduled Task state/trigger) without modifying `hosts` or popping blocking GUI modals, returning exit code `1` on verification failure.
   - `-Mode DryRun`: Validates parameters, KST schedule timestamps, system architecture, and per-drive disk space without modifying the machine.
   - `-Mode Restore`: Invokes `restore-and-cleanup.ps1` to cleanly restore the system.
5. **SID-Aware `SYSTEM` Scheduled Tasks, Anti-Cheat DoH Lockdown & Safe Restoration (`S-23`–`S-28`)**:
   - Registers Scheduled Tasks under `S-1-5-18` (`NT AUTHORITY\SYSTEM`, `ServiceAccount`, `-WakeToRun`, 1h execution limit) while tracking the student's `TargetUserSid` & `TargetUserProfile` so `User` PATH (`REG_EXPAND_SZ`, `NTUSER.DAT` hive load when signed out) targets `HKU\<TargetUserSid>\Environment` and never corrupts `HKU\.DEFAULT`.
   - Eliminates the dual `-StartWhenAvailable` race via trigger `EndBoundary` + `-NotAfter` + `Global\ContestSetupEnvironmentMutex` (`CultureInfo.InvariantCulture` formatting), suppresses `-Shutdown` when `-StartWhenAvailable` runs `>25` minutes late (next-morning boot safety), backs up student source files to persistent `%LOCALAPPDATA%\ContestSetup-Backups\ContestSetup-Workspace-Backup-*` (`TargetUserProfile\AppData\Local\ContestSetup-Backups`, fallback `%ProgramData%\ContestSetup-Backups` / `%TEMP%`) before deleting `$Root`, self-relocates to `$env:TEMP\contest-restore-runner.ps1`, unlocks `product.json` when `-KeepVSCode` is set, restores MSYS2 `.contest-bak` configs, and sequences `shutdown.exe` strictly *after* `rmdir` in `remove-cptools.cmd`.

## Feature Inventory

Every feature across Round 1 (`F1`–`F16`) and Round 2 (`F17`–`F23`) is cataloged below.

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | **Exam Schedule Alignment (2026-11-23 Mon 19:00–20:30)** | Update all schedule triggers, parameters, defaults, and docs from `2026-05-09T17:10:00` / `2026-05-04 18:00` to Monday `2026-11-23` `19:00:00`–`20:30:00` (`RestoreAt = '2026-11-23T20:30:00'`), with KST timezone check, Monday day-of-week validation, past-timestamp safeguard, and 19:00 start enforcement hook. | M1 | survey |
| F2 | **Hybrid Local-First + Staged Module Loader (`install-env.ps1`)** | Support both local/offline execution (dot-sourcing from `$PSScriptRoot`) and remote `irm \| iex` execution (staging scripts to `$Root\scripts` with retry + AST syntax check before dot-sourcing), plus proper UAC self-elevation argument quoting, UTF-8 BOM script writing, mutex lifecycle safety, and `-NoPause` non-blocking behavior. | M1 | survey |
| F3 | **Lifecycle Modes (`Install`, `Verify`, `Status`, `DryRun`, `Restore`, `ExportCache`) & Pre-flight Checks** | Implement `-Mode Install\|Verify\|Status\|DryRun\|Restore\|ExportCache`, `Invoke-PreflightChecks` (64-bit check, per-drive disk space check, clock skew check, clearing stale AI hosts blocks prior to downloads), and `C:\CPTools\state\install-manifest.json` state tracking. | M1 / R2-M1 | survey |
| F4 | **Non-Destructive Failure Handling & Log/Cache Preservation** | Close transcript before rollback, preserve `C:\CPTools\logs`, `C:\CPTools\downloads`, and `C:\CPTools\contest` on install error, back up error logs to `$env:TEMP\ContestSetup-Logs`, and add `-KeepLogs`, `-KeepDownloads`, `-KeepWorkspace`, `-KeepVSCode` flags to `restore-and-cleanup.ps1`. | M1 / R2-M2 | survey |
| F5 | **Parallel Download Prefetcher & Smart Cache Reuse (`common.ps1`)** | Implement `Invoke-ParallelDownloadFiles` for concurrent installer fetching, support `-CacheDir` (USB/LAN cache), validate `Content-Length`, enable `Invoke-WebRequest` fallback on PS 5.1 & PS 7+, and reuse cached `.zip`/`latest` `.exe` files when magic headers (`PK\x03\x04` / `MZ`) and minimum size check pass. | M1 | survey |
| F6 | **Fast & Self-Healing MSYS2 Provisioning (`setup-msys2.ps1`)** | Fix 60s dead sleep loop when `winget` is skipped/fails; auto-recover stale `var/lib/pacman/db.lck` and orphan `gpg-agent`/`dirmngr`; add fast-path skip when `g++`, `gcc`, `gdb`, `cat` already exist and work (unless `-ForceUpdate`); configure Korean mirrors (`ftp.kaist.ac.kr`, `mirror.harukasan.org`) + official CDNs; enable `ParallelDownloads = 8` and disable unused repos in `pacman.conf`; lazy single-PEM root CA sync; combined `pacman --needed -Syu` transaction. | M1 | survey |
| F7 | **Conflict-Free Python 3.10 Provisioning (`setup-python.ps1`)** | Handle pre-existing system Python 3.10.11 installations without failing when `TargetDir` is skipped by WiX Burn (fallback copy/NuGet/repair), wait/retry on MSI exit code `1618`, create native `python3.exe` alongside `python.exe`, and record `PythonInstalledByContestSetup` in manifest so cleanup never uninstalls user's personal Python. | M1 | survey |
| F8 | **Opt-In Visual Studio 2022 & `vswhere.exe` Detection (`setup-visualstudio.ps1`)** | Detect all VS editions (`Community`, `Professional`, `Enterprise`, `BuildTools`) with `VC.Tools.x86.x64` (`cl.exe`); skip 7–12 GB VS2022 install by default unless `-IncludeVisualStudio` is passed; drop `--includeRecommended` and accept exit code `3010` as success. | M1 | survey |
| F9 | **Bulletproof Portable VS Code & Batched Extensions (`setup-vscode.ps1`)** | Verify `Code.exe`, `code.cmd`, and `product.json`; save `product.json.contest-orig` backup before Marketplace lock (`127.0.0.1`) and unlock before installing missing extensions; batch missing extensions into a single `code.cmd` call without `--force`; fail if required extensions remain missing; preserve original shortcut `Existed` flag in `shortcut-manifest.json`; generate `.vscode\tasks.json`, `c_cpp_properties.json`, and `launch.json`. | M1 | survey |
| F10 | **Clean Command Wrappers & Machine/User PATH Precedence (`setup-wrappers.ps1`, `common.ps1`)** | Add `@setlocal` to all `.cmd` wrappers; prevent `.cmd` wrappers from shadowing native `.exe` binaries (`$PythonDir` and `$UcrtBin` before `$ToolBin`); handle `Machine` vs `User` PATH shadowing with backup; verify `Get-Command` resolution in C++14, C++20, and Python3 smoke tests. | M1 | survey |
| F11 | **Resilient IPv4+IPv6 AI Hosts Blocking (`ai-hosts-block.ps1`, `setup-ai-hosts.ps1`, `install-ai-hosts.ps1`)** | Add `[AllowEmptyString()]` to `Remove-ManagedHostsSectionFromText`; clear `ReadOnly` attribute and retry `hosts` writes 5 times on lock; block both `0.0.0.0` (IPv4) and `::` (IPv6) plus `www.` subdomain variants; stage `ai-hosts-block.ps1` to stable paths; remove `-NoExit` from `install-ai-hosts.ps1`; align `-Until` schedule to `2026-11-23 20:30`. | M1 | survey |
| F12 | **Admin-Checked Complete Restoration (`restore-and-cleanup.ps1`, `setup-restore-task.ps1`)** | Enforce `Test-IsAdmin` + self-elevation at top of `restore-and-cleanup.ps1`; always unregister `ContestSetupRestoreAndCleanup`, `ContestSetupRestoreAiHostsBlock`, and `ContestSetupExamStartEnforcement`; restore PATH from snapshot AND run surgical cleanup; only uninstall Python if `InstallLocation` is inside `$Root`; terminate all processes with `.Path` inside `$Root`; write `remove-cptools.cmd` in UTF-8 (`chcp 65001 >nul`) and sequence shutdown after `rmdir`. | M1 | survey |
| F13 | **JSON Serialization & Shared Helper Deduplication (`common.ps1`, `lib/*.ps1`)** | Fix `Write-JsonUtf8NoBom` using `ConvertTo-Json -InputObject` so 0/1-element arrays are preserved; deduplicate shared functions across 8 `lib/*.ps1` modules (`core-primitives.ps1`, `browser-policies.ps1`, `vscode-workspace.ps1`, etc.). | M1 | survey |
| F14 | **v2.0 Architecture & Speed Optimization Analysis Document (`ARCHITECTURE_V2.md`, `README.md`, `docs/STRUCTURE.md`)** | Comprehensive Korean documentation in `ARCHITECTURE_V2.md`, `README.md`, and `docs/STRUCTURE.md` covering the `2026-11-23 (월) 19:00~20:30` exam schedule, root-cause analysis of instabilities (`S-01`–`S-28`), v2.0 3-tier `lib/` architectural design, and quantified speed optimizations (`O1`–`O10`). | M1 / R2-M2 | survey |
| F15 | **Requirement-Driven E2E & Verification Test Suite (`tests/run_tests.py`, `tests/contestsetup_tests/`, `TEST_INFRA.md`)** | Modular automated test runner (`tests/run_tests.py` + `tests/contestsetup_tests/` PowerShell/AST/behavioral/live-`pwsh` verification package) covering Tier 1 (Feature Coverage), Tier 2 (Boundary & Corner Cases), Tier 3 (Cross-Feature Combinations), and Tier 4 (Real-World Application Scenarios). | E2E | survey |
| F16 | **Tier 5 Adversarial Coverage Hardening & Live `pwsh` E2E (`T5_01`–`T5_41`)** | White-box adversarial testing and live `pwsh 7.4+` E2E execution to expose regex/quoting bugs, PS 5.1 encoding/JSON flaws, or state-corruption paths across all 20 `.ps1` scripts. | M2 | survey |
| F17 | **PS 5.1 Encoding, JSONC/Array & `PSCustomObject` Runtime Safety (`S-19`, `S-20`, `S-28`)** | 100% 7-bit ASCII `.ps1` files, `Read-TextUtf8`/`Read-LinesUtf8` replacing bare `Get-Content`, `ConvertFrom-JsonSafe`/`ConvertFrom-JsonArray` (no `Object[][]` or JSONC `//` crash), `Set-ObjectProperty` + post-write lock check in `Disable-VSCodeMarketplace`, space-safe `.cmd` execution, MSYS2 two-stage `SyncFirst` & PGP keyring recovery (`S-26`), Python `robocopy`/`._pth`/stdlib validation, VS `cl.exe` check. | R2-M1 | R2 survey 1, 3 |
| F18 | **CLI/`CONTEST_*` Env Binding, Non-Destructive `-Mode Verify` & Exit Code Integrity (`S-21`, `S-27`)** | `$PSBoundParameters`-aware `CONTEST_*` env vars, `$PSCommandPath` StrictMode safety, early mutex `try/finally`, non-destructive `-Mode Verify` returning exit `1` without touching `hosts` or GUI modals, deep `Invoke-ContestEnvironmentAudit`. | R2-M1 | R2 survey 1, 2, 3 |
| F19 | **VS Code `--locale ko`, Portable `vscode\data` Trap & Extension Allowlist (`S-22`, `S-27`)** | Pass `--locale ko` everywhere, initialize `vscode\data` portable directory to block direct `Code.exe` bypass, enforce strict extension allowlist, cover Taskbar pinned `.lnk` & `CommonDesktopDirectory`, harden `code.cmd`/`tasks.json`/`launch.json`. | R2-M1 | R2 survey 1, 2, 3 |
| F20 | **Classroom Speed & Scale Optimizations (`O8`, `O9`, `O10`)** | `Expand-ArchiveFast` (`System32\tar.exe` -> `ZipFile` -> silent `Expand-Archive`), true concurrent `CopyToAsync` + post-download `Test-ValidCachedInstallerFile`, `-Mode ExportCache` + offline `vscode-extensions`/`.vsix` & `msys2-pkg` seeding, single-pass remote staging, cached `code.cmd --list-extensions`, parallel `-O0` smoke tests. | R2-M1 | R2 survey 1, 3 |
| F21 | **SID-Aware `SYSTEM` Scheduled Tasks, Dual-Trigger/Late-Shutdown Guards & Complete Restore (`S-23`, `S-24`, `S-25`, `S-26`)** | `S-1-5-18` (`ServiceAccount`) task principal + `-WakeToRun`, `TargetUserSid`/`HKU\<SID>\Environment` `REG_EXPAND_SZ` PATH handling, KST `+09:00` offset parsing, `19:00` task `EndBoundary` + `-NotAfter`, `>25m` late-boot `-Shutdown` suppression, `Quote-ProcessArgument` task args, persistent student `AppData\Local\ContestSetup-Backups` solution backup before cleanup, `$env:TEMP` self-relocation, `ping`-based `remove-cptools.cmd` with post-`rmdir` shutdown, MSYS2 `.contest-bak` restoration, `-KeepVSCode` (`product.json` unlock) & `-MsysRoot` support. | R2-M2 | R2 survey 1, 2, 3 |
| F22 | **Anti-Cheat Browser DoH/Copilot Lockdown & 2025–2026/KR AI Domain Expansion (`S-27`)** | Reversible 22-entry HKLM Browser DoH (`Chrome`, `Edge`, `Whale`, `Brave`, `Firefox` including `DnsOverHttpsTemplates`) & built-in AI/Copilot policy lockdown (`browser-policies.bak.json`), expanded 135+ frontier & Korean AI domain blocklist (`chat.com`, `claude.com`, `grok.com`, `x.ai`, `m365copilot.com`, `copilot.cloud.microsoft`, `genspark.ai`, `manus.im`, `aistudio.google.com`, `wrtn.ai`, `clova-x.naver.com`, `liner.com`, `lmarena.ai`, `duck.ai`, `qwen.ai`, `kimi.com`, `v0.dev`, `bolt.new`, `api2.cursor.sh`, `api.individual.githubcopilot.com`, ccSLD `.co.kr` `www.`), pre-write `-Until` validation, unconditional `hosts` fallback cleanup, fail-closed `-DeferAiBlockUntilExamStart`, synchronized docs & repo hygiene. | R2-M2 | R2 survey 2, 3 |
| F23 | **Expanded 5-Tier Modular Verification, Mutation & Live `pwsh` E2E Suite (`tests/run_tests.py`, `tests/contestsetup_tests/`, `TEST_INFRA.md`)** | Decompose test runner into `tests/contestsetup_tests/`, upgrade `PowerShellInspector` for `lib/` expansion, add 291 total tests across Tiers 1–4 (`F1`–`F22`) and Tier 5 (`T5_01`–`T5_41`, including 7 Live `pwsh` Environment E2E tests `T5_35`–`T5_41`). | R2-E2E | R2 survey 1, 2, 3 |

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | ContestSetup v2.0 Core Implementation & Documentation (`F1`–`F14`) | Upgrade all 12 `.ps1` scripts to v2.0, update schedule to Monday `2026-11-23 19:00–20:30`, fix instabilities (`S-01`–`S-18`), implement speed optimizations (`O1`–`O7`), update `README.md`, and write `ARCHITECTURE_V2.md`. | none | DONE |
| E2E | E2E Test Suite Infrastructure & Tiers 1–4 (`F15`) | Design and implement `TEST_INFRA.md`, `tests/run_tests.py` automated test runner across Tiers 1–4 covering `F1`–`F14`, and publish `TEST_READY.md`. | none | DONE |
| M2 | Round 1 Final Verification, Gate Review & Adversarial Hardening (`F16`) | Independent Reviewer, Challenger, and Forensic Auditor verification of Round 1 baseline. | M1, E2E | DONE |
| R2-M1 | Core Provisioning, PS 5.1 Runtime & Classroom Speed (`F17`–`F20`) | Upgrade `common.ps1`, `install-env.ps1`, `setup-msys2.ps1`, `setup-python.ps1`, `setup-visualstudio.ps1`, `setup-vscode.ps1`, `setup-wrappers.ps1`. | M2 | DONE |
| R2-M2 | Exam Ops, `SYSTEM`/SID Restore, Anti-Cheat DoH & Docs Sync (`F21`–`F22`) | Upgrade `ai-hosts-block.ps1`, `setup-ai-hosts.ps1`, `install-ai-hosts.ps1`, `setup-restore-task.ps1`, `restore-and-cleanup.ps1`, `.gitignore`, `.editorconfig`, `PROJECT.md`, `ARCHITECTURE_V2.md`, `README.md`. | M2 | DONE |
| R2-E2E | Expanded 5-Tier Verification Suite (`F23`) | Upgrade `tests/run_tests.py` (`--tier 1..5\|all`), `TEST_INFRA.md`, `TEST_READY.md`, verify 100% pass across all 5 tiers. | R2-M1, R2-M2 | DONE |
| R2-Gate | Round 2 Gate Review, Adversarial Fuzzing & Forensic Audit | Final 2 Reviewers + 2 Challengers + 1 Forensic Auditor sign-off (`GATE_STATUS.md`). | R2-M1, R2-M2, R2-E2E | DONE |

## Interface Contracts

### `install-env.ps1` ↔ `common.ps1` & `setup-*.ps1`
- **Parameters & `CONTEST_*` Environment Variable Overrides**:
  - `[ValidateSet('Install', 'Status', 'Verify', 'Restore', 'DryRun', 'ExportCache')][string]$Mode = 'Install'` (`CONTEST_MODE`)
  - `[string]$ExamStart = '2026-11-23T19:00:00'` (`CONTEST_EXAM_START`)
  - `[string]$ExamEnd = '2026-11-23T20:30:00'` (`CONTEST_EXAM_END`)
  - `[string]$RestoreAt = '2026-11-23T20:30:00'` (`CONTEST_RESTORE_AT`)
  - `[string]$Root = "$env:SystemDrive\CPTools"` (`CONTEST_ROOT`)
  - `[string]$MsysRoot = "$env:SystemDrive\msys64"` (`CONTEST_MSYS_ROOT`)
  - `[string]$CacheDir = ''` (`CONTEST_CACHE_DIR`)
  - `[string]$Msys2CaCertificatePath = ''` (`CONTEST_MSYS2_CA_PATH`)
  - `[string]$PythonVersion = '3.10.11'` (`CONTEST_PYTHON_VERSION`)
  - `[string]$TargetUserSid = ''` (`CONTEST_TARGET_USER_SID`)
  - `[string]$TargetUserProfile = ''` (`CONTEST_TARGET_USER_PROFILE`)
  - `[switch]$IncludeVisualStudio` (`CONTEST_INCLUDE_VS`)
  - `[switch]$ForceUpdate` (`CONTEST_FORCE_UPDATE`)
  - `[switch]$NoRestoreTask` (`CONTEST_NO_RESTORE_TASK`)
  - `[switch]$NoRestoreShutdown` (`CONTEST_NO_RESTORE_SHUTDOWN`)
  - `[switch]$RollbackOnFailure` (`CONTEST_ROLLBACK_ON_FAILURE`)
  - `[switch]$UseRemote` (`CONTEST_USE_REMOTE`)
  - `[switch]$KeepVSCode` (`CONTEST_KEEP_VSCODE`)
  - `[switch]$NoPause` (`CONTEST_NO_PAUSE`)
  - `[switch]$SkipSignatureCheck` (`CONTEST_SKIP_SIGNATURE_CHECK`)
  - `[switch]$DeferAiBlockUntilExamStart` (`CONTEST_DEFER_AI_BLOCK`)
- **Staging Directory**: `$ScriptStageDir = Join-Path $Root 'scripts'`
- **State Manifest**: `$StateManifestPath = Join-Path $Root 'state\install-manifest.json'`

### `setup-restore-task.ps1`, `restore-and-cleanup.ps1` & `ai-hosts-block.ps1`
- **Scheduled Task Names (`S-1-5-18` `ServiceAccount` Principal + `-WakeToRun`)**:
  - `ContestSetupRestoreAndCleanup` (primary post-exam cleanup at `$RestoreAt = '2026-11-23T20:30:00'` KST)
  - `ContestSetupRestoreAiHostsBlock` (standalone AI hosts & browser DoH policy restore task)
  - `ContestSetupExamStartEnforcement` (19:00 exam-start enforcement task when installed before `$ExamStart`, bounded by `EndBoundary` and `-NotAfter`)
- **`restore-and-cleanup.ps1` Parameters**:
  - `[string]$Root = "$env:SystemDrive\CPTools"` (`CONTEST_ROOT`)
  - `[string]$MsysRoot = "$env:SystemDrive\msys64"` (`CONTEST_MSYS_ROOT`)
  - `[string]$PythonDir = ''` (`CONTEST_PYTHON_DIR`)
  - `[string]$PythonVersion = '3.10.11'` (`CONTEST_PYTHON_VERSION`)
  - `[string]$TargetUserSid = ''` (`CONTEST_TARGET_USER_SID`)
  - `[string]$TargetUserProfile = ''` (`CONTEST_TARGET_USER_PROFILE`)
  - `[string]$ScheduledRestoreAt = ''` (`CONTEST_SCHEDULED_RESTORE_AT`)
  - `[switch]$Shutdown`, `[switch]$KeepDownloads`, `[switch]$KeepLogs`, `[switch]$KeepWorkspace`, `[switch]$KeepVSCode` (`CONTEST_KEEP_VSCODE`), `[switch]$PurgeWorkspace`, `[switch]$NoPause` (`CONTEST_NO_PAUSE`), `[switch]$ReinvokedFromTemp`
- **`ai-hosts-block.ps1` Parameters**:
  - `[switch]$Apply`, `[string]$Until = ''`, `[int]$DurationHours = 0`, `[switch]$NoSchedule`, `[string]$NotAfter = ''`, `[switch]$Restore`, `[string]$Root = "$env:SystemDrive\CPTools"`, `[string]$DomainListPath = ''`, `[string]$DomainListUrl = ''`, `[string]$BlockListPath = ''`, `[string]$BlockListUrl = ''`, `[string]$BlockListSha256 = ''`, `[switch]$AllowUnverifiedBlockListUrl`, `[switch]$ForceDownload`, `[switch]$SkipBrowserPolicy`

## Code Layout

```
ContestSetup/
├── .editorconfig                # UTF-8 no-BOM, LF, PS1/SH (2), Python (4), JSON (2) rules
├── .gitignore                   # Ignores __pycache__, .agents/, *.tmp, *.bak
├── README.md                    # User & proctor Korean guide (2026-11-23 19:00-20:30, ExportCache, 20:30 warning, runbook)
├── ARCHITECTURE_V2.md           # Comprehensive v2.0 engineering report (S-01..S-28, O1..O10, classroom scale)
├── PROJECT.md                   # Project architecture, feature inventory (F1..F23), milestones, contracts
├── TEST_INFRA.md                # 5-tier E2E, adversarial & live pwsh test architecture (291 tests)
├── CHANGELOG.md                 # Keep a Changelog release notes (v2.0.0)
├── docs/
│   └── STRUCTURE.md             # 3-layer modular architecture & staging/load flow guide (Korean)
├── .github/workflows/ci.yml     # CI: PS 5.1 + pwsh AST parse on windows-latest, full test suite on ubuntu/windows
├── install-env.ps1              # v2.0 entry point (Local-First + Staged loader, ExportCache/Verify/Status/DryRun/Restore)
├── common.ps1                   # v2.0 config hub (<300L) & Import-ContestLibraryModule loader
├── setup-msys2.ps1              # v2.0 MSYS2 installer (fast-path skip, db.lck/PGP recovery, KR mirrors, two-stage SyncFirst, pkg cache)
├── setup-python.ps1             # v2.0 Python 3.10 installer (collision-safe, robocopy/stdlib/._pth validation, python3.exe)
├── setup-visualstudio.ps1       # v2.0 Visual Studio detector/installer (vswhere + cl.exe verification, opt-in -IncludeVisualStudio)
├── setup-vscode.ps1             # v2.0 Portable VS Code setup (vscode\data trap, --locale ko, allowlist, product.json lock)
├── setup-wrappers.ps1           # v2.0 Portable CLI wrappers (@setlocal, non-shadowing PATH order, parallel -O0 smoke tests)
├── setup-ai-hosts.ps1           # v2.0 AI hosts integration module (local/staged first, -DeferAiBlockUntilExamStart support)
├── ai-hosts-block.ps1           # v2.0 AI hosts & Browser DoH/Copilot blocker (2026/KR domains, NotAfter guard, SYSTEM task)
├── install-ai-hosts.ps1         # v2.0 standalone AI hosts bootstrapper (2026-11-23 20:30 default, child exit code propagation)
├── setup-restore-task.ps1       # v2.0 SYSTEM (S-1-5-18) Scheduled Task registration (WakeToRun, EndBoundary, Quote-ProcessArgument)
├── restore-and-cleanup.ps1      # v2.0 SID-aware restoration & cleanup (late-boot guard, code backup, TEMP self-relocation, MSYS2 restore)
├── lib/                         # Shared PowerShell domain library layer (8 modules, each <600L, 100% 7-bit ASCII)
│   ├── core-primitives.ps1      # UTF-8 no-BOM I/O, JSONC parser, Quote-ProcessArgument, Resolve-VSCodeProductJsonPath, Test-PathInside
│   ├── logging-and-manifest.ps1 # Transcript logging & install-manifest.json state checkpoint helpers
│   ├── schedule-and-preflight.ps1 # KST (+09:00) schedule validation, HTTPS clock skew check, Invoke-PreflightChecks
│   ├── download-and-archive.ps1 # Expand-ArchiveFast, Test-ValidCachedInstallerFile, async downloader, SHA256/Authenticode/winget
│   ├── path-and-identity.ps1    # SID/profile resolution, HKU\<SID>\Environment REG_EXPAND_SZ PATH management & backups
│   ├── environment-audit.ps1    # Read-only Invoke-ContestEnvironmentAudit engine (Status/Verify/DryRun + test override support)
│   ├── browser-policies.ps1     # Canonical 22 browser DoH & AI registry policy specifications (13 core + 9 extended)
│   └── vscode-workspace.ps1     # VS Code .lnk shortcut manifest, launcher, CLI wrapper, and default .vscode workspace configs
└── tests/                       # Modular 5-tier verification, mutation & live pwsh E2E suite (291 tests)
    ├── run_tests.py             # Slim CLI test runner entrypoint (<200L, --tier 1|2|3|4|5|all, --strict)
    └── contestsetup_tests/      # Modular test package
        ├── __init__.py          # Shared constants (PS1_FILES, EXPECTED_LIB_PS1_FILES), TestCase/TestSkipped, suite builder
        ├── inspector.py         # PowerShellInspector (lib/ effective code expansion, AST/lexical/7-bit ASCII inspector)
        ├── simulator.py         # BehavioralSimulator (Win32 quoting, JSONC, KST schedule, hosts, browser policy & backup models)
        ├── tier1_features.py    # Tier 1: Feature coverage (100 tests)
        ├── tier2_boundaries.py  # Tier 2: Boundary & corner cases (100 tests)
        ├── tier3_contracts.py   # Tier 3: Cross-feature & script-to-script contracts (34 tests)
        ├── tier4_scenarios.py   # Tier 4: Real-world exam lifecycle scenarios (16 tests)
        ├── tier5_adversarial.py # Tier 5: White-box adversarial, mutation & AST probes (34 tests, T5_01-T5_34)
        └── live_pwsh_e2e.py     # Tier 5: Live pwsh 7.4+ E2E execution & structural modularity gate (7 tests, T5_35-T5_41)
```
