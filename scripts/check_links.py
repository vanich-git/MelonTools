#!/usr/bin/env python3
"""Check the external links used in the repository documentation.

The checker uses ``HEAD`` requests and treats the result in two classes:

* **missing** — ``404``/``410``. The link is broken; the script exits 1.
* **inconclusive** — timeouts, connection errors, ``429``, ``5xx`` and
  ``401``/``403``. These are common on shared CI IPs and must not fail a build.

Pass ``--strict`` to fail on inconclusive results as well. The script is
standard-library only and never writes to the repository.

Examples::

    python3 scripts/check_links.py
    python3 scripts/check_links.py --timeout 30 --strict
    GITHUB_TOKEN=... python3 scripts/check_links.py
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

ROOT = Path(__file__).resolve().parents[1]
URL = re.compile(r"https?://[^\s<>\"')\]]+")
DEFAULT_FILES = [
    "README.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "MacOS/README.md",
    "MacOS/RELEASE_NOTES.md",
    "Windows/README.md",
    "packaging/README.md",
]


def clean_url(raw: str) -> str:
    url = raw.rstrip(".,;:!?")
    # Markdown sometimes wraps a URL in parentheses.
    while url.endswith(")") and url.count("(") < url.count(")"):
        url = url[:-1]
    return url


def collect_files(extra: Iterable[str]) -> List[Path]:
    files: List[Path] = []
    for name in [*DEFAULT_FILES, *extra]:
        path = ROOT / name
        if path.is_file() and path not in files:
            files.append(path)
    for path in sorted((ROOT / "docs").glob("*.md")):
        if path.is_file() and path not in files:
            files.append(path)
    return files


def collect_urls(files: Iterable[Path]) -> Dict[str, List[str]]:
    links: Dict[str, List[str]] = {}
    for path in files:
        text = path.read_text(encoding="utf-8")
        for match in URL.finditer(text):
            url = clean_url(match.group(0))
            if not url or "{" in url or "<" in url:
                continue
            links.setdefault(url, []).append(str(path.relative_to(ROOT)))
    return links


def request_headers(token: Optional[str]) -> Dict[str, str]:
    headers = {"User-Agent": "melontools-link-check/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def probe(url: str, token: Optional[str], timeout: float) -> Tuple[str, str]:
    """Return (status, detail) with status ok|missing|inconclusive."""
    headers = request_headers(token)
    for method in ("HEAD", "GET"):
        request = urllib.request.Request(url, method=method, headers=headers)
        if method == "GET":
            request.add_header("Range", "bytes=0-0")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return "ok", f"{response.status}"
        except urllib.error.HTTPError as error:
            code = error.code
            if method == "HEAD" and code in (403, 405, 501):
                continue
            if code in (404, 410):
                return "missing", f"HTTP {code}"
            if code in (401, 403):
                return "inconclusive", f"HTTP {code} (auth or rate limit)"
            if code == 429 or 500 <= code < 600:
                return "inconclusive", f"HTTP {code}"
            return "inconclusive", f"HTTP {code}"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            if method == "HEAD":
                continue
            reason = getattr(error, "reason", error)
            return "inconclusive", f"network error: {reason}"
    return "inconclusive", "no usable response"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        action="append",
        default=[],
        help="extra Markdown file to scan (may be repeated)",
    )
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail on transient network errors as well as 404/410",
    )
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    files = collect_files(args.file)
    links = collect_urls(files)
    if not links:
        print("link-check: no links found")
        return 0

    missing: List[Tuple[str, str]] = []
    inconclusive: List[Tuple[str, str]] = []

    for url, sources in sorted(links.items()):
        status, detail = "inconclusive", "not checked"
        for attempt in range(args.retries + 1):
            status, detail = probe(url, token, args.timeout)
            if status != "inconclusive" or attempt == args.retries:
                break
            time.sleep(1.0 + attempt)
        place = ", ".join(sorted(set(sources)))
        if status == "missing":
            missing.append((url, f"{place} ({detail})"))
            print(f"MISSING {url} <- {place} ({detail})")
        elif status == "inconclusive":
            inconclusive.append((url, f"{place} ({detail})"))
            if not args.quiet:
                print(f"SKIP    {url} <- {place} ({detail})")
        elif not args.quiet:
            print(f"OK      {url}")

    print(
        f"link-check: {len(links)} links, {len(missing)} missing, "
        f"{len(inconclusive)} inconclusive"
    )
    if missing or (inconclusive and args.strict):
        print("link-check: FAILED")
        return 1
    print("link-check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
