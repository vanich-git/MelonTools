#!/usr/bin/env python3
"""Regression tests for the two-phase release metadata gates.

Standard-library only, so it runs in the same minimal CI image as the script:

    python3 scripts/test_release_checksums.py

The fixtures are synthetic artifacts with real SHA-256 values; no release
artifact or committed manifest is ever modified.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/verify_release_checksums.py"
VERSION = "6.0.0"
ARTIFACTS = [
    f"MelonTools-{VERSION}.dmg",
    f"MelonTools-{VERSION}-setup.exe",
    f"MelonTools-{VERSION}-win-x64-portable.exe",
    f"MelonTools-{VERSION}-win-x64.exe",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


class ReleaseGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="melon-release-gate-"))
        self.artifacts = self.tmp / "release-assets"
        self.staging = self.tmp / "staged"
        self.artifacts.mkdir()
        for index, name in enumerate(ARTIFACTS):
            path = self.artifacts / name
            path.write_bytes(f"artifact-{index}-{name}".encode() * 8)
        shutil.copyfile(self.artifacts / ARTIFACTS[2], self.artifacts / ARTIFACTS[3])
        for name in ARTIFACTS:
            path = self.artifacts / name
            (self.artifacts / f"{name}.sha256").write_text(
                f"{sha256(path)}  {name}\n", encoding="utf-8"
            )
        self.run_script(
            ["--stage", VERSION, "--artifacts", str(self.artifacts),
             "--out", str(self.staging)],
            expect=0,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, arguments, expect=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if expect is not None:
            self.assertEqual(
                result.returncode,
                expect,
                msg=f"exit {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
        return result

    def verify(self, *extra, expect=0):
        return self.run_script(
            [
                "--verify-staged",
                str(self.staging),
                "--artifacts",
                str(self.artifacts),
                "--version",
                VERSION,
                *extra,
            ],
            expect=expect,
        )

    def metadata(self) -> dict:
        return json.loads((self.staging / "RELEASE_METADATA.json").read_text())

    def write_metadata(self, metadata: dict) -> None:
        (self.staging / "RELEASE_METADATA.json").write_text(
            json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
        )

    # --- accepted ------------------------------------------------------

    def test_staged_metadata_matches_real_artifacts(self) -> None:
        self.verify()
        metadata = self.metadata()
        self.assertEqual(metadata["version"], VERSION)
        for name in ARTIFACTS:
            self.assertEqual(metadata["artifacts"][name], sha256(self.artifacts / name))

    def test_published_sums_and_stable_aliases_are_checked(self) -> None:
        aliases = {
            "MelonTools.dmg": ARTIFACTS[0],
            "MelonTools-setup.exe": ARTIFACTS[1],
            "MelonTools-win-x64-portable.exe": ARTIFACTS[2],
            "MelonTools-win-x64.exe": ARTIFACTS[3],
        }
        lines = []
        for alias, versioned in aliases.items():
            shutil.copyfile(self.artifacts / versioned, self.artifacts / alias)
            lines.append(f"{sha256(self.artifacts / alias)}  {alias}")
        for name in ARTIFACTS:
            lines.append(f"{sha256(self.artifacts / name)}  {name}")
        sums = self.artifacts / "SHA256SUMS"
        sums.write_text("\n".join(sorted(lines)) + "\n", encoding="utf-8")
        self.verify("--sha256sums", str(sums))

    # --- rejected ------------------------------------------------------

    def test_rebuilt_artifact_no_longer_matches(self) -> None:
        with (self.artifacts / ARTIFACTS[0]).open("ab") as handle:
            handle.write(b"re-signed")
        self.verify(expect=1)

    def test_hand_edited_metadata_digest_fails(self) -> None:
        metadata = self.metadata()
        metadata["artifacts"][ARTIFACTS[1]] = "0" * 64
        self.write_metadata(metadata)
        result = self.verify(expect=1)
        self.assertIn("does not match", result.stdout)

    def test_metadata_without_generated_provenance_fails(self) -> None:
        metadata = self.metadata()
        metadata["generated_by"] = "hand written"
        self.write_metadata(metadata)
        self.verify(expect=1)

    def test_missing_required_artifact_fails(self) -> None:
        metadata = self.metadata()
        del metadata["artifacts"][ARTIFACTS[2]]
        self.write_metadata(metadata)
        self.verify(expect=1)

    def test_extra_versioned_artifact_fails(self) -> None:
        extra = self.artifacts / f"MelonTools-{VERSION}-extra.exe"
        extra.write_bytes(b"unexpected")
        self.verify(expect=1)

    def test_missing_published_sibling_fails(self) -> None:
        (self.artifacts / f"{ARTIFACTS[0]}.sha256").unlink()
        self.verify(expect=1)

    def test_wrong_published_sibling_fails(self) -> None:
        (self.artifacts / f"{ARTIFACTS[0]}.sha256").write_text(
            f"{'a' * 64}  {ARTIFACTS[0]}\n", encoding="utf-8"
        )
        self.verify(expect=1)

    def test_tampered_staged_sums_fails(self) -> None:
        sums = self.staging / "SHA256SUMS"
        text = sums.read_text(encoding="utf-8")
        sums.write_text(
            text.replace(self.metadata()["artifacts"][ARTIFACTS[0]], "b" * 64, 1),
            encoding="utf-8",
        )
        self.verify(expect=1)

    def test_stable_alias_that_is_not_a_copy_fails(self) -> None:
        alias = self.artifacts / "MelonTools.dmg"
        alias.write_bytes(b"different bytes")
        sums = self.artifacts / "SHA256SUMS"
        sums.write_text(f"{sha256(alias)}  MelonTools.dmg\n", encoding="utf-8")
        self.verify("--sha256sums", str(sums), expect=1)

    def test_version_mismatch_fails(self) -> None:
        self.run_script(
            [
                "--verify-staged",
                str(self.staging),
                "--artifacts",
                str(self.artifacts),
                "--version",
                "6.0.1",
            ],
            expect=1,
        )

    def test_unsafe_artifact_name_fails(self) -> None:
        metadata = self.metadata()
        metadata["artifacts"]["../escape.dmg"] = "c" * 64
        self.write_metadata(metadata)
        self.verify(expect=1)

    def test_verify_staged_cannot_write_manifests(self) -> None:
        self.run_script(
            [
                "--verify-staged",
                str(self.staging),
                "--artifacts",
                str(self.artifacts),
                "--write",
            ],
            expect=1,
        )

    def test_warn_only_cannot_soften_the_build_gate(self) -> None:
        self.verify("--warn-only", expect=1)
        self.verify("--warn-on-hash-drift", expect=1)

    def test_prerelease_artifact_in_stable_draft_fails(self) -> None:
        # Before prerelease support this name parsed as version "6.0.0" and
        # slipped past the coverage check, so an RC could ship in a stable draft.
        (self.artifacts / f"MelonTools-{VERSION}-rc.1.dmg").write_bytes(b"rc")
        result = self.verify(expect=1)
        self.assertIn("not covered", result.stdout)

    def test_staging_does_not_touch_committed_manifests(self) -> None:
        cask = ROOT / "packaging/homebrew/Casks/melon-tools.rb"
        before = cask.read_bytes()
        self.run_script(
            ["--stage", VERSION, "--artifacts", str(self.artifacts),
             "--out", str(self.tmp / "second-stage")],
            expect=0,
        )
        self.assertEqual(cask.read_bytes(), before)


PRERELEASE = "6.0.0-rc.1"
PRERELEASE_ARTIFACTS = [
    f"MelonTools-{PRERELEASE}.dmg",
    f"MelonTools-{PRERELEASE}-setup.exe",
    f"MelonTools-{PRERELEASE}-win-x64-portable.exe",
    f"MelonTools-{PRERELEASE}-win-x64.exe",
]


class PrereleaseGateTests(unittest.TestCase):
    """The same gates must accept a -PRERELEASE version and its file names.

    The tags are built from real artifacts: a prerelease must never be waved
    through with placeholder hashes, and its metadata must keep the full
    version instead of the numeric core.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="melon-release-rc-"))
        self.artifacts = self.tmp / "release-assets"
        self.staging = self.tmp / "staged"
        self.artifacts.mkdir()
        for index, name in enumerate(PRERELEASE_ARTIFACTS):
            (self.artifacts / name).write_bytes(f"rc-artifact-{index}-{name}".encode() * 8)
        shutil.copyfile(
            self.artifacts / PRERELEASE_ARTIFACTS[2],
            self.artifacts / PRERELEASE_ARTIFACTS[3],
        )
        for name in PRERELEASE_ARTIFACTS:
            path = self.artifacts / name
            (self.artifacts / f"{name}.sha256").write_text(
                f"{sha256(path)}  {name}\n", encoding="utf-8"
            )
        self.run_script(
            ["--stage", PRERELEASE, "--artifacts", str(self.artifacts),
             "--out", str(self.staging)],
            expect=0,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, arguments, expect=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if expect is not None:
            self.assertEqual(
                result.returncode,
                expect,
                msg=f"exit {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
        return result

    def verify(self, *extra, expect=0):
        return self.run_script(
            [
                "--verify-staged",
                str(self.staging),
                "--artifacts",
                str(self.artifacts),
                "--version",
                PRERELEASE,
                *extra,
            ],
            expect=expect,
        )

    def test_metadata_keeps_the_full_prerelease_version(self) -> None:
        self.verify()
        metadata = json.loads(
            (self.staging / "RELEASE_METADATA.json").read_text(encoding="utf-8")
        )
        self.assertEqual(metadata["version"], PRERELEASE)
        cask = (self.staging / "homebrew/Casks/melon-tools.rb").read_text(
            encoding="utf-8"
        )
        self.assertIn(PRERELEASE, cask)
        self.assertIn("MelonTools-#{version}.dmg", cask)

    def test_verify_rejects_a_numeric_core_only(self) -> None:
        result = self.run_script(
            ["--verify-staged", str(self.staging), "--artifacts",
             str(self.artifacts), "--version", VERSION],
            expect=1,
        )
        self.assertIn("does not match staged metadata", result.stdout)

    def test_malformed_prerelease_is_rejected(self) -> None:
        for bad in ("6.0.0-", "6.0.0_rc1", "6.0.0-rc 1"):
            result = self.run_script(
                ["--stage", bad, "--artifacts", str(self.artifacts),
                 "--out", str(self.tmp / "bad")],
                expect=1,
            )
            self.assertIn("MAJOR.MINOR.PATCH", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
