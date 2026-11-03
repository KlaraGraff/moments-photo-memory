#!/usr/bin/env python3
"""Fail when the core UI-test list names a test that no longer exists."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts" / "ui_core_tests.txt"
TESTS_DIR = ROOT / "macos" / "Tests" / "MomentsUITests"
CLASS_PATTERN = re.compile(r"\b(?:final\s+)?class\s+(\w+)[^{]*\{")
TEST_PATTERN = re.compile(r"\bfunc\s+(test\w+)\s*\(")


def check(root: Path = ROOT) -> list[str]:
    errors = []
    classes: dict[str, set[str]] = {}
    for source in (root / "macos" / "Tests" / "MomentsUITests").glob("*.swift"):
        current_class = None
        for line in source.read_text(encoding="utf-8").splitlines():
            class_match = CLASS_PATTERN.search(line)
            if class_match:
                current_class = class_match.group(1)
                classes.setdefault(current_class, set())
                continue
            test_match = TEST_PATTERN.search(line)
            if current_class is not None and test_match:
                classes[current_class].add(test_match.group(1))

    manifest = root / "scripts" / "ui_core_tests.txt"
    for line_number, raw_line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), start=1
    ):
        test_id = raw_line.strip()
        if not test_id or test_id.startswith("#"):
            continue
        parts = test_id.split("/")
        if len(parts) != 3 or any(not part for part in parts):
            errors.append(f"{manifest.relative_to(root)}:{line_number}: invalid test ID: {test_id}")
            continue
        target, class_name, test_name = parts
        if target != "MomentsUITests":
            errors.append(f"{manifest.relative_to(root)}:{line_number}: unexpected target: {test_id}")
            continue
        if test_name not in classes.get(class_name, set()):
            errors.append(f"{manifest.relative_to(root)}:{line_number}: test not found: {test_id}")
    return errors


def main() -> int:
    errors = check()
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("All core UI tests exist in their named classes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
