"""Check pinned release and development builds without contacting GitHub."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import desktop_build_plan as plan


VERSION = "1.2.0-desktop.1"
STANDARD_RELEASE = f"release/{VERSION}"
REMOTE_RELEASE = f"release/remote-upload/{VERSION}"


class BuildPlanTest(unittest.TestCase):
    @contextmanager
    def run_plan(self, versions=None, missing=None, **overrides):
        env = {
            "BUILD_EVENT": "workflow_dispatch",
            "BUILD_EDITIONS": "both",
            "BUILD_BRANCH": "main",
            "BUILD_REF_TYPE": "branch",
            "BUILD_SHA": "push-sha",
            "RELEASE_VERSION": "",
            "STANDARD_BRANCH": "main",
            "REMOTE_BRANCH": "feature/remote-upload",
            "BUILD_WINDOWS": "false",
        }
        env.update(overrides)

        def entry(edition, branch, sha):
            version = (versions or {}).get(edition, VERSION + "+69")
            return {"edition": edition, "branch": branch, "sha": sha, "version": version}

        def branch_sha(branch):
            if branch in (missing or []):
                raise ValueError(f"Branch not found: {branch}")
            return f"{branch}-sha"

        with tempfile.TemporaryDirectory() as root:
            previous = os.getcwd()
            os.chdir(root)
            env["GITHUB_OUTPUT"] = str(Path(root) / "outputs")
            try:
                with patch.dict(os.environ, env), patch.object(plan, "branch_sha", side_effect=branch_sha) as refs, patch.object(plan, "entry", side_effect=entry):
                    yield refs
            finally:
                os.chdir(previous)

    def outputs(self):
        return dict(line.split("=", 1) for line in Path("outputs").read_text().splitlines())

    def assert_release_sources(self):
        outputs = self.outputs()
        entries = json.loads(outputs["matrix"])["include"]
        self.assertEqual([e["edition"] for e in entries], ["standard", "remoteUpload"])
        self.assertEqual([e["branch"] for e in entries], [STANDARD_RELEASE, REMOTE_RELEASE])
        self.assertEqual(outputs["standard_sha"], STANDARD_RELEASE + "-sha")
        self.assertEqual(outputs["remote_sha"], REMOTE_RELEASE + "-sha")
        self.assertEqual(json.loads(outputs["standard"]), entries[0])
        self.assertEqual(json.loads(outputs["remote_upload"]), entries[1])

    def test_paired_development_dispatch_without_windows(self):
        with self.run_plan():
            plan.main()
            outputs = self.outputs()
            entries = json.loads(outputs["matrix"])["include"]
            self.assertEqual([e["edition"] for e in entries], ["standard", "remoteUpload"])
            self.assertEqual(outputs["standard_sha"], "main-sha")
            self.assertEqual(json.loads(outputs["standard"]), entries[0])
            self.assertEqual(json.loads(outputs["remote_upload"]), entries[1])
            self.assertEqual(outputs["remote_sha"], "feature/remote-upload-sha")
            self.assertEqual(outputs["build_windows"], "false")

    def test_standard_only_development_has_no_remote_pipeline(self):
        with self.run_plan(BUILD_EDITIONS="standard", BUILD_WINDOWS="true"):
            plan.main()
            outputs = self.outputs()
            self.assertEqual(json.loads(outputs["standard"])["edition"], "standard")
            self.assertEqual(json.loads(outputs["remote_upload"]), {})
            self.assertEqual(outputs["remote_sha"], "")
            self.assertEqual(outputs["build_windows"], "true")

    def test_remote_only_development_has_no_standard_pipeline(self):
        with self.run_plan(BUILD_EDITIONS="remote-upload", BUILD_WINDOWS="true"):
            plan.main()
            outputs = self.outputs()
            self.assertEqual(json.loads(outputs["standard"]), {})
            self.assertEqual(outputs["standard_sha"], "")
            self.assertEqual(json.loads(outputs["remote_upload"])["edition"], "remoteUpload")
            self.assertEqual(outputs["build_windows"], "false")

    def test_invalid_development_edition_is_rejected(self):
        with self.run_plan(BUILD_EDITIONS="invalid"):
            with self.assertRaisesRegex(ValueError, "Invalid edition"):
                plan.main()

    def test_main_push_builds_only_standard_at_the_pushed_commit(self):
        with self.run_plan(BUILD_EVENT="push") as refs:
            plan.main()
            entries = json.loads(self.outputs()["matrix"])["include"]
            self.assertEqual([(e["edition"], e["branch"], e["sha"]) for e in entries], [("standard", "main", "push-sha")])
            self.assertEqual(self.outputs()["build_windows"], "true")
            refs.assert_not_called()

    def test_feature_push_never_builds_windows(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_BRANCH="feature/remote-upload", BUILD_WINDOWS="true"):
            plan.main()
            outputs = self.outputs()
            entries = json.loads(outputs["matrix"])["include"]
            self.assertEqual(entries[0]["sha"], "push-sha")
            self.assertEqual(entries[0]["edition"], "remoteUpload")
            self.assertEqual(len(entries), 1)
            self.assertEqual(outputs["build_windows"], "false")

    def test_release_dispatch_uses_saved_branches_instead_of_development(self):
        with self.run_plan(RELEASE_VERSION=VERSION, BUILD_WINDOWS="true") as refs:
            plan.main()
            self.assert_release_sources()
            self.assertEqual([call.args[0] for call in refs.call_args_list], [STANDARD_RELEASE, REMOTE_RELEASE])
            self.assertEqual(self.outputs()["build_windows"], "true")

    def test_release_input_accepts_tag_prefix(self):
        with self.run_plan(RELEASE_VERSION="v" + VERSION):
            plan.main()
            self.assert_release_sources()

    def test_dispatch_from_either_release_branch_pins_both_editions(self):
        for branch in [STANDARD_RELEASE, REMOTE_RELEASE]:
            with self.subTest(branch=branch), self.run_plan(BUILD_BRANCH=branch):
                plan.main()
                self.assert_release_sources()

    def test_release_branch_push_builds_both_from_the_saved_commits(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_BRANCH=STANDARD_RELEASE, BUILD_SHA=STANDARD_RELEASE + "-sha"):
            plan.main()
            self.assert_release_sources()
            self.assertEqual(self.outputs()["build_windows"], "true")

    def test_release_branch_advanced_before_planning_is_rejected(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_BRANCH=STANDARD_RELEASE, BUILD_SHA="older-sha"):
            with self.assertRaisesRegex(ValueError, "changed after"):
                plan.main()

    def test_release_tag_must_use_the_saved_standard_commit(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_REF_TYPE="tag", BUILD_BRANCH="v" + VERSION, BUILD_SHA=STANDARD_RELEASE + "-sha"):
            plan.main()
            self.assert_release_sources()

    def test_release_tag_pointing_elsewhere_is_rejected(self):
        with self.run_plan(BUILD_EVENT="push", BUILD_REF_TYPE="tag", BUILD_BRANCH="v" + VERSION, BUILD_SHA="different-sha"):
            with self.assertRaisesRegex(ValueError, "tag does not point"):
                plan.main()

    def test_missing_release_branch_never_falls_back_to_development(self):
        for branch in [STANDARD_RELEASE, REMOTE_RELEASE]:
            with self.subTest(branch=branch), self.run_plan(RELEASE_VERSION=VERSION, missing=[branch]) as refs:
                with self.assertRaisesRegex(ValueError, "Branch not found"):
                    plan.main()
                self.assertTrue(all(call.args[0].startswith("release/") for call in refs.call_args_list))

    def test_release_version_must_match_both_sources(self):
        wrong = {edition: "1.2.0-desktop.2+69" for edition in ["standard", "remoteUpload"]}
        with self.run_plan(RELEASE_VERSION=VERSION, versions=wrong):
            with self.assertRaisesRegex(ValueError, "do not match"):
                plan.main()

    def test_release_sources_must_use_the_same_build_number(self):
        with self.run_plan(RELEASE_VERSION=VERSION, versions={"remoteUpload": VERSION + "+70"}):
            with self.assertRaisesRegex(ValueError, "build numbers differ"):
                plan.main()

    def test_release_build_requires_both_editions(self):
        for selection in ["standard", "remote-upload"]:
            with self.subTest(selection=selection), self.run_plan(RELEASE_VERSION=VERSION, BUILD_EDITIONS=selection):
                with self.assertRaisesRegex(ValueError, "both editions"):
                    plan.main()

    def test_release_input_must_match_selected_release_branch(self):
        with self.run_plan(BUILD_BRANCH=STANDARD_RELEASE, RELEASE_VERSION="1.2.0-desktop.2"):
            with self.assertRaisesRegex(ValueError, "differs from"):
                plan.main()

    def test_invalid_release_version_is_rejected_before_resolving_refs(self):
        for version in ["v", "1.2.0.1", "1.2.0-desktop.1+69", "1.2.0-desktop.1/other", "../main"]:
            with self.subTest(version=version), self.run_plan(RELEASE_VERSION=version) as refs:
                with self.assertRaisesRegex(ValueError, "Invalid desktop release version"):
                    plan.main()
                refs.assert_not_called()

    def test_mixed_version_or_build_is_rejected(self):
        for other in ["1.2.0-desktop.2+69", VERSION + "+70"]:
            with self.assertRaises(ValueError):
                plan.validate_versions([{"version": VERSION + "+69"}, {"version": other}])

    def test_real_git_release_build_keeps_old_sources_after_development_advances(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, origin, builder = root / "source", root / "origin.git", root / "builder"

            def git(*args, cwd=source):
                return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()

            git("init", "--quiet", "-b", "main", str(source), cwd=root)
            git("config", "user.name", "Build plan test")
            git("config", "user.email", "build-plan@example.invalid")
            git("config", "commit.gpgsign", "false")
            git("config", "core.hooksPath", "/dev/null")
            edition_file = source / "lib/core/desktop_edition.dart"
            edition_file.parent.mkdir(parents=True)
            (source / "pubspec.yaml").write_text(f"version: {VERSION}+69\n")
            edition_file.write_text("const kDesktopEdition = DesktopEdition.standard;\n")
            git("add", ".")
            git("commit", "--quiet", "-m", "Standard release")
            standard_sha = git("rev-parse", "HEAD")
            git("branch", STANDARD_RELEASE)
            git("switch", "--quiet", "-c", "feature/remote-upload")
            edition_file.write_text("const kDesktopEdition = DesktopEdition.remoteUpload;\n")
            git("commit", "--quiet", "-am", "Remote upload release")
            remote_sha = git("rev-parse", "HEAD")
            git("branch", REMOTE_RELEASE)
            for branch in ["main", "feature/remote-upload"]:
                git("switch", "--quiet", branch)
                (source / "pubspec.yaml").write_text("version: 1.2.0-desktop.2+70\n")
                git("commit", "--quiet", "-am", "Next development version")
            git("init", "--quiet", "--bare", str(origin), cwd=root)
            git("push", "--quiet", "--all", str(origin))
            git("init", "--quiet", str(builder), cwd=root)
            git("remote", "add", "origin", str(origin), cwd=builder)
            env = {"BUILD_EVENT": "workflow_dispatch", "BUILD_BRANCH": "main", "BUILD_REF_TYPE": "branch", "BUILD_SHA": "unused", "BUILD_EDITIONS": "both", "BUILD_WINDOWS": "true", "RELEASE_VERSION": VERSION, "STANDARD_BRANCH": "main", "REMOTE_BRANCH": "feature/remote-upload", "GITHUB_OUTPUT": str(builder / "outputs")}
            previous = os.getcwd()
            try:
                os.chdir(builder)
                with patch.dict(os.environ, env):
                    plan.main()
                entries = json.loads((builder / "desktop-build-plan.json").read_text())["include"]
                self.assertEqual([item["sha"] for item in entries], [standard_sha, remote_sha])
                self.assertEqual([item["version"] for item in entries], [VERSION + "+69"] * 2)
                self.assertEqual([item["branch"] for item in entries], [STANDARD_RELEASE, REMOTE_RELEASE])
            finally:
                os.chdir(previous)

    def test_source_must_identify_its_edition(self):
        def git(*args):
            if args[0] == "show":
                return "version: " + VERSION + "+69" if args[1].endswith("pubspec.yaml") else "const kDesktopEdition = DesktopEdition.standard;"
            return ""
        with patch.object(plan, "git", side_effect=git):
            with self.assertRaisesRegex(ValueError, "not the remoteUpload edition"):
                plan.entry("remoteUpload", REMOTE_RELEASE, "remote-sha")

    def test_both_edition_packages_are_arm64(self):
        for edition in ["standard", "remoteUpload"]:
            def git(*args):
                if args[0] == "show":
                    return "version: " + VERSION + "+69" if args[1].endswith("pubspec.yaml") else f"const kDesktopEdition = DesktopEdition.{edition};"
                return ""
            with patch.object(plan, "git", side_effect=git):
                item = plan.entry(edition, "source-branch", "source-sha")
            self.assertEqual(item["architecture"], "arm64")
            self.assertTrue(item["dmg"].endswith("-arm64.dmg"))


if __name__ == "__main__":
    unittest.main()
