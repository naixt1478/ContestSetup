"""
ContestSetup v2.0 — Modular 5-Tier Verification, Behavioral Simulation & Live PowerShell E2E Package.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

PS1_FILES: List[str] = [
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

EXPECTED_LIB_PS1_FILES: List[str] = [
    "lib/browser-policies.ps1",
    "lib/core-primitives.ps1",
    "lib/download-and-archive.ps1",
    "lib/environment-audit.ps1",
    "lib/logging-and-manifest.ps1",
    "lib/path-and-identity.ps1",
    "lib/schedule-and-preflight.ps1",
    "lib/vscode-workspace.ps1",
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
    candidates = [
        os.environ.get("CONTEST_PWSH", ""),
        shutil.which("pwsh") or "",
        str(Path.home() / ".local" / "pwsh" / "pwsh"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def make_registrar(tests: List[TestCase]):
    """Create a @register(test_id, tier, feature, description) decorator appending to `tests`."""
    def register(test_id: str, tier: int, feature: str, description: str):
        def decorator(fn: Callable[[], None]):
            tests.append(TestCase(test_id=test_id, tier=tier, feature=feature, description=description, fn=fn))
            return fn
        return decorator
    return register


def build_test_suite(repo_root: Path = REPO_ROOT) -> List[TestCase]:
    """Assemble all 5 verification tiers (T1..T5, including live pwsh E2E tests T5_35..T5_41)."""
    from . import (
        live_pwsh_e2e,
        tier1_features,
        tier2_boundaries,
        tier3_contracts,
        tier4_scenarios,
        tier5_adversarial,
    )
    from .inspector import PowerShellInspector
    from .simulator import BehavioralSimulator

    ps = PowerShellInspector(repo_root)
    sim = BehavioralSimulator(ps)
    tests: List[TestCase] = []

    for mod in (
        tier1_features,
        tier2_boundaries,
        tier3_contracts,
        tier4_scenarios,
        tier5_adversarial,
        live_pwsh_e2e,
    ):
        tests.extend(mod.register_tests(ps, sim, repo_root))
    return tests


__all__ = [
    "EXPECTED_LIB_PS1_FILES",
    "INSTALL_ENV_21_PARAMS",
    "PS1_FILES",
    "REPO_ROOT",
    "TestCase",
    "TestSkipped",
    "build_test_suite",
    "find_pwsh",
    "make_registrar",
]
