#!/usr/bin/env python3
"""Unit and end-to-end tests for tool/git_hooks.py and .githooks/."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import git_hooks  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parent.parent


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=check,
    )


class GitHooksUnitTest(unittest.TestCase):
    def test_valid_commit_messages(self) -> None:
        valid_messages = [
            "feat(auth): 新增 OAuth2 登录回调与令牌刷新",
            "fix(api/orders)!: 修复并发下单时的库存扣减竞态",
            "docs: 补充本地调试与环境变量说明",
            "build(desktop): 准备 1.2.5-desktop+74 [skip ci]",
            "Merge branch 'main' into feature/remote-upload",
            'Revert "feat: 某次改动"',
            "feat(editor): 优化多画布草稿保存\n\n仅在内容变化时触发写盘，并保留失败提示。\n\nCo-Authored-By: Test <test@example.com>",
            "fix(gallery): 修复删除恢复索引定位\n\n(cherry picked from commit 1234567890abcdef)",
            "chore(git): 新增钩子\n# comment ignored\n"
            + git_hooks.SCISSOR_LINE
            + "\n+English diff line after scissor must be ignored",
        ]
        for msg in valid_messages:
            with self.subTest(msg=msg.splitlines()[0]):
                self.assertEqual(git_hooks.validate_commit_message(msg), [])

    def test_invalid_commit_messages(self) -> None:
        invalid_messages = [
            "",
            "   \n# only comment\n",
            "missing type prefix: 新增功能",
            "merge(remote-upload): 同步代码",
            "feat(Auth): 大写 scope 应被拒绝",
            "feat(bad scope): 含空格的 scope",
            "feat(auth): add oauth2 callback",
            "build(desktop): [skip ci]",
            "feat(auth): 新增登录\n\nEnglish-only body must fail.",
        ]
        for msg in invalid_messages:
            with self.subTest(msg=repr(msg)):
                self.assertTrue(git_hooks.validate_commit_message(msg))

    def test_forbidden_paths_and_allowlist(self) -> None:
        blocked = [
            "REVIEW_SUMMARY.md",
            "docs/task_summary.md",
            "HANDOFF.md",
            "NEXT-SESSION.md",
            ".env",
            ".env.local",
            "config/.env.production",
            "client_secret_123.json",
            "tool/local/google-drive-desktop.json",
            "output/2026-11-22/demo.png",
            "作品/demo.png",
            "settings.json",
            "nested/prefs.json",
            "android/key.properties",
            "release.keystore",
            "build/windows/x64/app.exe",
            "tool/__pycache__/git_hooks.cpython-312.pyc",
            ".DS_Store",
        ]
        for path in blocked:
            with self.subTest(blocked=path):
                self.assertTrue(git_hooks.check_forbidden_paths([path]), f"Expected block for {path}")

        allowed = [
            ".env.example",
            ".env.template",
            "lib/core/auth/bot_session_store.dart",
            "test/gallery_image_handoff_test.dart",
            "AGENTS.md",
            ".github/workflows/commit-guard.yml",
        ]
        self.assertEqual(git_hooks.check_forbidden_paths(allowed), [])

    def test_real_repo_tracked_files_have_no_forbidden_paths(self) -> None:
        proc = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        tracked = [p.decode("utf-8", errors="surrogateescape") for p in proc.stdout.split(b"\x00") if p]
        self.assertGreater(len(tracked), 100)
        self.assertEqual(git_hooks.check_forbidden_paths(tracked), [])

    def test_conflict_markers(self) -> None:
        m_start = "<" * 7 + " HEAD\n"
        m_mid = "=" * 7 + "\n"
        m_end = ">" * 7 + " main\n"
        self.assertTrue(
            git_hooks.check_conflict_markers("a.txt", (m_start + "a\n" + m_mid + "b\n" + m_end).encode())
        )
        # Markdown Setext headings use `=======` outside any conflict block.
        markdown = b"Title\n=======\n\nBody text\n"
        self.assertEqual(git_hooks.check_conflict_markers("README.md", markdown), [])
        # Binary data containing NUL bytes is skipped.
        binary = b"\x89PNG\r\n\x1a\n\x00\x00" + m_start.encode()
        self.assertEqual(git_hooks.check_conflict_markers("img.png", binary), [])

    def test_app_info_sync_and_gal_pin(self) -> None:
        pubspec = "name: plana_app\nversion: 1.2.4-desktop+73\n"
        app_info = (
            "const kAppName = 'Plana App Desktop';\n"
            "const kAppVersion = '1.2.4-desktop';\n"
            "const kAppBuild = '73';\n"
            "const kGithubRepo = 'shenghuo2/Plana-App-Desktop';\n"
        )
        self.assertEqual(git_hooks.check_app_info_sync(pubspec, app_info), [])
        self.assertTrue(
            git_hooks.check_app_info_sync("version: 1.2.5-desktop+74\n", app_info)
        )
        self.assertTrue(
            git_hooks.check_app_info_sync(
                pubspec,
                app_info.replace("Plana App Desktop", "Other App"),
            )
        )

        lock_ok = (
            "packages:\n"
            "  gal:\n"
            '    dependency: "direct main"\n'
            '    version: "2.3.3"\n'
            "  glob:\n"
            '    version: "2.1.3"\n'
        )
        self.assertEqual(git_hooks.check_gal_pin(lock_ok), [])
        self.assertTrue(git_hooks.check_gal_pin(lock_ok.replace("2.3.3", "3.0.1")))

    def test_python_syntax_check(self) -> None:
        self.assertEqual(git_hooks.check_python_syntax("ok.py", b"x = 1 + 2\n"), [])
        self.assertTrue(git_hooks.check_python_syntax("bad.py", b"def broken(:\n"))


class GitHooksE2ETest(unittest.TestCase):
    def _create_temp_repo(self) -> Path:
        tmp = Path(tempfile.mkdtemp(prefix="plana_git_hooks_"))
        self.addCleanup(lambda: shutil.rmtree(tmp, ignore_errors=True))
        _git(tmp, "init")
        _git(tmp, "config", "user.name", "Test User")
        _git(tmp, "config", "user.email", "test@example.com")
        shutil.copytree(REPO_ROOT / ".githooks", tmp / ".githooks")
        for hook in (tmp / ".githooks").iterdir():
            if hook.is_file():
                os.chmod(hook, 0o755)
        (tmp / "tool").mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO_ROOT / "tool" / "git_hooks.py", tmp / "tool" / "git_hooks.py")
        (tmp / "README.md").write_text("# Test\n", encoding="utf-8")
        _git(tmp, "add", ".githooks", "tool/git_hooks.py", "README.md")
        _git(tmp, "commit", "-m", "chore: 初始化测试仓库")
        _git(tmp, "config", "core.hooksPath", ".githooks")
        return tmp

    def test_hooks_enforce_commit_msg_hygiene_and_ci_check(self) -> None:
        repo = self._create_temp_repo()
        base_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

        # 1. Invalid English-only commit message is blocked by commit-msg hook.
        (repo / "notes.txt").write_text("ok\n", encoding="utf-8")
        _git(repo, "add", "notes.txt")
        bad_msg = _git(repo, "commit", "-m", "feat(core): add something", check=False)
        self.assertNotEqual(bad_msg.returncode, 0)
        self.assertIn("中文", bad_msg.stderr)

        # 2. Valid commit message succeeds.
        ok = _git(repo, "commit", "-m", "docs(notes): 新增测试说明文档")
        self.assertEqual(ok.returncode, 0, msg=ok.stderr)

        # 3. Forbidden report file is blocked by pre-commit hook.
        (repo / "TASK_SUMMARY.md").write_text("summary\n", encoding="utf-8")
        _git(repo, "add", "TASK_SUMMARY.md")
        bad_file = _git(repo, "commit", "-m", "docs: 添加临时总结", check=False)
        self.assertNotEqual(bad_file.returncode, 0)
        self.assertIn("TASK_SUMMARY.md", bad_file.stderr)
        _git(repo, "reset", "HEAD", "--", "TASK_SUMMARY.md")
        (repo / "TASK_SUMMARY.md").unlink()

        # 4. Broken Python file is blocked by pre-commit hook.
        (repo / "tool" / "broken.py").write_text("def oops(:\n", encoding="utf-8")
        _git(repo, "add", "tool/broken.py")
        bad_py = _git(repo, "commit", "-m", "chore(tool): 添加测试脚本", check=False)
        self.assertNotEqual(bad_py.returncode, 0)
        self.assertIn("broken.py", bad_py.stderr)
        _git(repo, "reset", "HEAD", "--", "tool/broken.py")
        (repo / "tool" / "broken.py").unlink()

        # 5. ci-check passes on clean commit range after base_sha.
        ci_ok = subprocess.run(
            ["python3", "tool/git_hooks.py", "ci-check", "--base", base_sha, "--head", "HEAD"],
            cwd=str(repo),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(ci_ok.returncode, 0, msg=ci_ok.stderr)

        # 6. ci-check fails when a `--no-verify` style bad commit exists in range.
        (repo / "bypass.txt").write_text("oops\n", encoding="utf-8")
        _git(repo, "add", "bypass.txt")
        _git(repo, "commit", "--no-verify", "-m", "fix: bypassed hook")
        ci_bad = subprocess.run(
            ["python3", "tool/git_hooks.py", "ci-check", "--base", base_sha, "--head", "HEAD"],
            cwd=str(repo),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertNotEqual(ci_bad.returncode, 0)
        self.assertIn("MUST contain Chinese", ci_bad.stderr)

    def test_ci_check_merge_commit_only_inspects_first_parent_diff(self) -> None:
        repo = self._create_temp_repo()
        (repo / "edition.txt").write_text("base\n", encoding="utf-8")
        _git(repo, "add", "edition.txt")
        _git(repo, "commit", "-m", "chore: 添加基础版本文件")
        main_branch = _git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()

        _git(repo, "checkout", "-b", "feature/test-edition")
        (repo / "edition.txt").write_text("feature-only\n", encoding="utf-8")
        _git(repo, "add", "edition.txt")
        _git(repo, "commit", "-m", "feat(edition): 修改分支专有配置")
        feature_base = _git(repo, "rev-parse", "HEAD").stdout.strip()

        _git(repo, "checkout", main_branch)
        (repo / "shared.txt").write_text("from-main\n", encoding="utf-8")
        _git(repo, "add", "shared.txt")
        _git(repo, "commit", "-m", "docs: 主分支新增共享说明")

        _git(repo, "checkout", "feature/test-edition")
        _git(repo, "merge", "--no-ff", main_branch, "-m", "chore(edition): 同步主分支更新")
        merge_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

        paths = git_hooks._collect_commit_changed_paths(repo, [merge_sha])
        self.assertEqual(paths, ["shared.txt"])
        ci_ok = subprocess.run(
            ["python3", "tool/git_hooks.py", "ci-check", "--base", feature_base, "--head", "HEAD"],
            cwd=str(repo),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(ci_ok.returncode, 0, msg=ci_ok.stderr)


if __name__ == "__main__":
    unittest.main()
