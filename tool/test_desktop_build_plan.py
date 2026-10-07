"""Release planning checks without contacting GitHub or building installers."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import desktop_build_plan as plan


class BuildPlanTest(unittest.TestCase):
    @contextmanager
    def run_plan(self, **overrides):
        env = {
            "BUILD_EVENT": "workflow_dispatch",
            "BUILD_EDITIONS": "both",
            "BUILD_BRANCH": "feature/remote-upload",
            "BUILD_REF_TYPE": "branch",
            "BUILD_SHA": "push-sha",
            "STANDARD_BRANCH": "desktop/merge-windows45",
            "REMOTE_BRANCH": "feature/remote-upload",
            "BUILD_WINDOWS": "false",
        }
        env.update(overrides)

        def entry(edition, branch, sha):
            return {"edition": edition, "branch": branch, "sha": sha, "version": "1.1.2-desktop+65"}

        with tempfile.TemporaryDirectory() as root:
            previous = os.getcwd()
            os.chdir(root)
            env["GITHUB_OUTPUT"] = str(Path(root) / "outputs")
            try:
                with patch.dict(os.environ, env), patch.object(plan, "branch_sha", side_effect=lambda branch: f"{branch}-sha"), patch.object(plan, "entry", side_effect=entry):
                    yield
            finally:
                os.chdir(previous)

    def outputs(self):
        return dict(line.split("=", 1) for line in Path("outputs").read_text().splitlines())

    def test_paired_dispatch_without_windows(self):
        with self.run_plan():
            plan.main()
            outputs = self.outputs()
            entries = json.loads(outputs["matrix"])["include"]
            self.assertEqual([e["edition"] for e in entries], ["standard", "remoteUpload"])
            self.assertEqual(outputs["standard_sha"], "desktop/merge-windows45-sha")
            self.assertEqual(outputs["build_windows"], "false")

    def test_feature_push_never_builds_windows(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_WINDOWS="true"):
            plan.main()
            outputs = self.outputs()
            self.assertEqual(json.loads(outputs["matrix"])["include"][0]["sha"], "push-sha")
            self.assertEqual(len(json.loads(outputs["matrix"])["include"]), 1)
            self.assertEqual(outputs["build_windows"], "false")

    def test_release_tag_builds_both_and_pins_standard_to_tag(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_REF_TYPE="tag", BUILD_BRANCH="v1.1.2-desktop", BUILD_SHA="tag-sha"):
            plan.main()
            outputs = self.outputs()
            entries = json.loads(outputs["matrix"])["include"]
            self.assertEqual([e["edition"] for e in entries], ["standard", "remoteUpload"])
            self.assertEqual(outputs["standard_sha"], "tag-sha")

    def test_release_tag_must_match_source_version(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_REF_TYPE="tag", BUILD_BRANCH="v1.1.3-desktop"):
            with self.assertRaisesRegex(ValueError, "tag does not match"):
                plan.main()

    def test_mixed_version_or_build_is_rejected(self):
        for other in ["1.1.3-desktop+65", "1.1.2-desktop+66"]:
            with self.assertRaises(ValueError):
                plan.validate_versions([{"version": "1.1.2-desktop+65"}, {"version": other}])

    def test_source_must_identify_its_edition(self):
        def git(*args):
            if args[0] == "show":
                return "version: 1.1.2-desktop+65" if args[1].endswith("pubspec.yaml") else "const kDesktopEdition = DesktopEdition.standard;"
            return ""
        with patch.object(plan, "git", side_effect=git):
            with self.assertRaisesRegex(ValueError, "not the remoteUpload edition"):
                plan.entry("remoteUpload", "feature/remote-upload", "remote-sha")


if __name__ == "__main__":
    unittest.main()
