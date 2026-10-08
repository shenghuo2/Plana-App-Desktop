"""Exercise packaging and failures with macOS command substitutes on Linux."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parent
SHELL = os.environ.get("PLANA_TEST_BASH", "/bin/bash")
COMMAND = r'''#!/usr/bin/env python3
import json, os
from pathlib import Path
import sys

root = Path(os.environ["PLANA_ARM64_FIXTURE"])
args = sys.argv[1:]
command = Path(sys.argv[0]).name
log = root / "commands.jsonl"
with log.open("a") as stream:
    stream.write(json.dumps([command, *args]) + "\n")

if command == "flutter":
    assert args == ["build", "macos", "--release", "--no-pub"], args
    config = (root / "macos/Flutter/Flutter-Release.xcconfig").read_text()
    assert "EXCLUDED_ARCHS = x86_64" in config
    sys.exit(int(os.environ.get("PLANA_ARM64_FLUTTER_STATUS", "0")))
elif command == "file":
    path = Path(args[-1])
    if path.suffix == ".macho":
        print("Mach-O universal binary")
    else:
        print("ASCII text")
elif command == "lipo":
    if args[0] == "-archs":
        assert len(args) == 2
        print(" ".join(json.loads(Path(args[1]).read_text())["architectures"]))
    else:
        assert len(args) == 5 and args[1:4] == ["-thin", "arm64", "-output"], args
        data = json.loads(Path(args[0]).read_text())
        assert "arm64" in data["architectures"]
        data["architectures"] = ["arm64"]
        Path(args[4]).write_text(json.dumps(data))
elif command == "stat":
    assert args[:2] == ["-f", "%Lp"]
    print(format(Path(args[2]).stat().st_mode & 0o7777, "o"))
elif command == "codesign":
    if "--force" in args:
        assert "--deep" in args and "--sign" in args
        assert "--preserve-metadata=identifier,entitlements,requirements,flags,runtime" in args
        assert all(json.loads(p.read_text())["architectures"] == ["arm64"]
                   for p in Path(args[-1]).rglob("*.macho"))
        (root / "signed").write_text("signed after thinning")
        sys.exit(int(os.environ.get("PLANA_ARM64_SIGN_STATUS", "0")))
    assert "--verify" in args and (root / "signed").exists()
else:
    raise AssertionError(command)
'''


class Arm64PackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plana arm64's ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "build/macos/Build/Products/Release/Plana App Desktop.app"
        self.app.mkdir(parents=True)
        self.config = self.root / "macos/Flutter/Flutter-Release.xcconfig"
        self.config.parent.mkdir(parents=True)
        self.original_config = b'#include "ephemeral/Flutter-Generated.xcconfig"\r\n'
        self.config.write_bytes(self.original_config)
        tools = self.root / "tool"
        tools.mkdir()
        for script in ["build_macos_arm64.sh", "verify_macos_arm64.sh"]:
            shutil.copyfile(TOOLS / script, tools / script)
        commands = self.root / "bin"
        commands.mkdir()
        for name in ["flutter", "file", "lipo", "stat", "codesign"]:
            file = commands / name
            file.write_text(COMMAND)
            file.chmod(0o755)
        self.env = dict(os.environ, PLANA_ARM64_FIXTURE=str(self.root))
        self.env["PATH"] = str(commands) + os.pathsep + self.env["PATH"]

    def binary(self, name, architectures, mode=0o755):
        file = self.app / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps({"architectures": architectures, "payload": "unchanged"}))
        file.chmod(mode)
        return file

    def run_script(self, name, *args, **env):
        return subprocess.run(
            [SHELL, str(self.root / "tool" / name), *map(str, args)],
            env=dict(self.env, **env), text=True, capture_output=True, timeout=15,
        )

    def calls(self):
        file = self.root / "commands.jsonl"
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def test_thins_all_binaries_preserves_modes_and_restores_config(self):
        main = self.binary("Contents/MacOS/Plana App.macho", ["x86_64", "arm64"], 0o751)
        framework = self.binary("Contents/Frameworks/Flutter.framework/Versions/A/Flutter.macho", ["arm64", "x86_64"], 0o644)
        single = self.binary("Contents/Frameworks/App.framework/Versions/A/App.macho", ["arm64"])
        link = self.app / "Contents/Frameworks/Flutter.framework/Flutter.macho"
        link.symlink_to("Versions/A/Flutter.macho")
        asset = self.app / "Contents/Resources/asset.txt"
        asset.parent.mkdir(parents=True)
        asset.write_text("asset unchanged")
        result = self.run_script("build_macos_arm64.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for binary in [main, framework, single]:
            self.assertEqual(json.loads(binary.read_text()), {"architectures": ["arm64"], "payload": "unchanged"})
        self.assertEqual(main.stat().st_mode & 0o777, 0o751)
        self.assertEqual(framework.stat().st_mode & 0o777, 0o644)
        self.assertTrue(link.is_symlink())
        self.assertEqual(asset.read_text(), "asset unchanged")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        calls = self.calls()
        thin_calls = [call for call in calls if call[0] == "lipo" and "-thin" in call]
        self.assertEqual(len(thin_calls), 2)
        signing = next(i for i, call in enumerate(calls) if call[0] == "codesign" and "--force" in call)
        self.assertTrue(all(calls.index(call) < signing for call in thin_calls))

    def test_intel_only_dependency_fails_before_signing(self):
        self.binary("Contents/Frameworks/Plugin.macho", ["x86_64"])
        result = self.run_script("build_macos_arm64.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing arm64 slice", result.stderr)
        self.assertFalse((self.root / "signed").exists())
        self.assertEqual(self.config.read_bytes(), self.original_config)

    def test_flutter_failure_restores_config_and_stops(self):
        result = self.run_script("build_macos_arm64.sh", PLANA_ARM64_FLUTTER_STATUS="9")
        self.assertEqual(result.returncode, 9)
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertFalse((self.root / "signed").exists())

    def test_signing_failure_stops_and_restores_config(self):
        self.binary("Contents/MacOS/Plana App.macho", ["arm64"])
        result = self.run_script("build_macos_arm64.sh", PLANA_ARM64_SIGN_STATUS="7")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.config.read_bytes(), self.original_config)

    def test_build_rejects_x64_request(self):
        result = self.run_script("build_macos_arm64.sh", "x64")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(self.calls(), [])

    def test_build_rejects_bundle_without_native_binaries(self):
        result = self.run_script("build_macos_arm64.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Mach-O binaries", result.stderr)
        self.assertFalse((self.root / "signed").exists())
        self.assertEqual(self.config.read_bytes(), self.original_config)

    def test_packaged_app_rejects_dual_architecture_framework(self):
        self.binary("Contents/MacOS/Plana App.macho", ["arm64"])
        self.binary("Contents/Frameworks/Flutter.macho", ["arm64", "x86_64"])
        result = self.run_script("verify_macos_arm64.sh", self.app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected only arm64", result.stderr)

    def test_packaged_app_accepts_only_arm64(self):
        self.binary("Contents/MacOS/Plana App.macho", ["arm64"])
        result = self.run_script("verify_macos_arm64.sh", self.app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_packaged_app_rejects_empty_bundle(self):
        result = self.run_script("verify_macos_arm64.sh", self.app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Mach-O binaries", result.stderr)

    def test_packaged_app_requires_bundle_argument(self):
        result = self.run_script("verify_macos_arm64.sh")
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
