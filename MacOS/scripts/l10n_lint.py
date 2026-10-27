#!/usr/bin/env python3
"""Check the Swift localization table for duplicate and missing keys.

Swift dictionary literals trap at runtime on a duplicate key, and the crash
only happens the first time the table is touched. This lint is stdlib-only and
runs in CI before the app is built:

    python3 MacOS/scripts/l10n_lint.py

Exit codes: 0 = clean, 1 = duplicate key or missing key.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "MacOS/app/MelonTools"
L10N = APP / "Design/L10n.swift"
TABLE_START = re.compile(r"static let ru: \[String: String\] = \[")
ENTRY = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*:')
CALL = re.compile(r'\bL\("((?:\\.|[^"\\])*)"\)')


def swift_string(literal: str) -> str:
    """Decode the subset of Swift string escapes used in the table."""
    body = literal[1:-1]
    return (
        body.replace(r"\\", "\x00")
        .replace(r"\"", '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
        .replace("\x00", "\\")
    )


def table_keys(text: str) -> list[str]:
    match = TABLE_START.search(text)
    if not match:
        raise SystemExit("l10n_lint: `static let ru` table not found")
    end = text.find("\n    ]", match.end())
    if end < 0:
        raise SystemExit("l10n_lint: end of the `ru` table not found")
    keys: list[str] = []
    for line in text[match.end() : end].splitlines():
        entry = ENTRY.match(line)
        if entry:
            keys.append(swift_string(entry.group(1)))
    return keys


def main() -> int:
    source = L10N.read_text(encoding="utf-8")
    keys = table_keys(source)
    seen: dict[str, int] = {}
    duplicates: list[tuple[str, int]] = []
    for index, key in enumerate(keys, 1):
        if key in seen:
            duplicates.append((key, index))
        else:
            seen[key] = index

    used: dict[str, str] = {}
    for path in sorted(APP.rglob("*.swift")):
        # The table file mentions L("...") only in the translator comment.
        if path == L10N:
            continue
        text = path.read_text(encoding="utf-8")
        for match in CALL.finditer(text):
            literal = match.group(1)
            key = swift_string('"' + literal + '"')
            used.setdefault(key, str(path.relative_to(ROOT)))
    missing = sorted(key for key in used if key not in seen)

    if duplicates:
        print(f"l10n_lint: {len(duplicates)} duplicate key(s) in the ru table", file=sys.stderr)
        for key, line in duplicates:
            print(f"  duplicate {key!r} (first at line {seen[key]}, again at {line})", file=sys.stderr)
    if missing:
        print(f"l10n_lint: {len(missing)} L() key(s) missing from the ru table", file=sys.stderr)
        for key in missing:
            print(f"  missing {key!r} (used by {used[key]})", file=sys.stderr)
    if duplicates or missing:
        return 1
    print(f"l10n ok: {len(keys)} keys, {len(used)} L() call sites")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
