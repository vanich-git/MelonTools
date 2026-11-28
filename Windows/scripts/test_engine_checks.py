#!/usr/bin/env python3
"""Unit tests for the Windows engine provenance and payload checks."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("verify-engine.py")
SPEC = importlib.util.spec_from_file_location("verify_engine", SCRIPT)
assert SPEC and SPEC.loader
verify_engine = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verify_engine
SPEC.loader.exec_module(verify_engine)

PATCHES = {
    "0001-a.patch": b"a",
    "0002-b.patch": b"bb",
}
PATCH_DIGESTS = {name: hashlib.sha256(data).hexdigest() for name, data in PATCHES.items()}
SOURCE_STATE = verify_engine.sha256(b"".join(
    (name + "\n").encode() + bytes.fromhex(PATCH_DIGESTS[name]) for name in sorted(PATCH_DIGESTS)
))


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "MacOS/patches").mkdir(parents=True)
        for name, data in PATCHES.items():
            (self.root / "MacOS/patches" / name).write_bytes(data)

    def test_exact_patch_set_passes(self):
        provenance = {
            "build": {
                "sourceState": SOURCE_STATE,
                "patchSha256": PATCH_DIGESTS,
                "command": "GOOS=windows GOARCH=amd64 -trimpath -s -w -buildvcs=false",
            }
        }
        errors, warnings = verify_engine.check_current_patches(
            provenance, verify_engine.patch_files(self.root)
        )
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_legacy_provenance_is_warning_not_mismatch(self):
        provenance = {
            "build": {
                "sourceState": "pinned checkout with MacOS/patches/*.patch applied",
                "command": "GOOS=windows GOARCH=amd64 -trimpath -s -w",
            }
        }
        errors, warnings = verify_engine.check_current_patches(
            provenance, verify_engine.patch_files(self.root)
        )
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("unverified", warnings[0])

    def test_malformed_digest_does_not_crash(self):
        provenance = {
            "build": {
                "sourceState": "0" * 64,
                "patchSha256": {**PATCH_DIGESTS, "0001-a.patch": "not-a-digest"},
                "command": "GOOS=windows GOARCH=amd64 -trimpath -s -w -buildvcs=false",
            }
        }
        errors, _ = verify_engine.check_current_patches(
            provenance, verify_engine.patch_files(self.root)
        )
        self.assertIn("build.patchSha256[0001-a.patch] is not a 64-hex digest", errors)
        self.assertIn("build.patchSha256 has malformed digests", errors)

    def test_changed_patch_and_missing_flag_fail(self):
        provenance = {
            "build": {
                "sourceState": "0" * 64,
                "patchSha256": {**PATCH_DIGESTS, "0001-a.patch": "1" * 64},
                "command": "GOOS=windows GOARCH=amd64 -trimpath -s -w",
            }
        }
        errors, _ = verify_engine.check_current_patches(
            provenance, verify_engine.patch_files(self.root)
        )
        self.assertIn("patch sha256 mismatch: 0001-a.patch", errors)
        self.assertIn("build.command is missing -buildvcs=false", errors)


class BuildScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = pathlib.Path(__file__).with_name("build-engine.sh")
        cls.body = script.read_text(encoding="utf-8")
        start = cls.body.index("python3 - \"$BUILD_DIR/cliproxyapi.exe\"")
        heredoc = cls.body.index("<<'PY'\n", start) + len("<<'PY'\n")
        cls.embedded = cls.body[heredoc:cls.body.index("\nPY\n", heredoc)]
        start = cls.body.index('python3 - "$PROVENANCE" "$ROOT" "$BUILD_DIR/cliproxyapi.exe"')
        heredoc = cls.body.index("<<'PY'\n", start) + len("<<'PY'\n")
        cls.publisher = cls.body[heredoc:cls.body.index("\nPY\n", heredoc)]

    def test_no_vendor_reset_or_clean(self):
        self.assertNotIn("git clean", self.body)
        self.assertNotIn("git checkout --quiet --force \"$SRC\"", self.body)
        self.assertIn("git clone --quiet --shared \"$SRC\" \"$CHECKOUT\"", self.body)

    def test_reproducible_build_flags(self):
        self.assertIn("-trimpath -buildvcs=false -ldflags", self.body)
        self.assertIn("GOTOOLCHAIN=\"$GO_TOOLCHAIN\"", self.body)
        for env in ("HOME", "TMPDIR", "GOCACHE", "GOMODCACHE", "GOPATH"):
            self.assertIn(f"export {env}=\"$TMP", self.body)

    def test_write_updates_both_files(self):
        self.assertIn("os.replace(staged_blob, target_path)", self.body)
        self.assertIn("os.replace(staged_provenance, provenance_path)", self.body)
        self.assertIn("provenance[\"payload\"]", self.body)
        self.assertIn("provenance[\"compressed\"]", self.body)
        self.assertIn("provenance[\"build\"][\"patchSha256\"]", self.body)
        self.assertIn("provenance_path.write_bytes(original_provenance)", self.body)
        self.assertIn("target_path.write_bytes(original_blob)", self.body)

    def test_publish_updates_blob_and_verifiable_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            patches = root / "MacOS/patches"
            patches.mkdir(parents=True)
            for name, data in PATCHES.items():
                (patches / name).write_bytes(data)
            provenance = root / "engine-provenance.json"
            provenance.write_text(json.dumps({"build": {}, "goToolchain": "go1.26.10"}), encoding="utf-8")
            payload, packed, target = (root / name for name in ("engine.exe", "engine.z", "resource.z"))
            payload.write_bytes(b"new payload")
            packed.write_bytes(b"new compressed payload")
            target.write_bytes(b"old resource")
            proc = subprocess.run(
                [sys.executable, "-", str(provenance), str(root), str(payload), str(packed), str(target)],
                input=self.publisher, text=True, capture_output=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(target.read_bytes(), packed.read_bytes())
            result = json.loads(provenance.read_text(encoding="utf-8"))
            self.assertEqual(result["payload"]["sha256"], verify_engine.sha256(payload.read_bytes()))
            self.assertEqual(result["compressed"]["sha256"], verify_engine.sha256(packed.read_bytes()))
            errors, warnings = verify_engine.check_current_patches(result, verify_engine.patch_files(root))
            self.assertEqual(errors, [])
            self.assertEqual(warnings, [])

    def test_payload_check_rejects_zeroed_pe(self):
        payload = bytearray(b"MZ" + b"\x90" * 0x1000)
        pe = 0x80
        struct.pack_into("<I", payload, 0x3C, pe)
        struct.pack_into("<HH", payload, pe + 4, 0x8664, 1)
        payload[pe:pe + 4] = b"PE\0\0"
        struct.pack_into("<H", payload, pe + 20, 240)
        struct.pack_into("<H", payload, pe + 24, 0x20B)
        struct.pack_into("<II", payload, pe + 24 + 32, 0x1000, 0x200)
        struct.pack_into("<II", payload, pe + 24 + 56, 0x3000, 0x200)
        struct.pack_into("<I", payload, pe + 24 + 64, 0)
        struct.pack_into("<H", payload, pe + 24 + 68, 3)
        struct.pack_into("<I", payload, pe + 24 + 16, 0x1000)
        section = pe + 24 + 240
        struct.pack_into("<IIII", payload, section + 8, 0x200, 0x1000, 0x200, 0x200)
        struct.pack_into("<I", payload, section + 36, 0)
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "payload.exe"
            path.write_bytes(payload)
            provenance_path = pathlib.Path(tmp) / "engine-provenance.json"
            provenance_path.write_text("{}", encoding="utf-8")
            proc = self.run_check(path, pathlib.Path(tmp) / "engine.z", provenance_path, write=False)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no substantial code section", proc.stderr)

    @staticmethod
    def run_check(payload: pathlib.Path, packed: pathlib.Path, provenance: pathlib.Path, write: bool):
        program = BuildScriptTests.embedded.split("PY\n", 1)[0]
        return subprocess.run(
            [sys.executable, "-", str(payload), str(packed), str(provenance), "1" if write else "0"],
            input=program,
            text=True,
            capture_output=True,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
