#!/usr/bin/env python3
"""
ContestSetup v2.0 — Requirement-Driven 5-Tier E2E, Behavioral & Adversarial Verification CLI Entrypoint.

Usage:
    python3 -B tests/run_tests.py [--tier 1|2|3|4|5|all] [--verbose] [--json] [--strict]

Tiers:
    Tier 1: Feature Coverage (Category-Partition Method, 100 tests: 5 per F1..F14, F17..F22)
    Tier 2: Boundary & Corner Cases (Boundary Value Analysis, 100 tests: 5 per F1..F14, F17..F22)
    Tier 3: Cross-Feature Combinations (Pairwise & Interface Contract Testing, 34 tests)
    Tier 4: Real-World Application Scenarios (End-to-End Workload Simulation, 16 tests)
    Tier 5: White-Box Adversarial, Mutation Hardening & Live pwsh E2E (F16 + F23, 41 tests)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple

TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from contestsetup_tests import (  # noqa: E402
    EXPECTED_LIB_PS1_FILES,
    INSTALL_ENV_21_PARAMS,
    PS1_FILES,
    REPO_ROOT,
    TestCase,
    TestSkipped,
    build_test_suite,
    find_pwsh,
)
from contestsetup_tests.inspector import PowerShellInspector  # noqa: E402
from contestsetup_tests.simulator import BehavioralSimulator  # noqa: E402

__all__ = [
    "REPO_ROOT",
    "PS1_FILES",
    "EXPECTED_LIB_PS1_FILES",
    "INSTALL_ENV_21_PARAMS",
    "TestCase",
    "TestSkipped",
    "find_pwsh",
    "PowerShellInspector",
    "BehavioralSimulator",
    "build_test_suite",
    "main",
]


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
