"""Check complete release sets and partial development builds."""

import hashlib
from pathlib import Path
import tempfile
import unittest

from desktop_release_checksums import write_checksums


STANDARD = "Plana-App-Desktop-macOS-arm64.dmg"
REMOTE = "Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg"
WINDOWS = "Plana-App-Desktop-Windows-1.2.1-desktop-x64"


class ReleaseChecksumsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.artifacts = self.root / "artifacts"
        self.output = self.root / "output/SHA256SUMS.txt"
        self.plan = {"include": [
            {"edition": "standard", "version": "1.2.1-desktop+70", "dmg": STANDARD},
            {"edition": "remoteUpload", "version": "1.2.1-desktop+70", "dmg": REMOTE},
        ]}

    def package(self, name, folder="build"):
        path = self.artifacts / folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(name.encode())
        return path

    def generate(self, windows=False):
        return write_checksums(self.artifacts, self.plan, self.output, windows)

    def test_four_packages_share_one_standard_checksum_file(self):
        names = [STANDARD, REMOTE, WINDOWS + ".zip", WINDOWS + "-setup.exe"]
        for i, name in enumerate(names):
            self.package(name, f"edition-{i}")
        self.package(STANDARD + ".sha256")
        self.package("desktop-build-plan.json")
        self.assertEqual(self.generate(windows=True), 4)
        lines = self.output.read_text().splitlines()
        self.assertEqual([line.split("  ")[1] for line in lines], sorted(names))
        for line in lines:
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256(name.encode()).hexdigest())
        self.assertTrue(self.output.read_bytes().endswith(b"\n"))

    def test_development_can_build_either_or_both_mac_editions(self):
        for entries in [[self.plan["include"][0]], [self.plan["include"][1]], self.plan["include"]]:
            with self.subTest(editions=[e["edition"] for e in entries]):
                folder = self.root / ("-".join(e["edition"] for e in entries))
                folder.mkdir()
                for entry in entries:
                    (folder / entry["dmg"]).write_bytes(b"image")
                self.assertEqual(write_checksums(folder, {"include": entries}, self.output), len(entries))

    def test_missing_windows_installer_rejects_incomplete_release(self):
        for name in [STANDARD, REMOTE, WINDOWS + ".zip"]:
            self.package(name)
        with self.assertRaisesRegex(ValueError, "missing=.*setup.exe"):
            self.generate(windows=True)
        self.assertFalse(self.output.exists())

    def test_missing_mac_edition_is_rejected(self):
        self.package(STANDARD)
        with self.assertRaisesRegex(ValueError, "missing=.*RemoteUpload"):
            self.generate()

    def test_unexpected_package_is_rejected(self):
        for name in [STANDARD, REMOTE, "unrelated.zip"]:
            self.package(name)
        with self.assertRaisesRegex(ValueError, "unexpected=.*unrelated.zip"):
            self.generate()

    def test_duplicate_package_names_are_rejected(self):
        self.package(STANDARD, "first")
        self.package(STANDARD, "second")
        with self.assertRaisesRegex(ValueError, "Duplicate package"):
            self.generate()

    def test_mixed_versions_are_rejected(self):
        self.plan["include"][1]["version"] = "1.2.1-desktop+71"
        with self.assertRaisesRegex(ValueError, "versions differ"):
            self.generate()

    def test_windows_requires_standard_edition(self):
        self.plan["include"] = [self.plan["include"][1]]
        with self.assertRaisesRegex(ValueError, "Windows requires"):
            self.generate(windows=True)

    def test_invalid_plan_is_rejected(self):
        for entries in [[], [self.plan["include"][0]] * 2,
                        [{"edition": "other", "version": "1.2.1-desktop+70", "dmg": STANDARD}]]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                write_checksums(self.artifacts, {"include": entries}, self.output)


if __name__ == "__main__":
    unittest.main()
