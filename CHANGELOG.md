# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Issue IDs (`S-xx` stability, `O-x` optimization) refer to the tables in `ARCHITECTURE_V2.md`.

## [Unreleased]

## [2.0.0] - 2026-11-11

Release prepared for the exam on **Monday, 2026-11-23, 19:00-20:30 KST**.

### Added

- `install-env.ps1 -Mode` lifecycle: `Install`, `Verify` (exit code 0/1), `Status`, `DryRun`, `Restore`, `ExportCache`.
- `-Mode ExportCache` + `-CacheDir` offline classroom bundle (installers, VS Code extensions/`.vsix`, MSYS2 package cache) for 50-200 seat labs with zero external traffic (O9).
- 21 CLI parameters, each overridable by a matching `CONTEST_*` environment variable (CLI > env > default), including `-DeferAiBlockUntilExamStart`, `-RollbackOnFailure`, `-KeepVSCode`, `-NoRestoreShutdown`, `-UseRemote`.
- SYSTEM (`S-1-5-18`) scheduled tasks `ContestSetupExamStartEnforcement` (19:00, `EndBoundary` + `-NotAfter`), `ContestSetupRestoreAndCleanup` and `ContestSetupRestoreAiHostsBlock` (20:30), with `WakeToRun` and a global mutex (S-23, S-24).
- KST (`+09:00`) `DateTimeOffset` schedule normalization and HTTPS server-time clock-skew preflight (S-25).
- Automatic backup of student source files to `%LOCALAPPDATA%\ContestSetup-Backups` before cleanup (S-25).
- Browser DNS-over-HTTPS and built-in AI policy lockdown (Chrome, Edge, Whale, Brave, Firefox) with reversible HKLM backup; expanded 2025-2026 / Korean AI domain blocklist over IPv4, IPv6 and `www.` (S-11, S-27).
- `Expand-ArchiveFast`: `System32\tar.exe` -> `ZipFile` -> silent `Expand-Archive` (O8).
- `ARCHITECTURE_V2.md` (design analysis), `PROJECT.md` (feature inventory and contracts), `TEST_INFRA.md` (test architecture), this `CHANGELOG.md`.
- `tests/run_tests.py`: 283-test, 5-tier verification suite (feature coverage, boundary cases, cross-feature contracts, end-to-end scenarios, adversarial/mutation hardening), with `--tier`, `--verbose`, `--json` and `--strict`.
- Live `pwsh` regression test `T5_33` for the `Get-ContestVariableValue` shallow-scope fix; reported as SKIP when `pwsh` is unavailable (FAIL under `--strict`).
- GitHub Actions workflow `.github/workflows/ci.yml`: Windows PowerShell 5.1 + PowerShell 7 AST parse of every `.ps1` on `windows-latest`, and the full test suite on Windows and Ubuntu.
- `.gitignore` for Python caches, temporary/backup artifacts and agent workspace metadata.

### Changed

- Exam schedule moved from 2026-05-09 to 2026-11-23 19:00-20:30 KST across all scripts and docs (S-06).
- Local-first module loading: scripts next to `install-env.ps1` are dot-sourced directly; remote `irm | iex` mode stages modules once into `$Root\scripts` with AST validation (S-17, O10).
- MSYS2: Korean mirrors first, `ParallelDownloads = 8`, single bundled CA import, two-stage `SyncFirst` upgrade with `g++`/`gdb` re-check, skip when already provisioned (S-13, S-26, O2-O4).
- VS Code: dual isolated portable profile, `--locale ko`, extension allowlist installed in one batch only when missing, `product.json` marketplace lock with original backup (S-01, S-22, O6).
- Parallel cached downloads with magic-header validation instead of sequential re-downloads (S-16, O5).
- Visual Studio 2022 is now opt-in via `-IncludeVisualStudio`, detected through `vswhere` + `cl.exe` (S-14, O1).
- All `.ps1` sources are 7-bit ASCII, UTF-8 without BOM, LF; explicit UTF-8 file I/O and PS 5.1-safe JSON helpers (S-19, S-20).
- `README.md` rewritten as a Korean user/proctor guide with an exam-day runbook, full CLI/env reference and developer test instructions.

### Fixed

- Marketplace deadlock on re-run after `product.json` was locked (S-01).
- Rollback deleting logs, caches and student code on failure (S-02).
- System Python 3.10 collisions and deletion of personal Python installs (S-03).
- Permanent MSYS2 `db.lck` after an interrupted run (S-04).
- Machine `PATH` shadowing the contest user `PATH` (S-05); interactive scheduled tasks not running after logoff/UAC and SYSTEM writing user `PATH` into `HKU\.DEFAULT` (S-23).
- Restore leaving scheduled tasks behind; missing admin check in restore (S-07, S-10).
- UAC re-launch argument quoting with spaces/trailing backslashes (S-08, S-28).
- Blocking prompts during unattended deployment (S-09).
- `.cmd` wrappers missing `setlocal` and being shadowed by `.exe` (S-12).
- Locked child processes and non-UTF-8 batch encoding during cleanup (S-15).
- Single-element JSON arrays unwrapped by PS 5.1 (S-18).
- `CONTEST_*` string environment overrides ignored because of `param()` defaults; `-Mode Verify` failure removing the active AI `hosts` block and exiting with code 0 (S-21).
- `Get-ContestVariableValue` crashing with `ArgumentOutOfRange` when `common.ps1` is loaded at the top level (`irm | iex` or dot-sourced from the prompt), because `Get-Variable -Scope 2` exceeds the call stack and is not suppressible with `-ErrorAction`.

## [1.x] - before 2026-11

- Original remote `irm | iex` installer targeting the 2026-05-09 exam.

[Unreleased]: https://github.com/naixt1478/ContestSetup/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/naixt1478/ContestSetup/releases/tag/v2.0.0
