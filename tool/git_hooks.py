#!/usr/bin/env python3
"""Git commit message, staging hygiene, formatting, and CI guard checks."""

from __future__ import annotations

import argparse
import glob
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
from typing import Iterable, Sequence

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover - optional in bare Python environments
    yaml = None

ALLOWED_TYPES = (
    "feat",
    "fix",
    "docs",
    "style",
    "refactor",
    "perf",
    "test",
    "build",
    "ci",
    "chore",
)

SUBJECT_RE = re.compile(
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\([a-z0-9_/-]+\))?!?: (.+)$"
)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
TRAILER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*:\s+\S")
SKIP_TAG_RE = re.compile(r"\[(?:skip ci|ci skip|no ci)\]", re.IGNORECASE)
SCISSOR_LINE = "# ------------------------ >8 ------------------------"

BASELINE_COMMITS = (
    "52af938c36e292d47e684aa058438a791f305b10",
    "7d572a5777a7e447c0610557002fdae0ec334d55",
)

EXPECTED_APP_NAME = "Plana App Desktop"
EXPECTED_GITHUB_REPO = "shenghuo2/Plana-App-Desktop"
EXPECTED_GAL_VERSION = "2.3.3"

FORBIDDEN_TOP_DIRS = {
    "build",
    "dist",
    "logs",
    "output",
    "\u4f5c\u54c1",
    "backups",
    "validation",
    "coverage",
    ".dart_tool",
    ".pub-cache",
    ".pub",
}

FORBIDDEN_EXACT_NAMES = {
    "handoff.md",
    "next-session.md",
    "windows-plan.md",
    "windows-source.json",
    "windows-validation.md",
    "settings.json",
    "prefs.json",
    "prompt_presets.json",
    "desktop_output_roots.json",
    "my_public_tags.json",
    ".ds_store",
}

FORBIDDEN_EXACT_PATHS = {
    "android/key.properties",
    "tool/local/google-drive-desktop.json",
}

ALLOWED_ENV_NAMES = {".env.example", ".env.template"}


def _git_bytes(repo: Path, args: Sequence[str]) -> bytes:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed ({proc.returncode}): {err}")
    return proc.stdout


def _git_text(repo: Path, args: Sequence[str]) -> str:
    return _git_bytes(repo, args).decode("utf-8", errors="replace")


def _git_ok(repo: Path, args: Sequence[str]) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode == 0


def _parse_nul_name_status(raw: bytes) -> list[str]:
    """Parse `git ... --name-status -z` tokens into destination repo-relative paths."""
    if not raw:
        return []
    tokens = [t.decode("utf-8", errors="surrogateescape") for t in raw.split(b"\x00") if t]
    paths: list[str] = []
    i = 0
    while i < len(tokens):
        status = tokens[i]
        i += 1
        if status.startswith(("R", "C")):
            if i + 1 < len(tokens):
                # Destination path follows source path for rename/copy records.
                paths.append(tokens[i + 1])
                i += 2
            elif i < len(tokens):
                paths.append(tokens[i])
                i += 1
        else:
            if i < len(tokens):
                paths.append(tokens[i])
                i += 1
    return paths


def validate_commit_message(raw: str) -> list[str]:
    """Validate Conventional Commit header and Chinese subject/body rules."""
    errors: list[str] = []
    kept_lines: list[str] = []
    for line in raw.replace("\r\n", "\n").splitlines():
        if line == SCISSOR_LINE:
            break
        if line.lstrip().startswith("#"):
            continue
        kept_lines.append(line)

    while kept_lines and not kept_lines[0].strip():
        kept_lines.pop(0)
    while kept_lines and not kept_lines[-1].strip():
        kept_lines.pop()

    if not kept_lines:
        return ["Commit message is empty / 提交说明不能为空。"]

    subject = kept_lines[0].strip()
    if subject.startswith("Merge ") or subject.startswith("Revert "):
        return []

    match = SUBJECT_RE.match(subject)
    if not match:
        errors.append(
            "Commit subject must match `<type>(<scope>): <中文简述>` "
            "(allowed types: feat, fix, docs, style, refactor, perf, test, build, ci, chore; "
            "optional lowercase scope matching `[a-z0-9_/-]+`).\n"
            f"  Got: {subject!r}"
        )
        return errors

    desc = SKIP_TAG_RE.sub("", match.group(3)).strip()
    if not desc:
        errors.append("Commit description cannot be empty after control tags / 提交简述不能为空。")
    elif not CJK_RE.search(desc):
        errors.append(
            "Commit subject description MUST contain Chinese characters / "
            f"提交简述必须使用中文: {subject!r}"
        )

    prose_body: list[str] = []
    for line in kept_lines[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        if TRAILER_RE.match(stripped):
            continue
        if stripped.startswith("(cherry picked from commit ") and stripped.endswith(")"):
            continue
        prose_body.append(stripped)

    if prose_body and not CJK_RE.search("\n".join(prose_body)):
        errors.append(
            "Commit body prose MUST be written in Chinese (git trailers like Co-Authored-By are exempt) / "
            "提交正文必须使用中文。"
        )

    return errors


def check_forbidden_paths(paths: Iterable[str]) -> list[str]:
    """Reject temporary reports, secrets, credentials, runtime outputs, and build junk."""
    errors: list[str] = []
    seen: set[str] = set()
    for raw in paths:
        norm = raw.replace("\\", "/")
        while norm.startswith("./"):
            norm = norm[2:]
        norm = norm.lstrip("/")
        if not norm or norm in seen:
            continue
        seen.add(norm)
        lower = norm.lower()
        parts = PurePosixPath(norm).parts
        lower_parts = tuple(p.lower() for p in parts)
        base = parts[-1] if parts else norm
        base_lower = base.lower()

        reason: str | None = None
        if base_lower.endswith("_summary.md"):
            reason = "temporary summary/report markdown (`*_SUMMARY.md`)"
        elif base_lower in FORBIDDEN_EXACT_NAMES:
            reason = f"forbidden local/runtime/handoff file (`{base}`)"
        elif lower in FORBIDDEN_EXACT_PATHS:
            reason = f"forbidden credential/signing file (`{norm}`)"
        elif (base_lower == ".env" or base_lower.startswith(".env.")) and base_lower not in ALLOWED_ENV_NAMES:
            reason = f"environment secret file (`{base}`)"
        elif base_lower.endswith((".jks", ".keystore", ".secure", ".swp", ".pyc")):
            reason = f"forbidden signing, secret, swap, or bytecode file (`{base}`)"
        elif base_lower.startswith("client_secret") and base_lower.endswith(".json"):
            reason = f"OAuth client secret file (`{base}`)"
        elif base_lower.startswith("flutter_secure_storage") and base_lower.endswith(".dat"):
            reason = f"encrypted local credential store (`{base}`)"
        elif base_lower.startswith("bot_session") and base_lower.endswith(".json"):
            reason = f"runtime Bot session file (`{base}`)"
        elif base_lower.startswith("tag_library") and base_lower.endswith(".json"):
            reason = f"runtime user tag library (`{base}`)"
        elif lower_parts and lower_parts[0] in FORBIDDEN_TOP_DIRS:
            reason = f"forbidden build/runtime directory (`{parts[0]}/`)"
        elif lower_parts and lower_parts[0].startswith("recovery-backup-"):
            reason = f"local recovery backup directory (`{parts[0]}/`)"
        elif "__pycache__" in lower_parts:
            reason = "Python bytecode cache directory (`__pycache__/`)"

        if reason:
            errors.append(f"Forbidden staged/committed path `{norm}`: {reason}")
    return errors


def check_conflict_markers(path: str, data: bytes) -> list[str]:
    """Detect unresolved merge conflict markers in non-binary blobs."""
    if b"\x00" in data[:8192]:
        return []
    start_prefix = "<" * 7 + " "
    start_exact = "<" * 7
    mid_exact = "=" * 7
    end_prefix = ">" * 7 + " "
    end_exact = ">" * 7

    text = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
    in_conflict = False
    for lineno, line in enumerate(text.splitlines(), start=1):
        if line.startswith(start_prefix) or line == start_exact:
            in_conflict = True
            return [f"Unresolved conflict start marker at {path}:{lineno}"]
        if in_conflict and line == mid_exact:
            return [f"Unresolved conflict separator marker at {path}:{lineno}"]
        if line.startswith(end_prefix) or line == end_exact:
            return [f"Unresolved conflict end marker at {path}:{lineno}"]
    return []


def check_app_info_sync(pubspec_text: str, app_info_text: str) -> list[str]:
    """Verify pubspec.yaml version/build matches lib/core/app_info.dart and repo identity."""
    errors: list[str] = []
    pub_norm = pubspec_text.replace("\r\n", "\n")
    info_norm = app_info_text.replace("\r\n", "\n")

    m_pub = re.search(r"^version:\s*([^\s+#]+)\+([0-9]+)\s*$", pub_norm, re.MULTILINE)
    if not m_pub:
        return ["pubspec.yaml is missing a `<version>+<build>` line."]
    pub_ver, pub_build = m_pub.group(1), m_pub.group(2)

    m_ver = re.search(r"^const\s+kAppVersion\s*=\s*'([^']+)'\s*;", info_norm, re.MULTILINE)
    m_build = re.search(r"^const\s+kAppBuild\s*=\s*'([^']+)'\s*;", info_norm, re.MULTILINE)
    m_name = re.search(r"^const\s+kAppName\s*=\s*'([^']+)'\s*;", info_norm, re.MULTILINE)
    m_repo = re.search(r"^const\s+kGithubRepo\s*=\s*'([^']+)'\s*;", info_norm, re.MULTILINE)

    if not m_ver or m_ver.group(1) != pub_ver:
        actual = m_ver.group(1) if m_ver else "<missing>"
        errors.append(
            f"Version mismatch: pubspec.yaml has `{pub_ver}` while kAppVersion has `{actual}`."
        )
    if not m_build or m_build.group(1) != pub_build:
        actual = m_build.group(1) if m_build else "<missing>"
        errors.append(
            f"Build number mismatch: pubspec.yaml has `{pub_build}` while kAppBuild has `{actual}`."
        )
    if not m_name or m_name.group(1) != EXPECTED_APP_NAME:
        actual = m_name.group(1) if m_name else "<missing>"
        errors.append(
            f"kAppName invariant violated: expected `{EXPECTED_APP_NAME}`, got `{actual}`."
        )
    if not m_repo or m_repo.group(1) != EXPECTED_GITHUB_REPO:
        actual = m_repo.group(1) if m_repo else "<missing>"
        errors.append(
            f"kGithubRepo invariant violated: expected `{EXPECTED_GITHUB_REPO}`, got `{actual}`."
        )
    return errors


def check_gal_pin(pubspec_lock_text: str) -> list[str]:
    """Verify pubspec.lock keeps gal pinned to 2.3.3."""
    norm = pubspec_lock_text.replace("\r\n", "\n")
    m = re.search(r"(?m)^  gal:\n((?:    .*\n)*)", norm)
    if not m:
        return ["pubspec.lock is missing the `gal:` package block."]
    m_ver = re.search(r'^\s+version:\s*"?([^"\s]+)"?\s*$', m.group(1), re.MULTILINE)
    if not m_ver:
        return ["pubspec.lock `gal:` block is missing its `version:` field."]
    if m_ver.group(1) != EXPECTED_GAL_VERSION:
        return [
            f"pubspec.lock `gal` version must remain `{EXPECTED_GAL_VERSION}`, found `{m_ver.group(1)}`."
        ]
    return []


def check_python_syntax(path: str, data: bytes) -> list[str]:
    """Compile Python source to catch syntax errors before commit."""
    try:
        source = data.decode("utf-8")
        compile(source, path, "exec")
    except (UnicodeDecodeError, SyntaxError) as exc:
        return [f"Python syntax/encoding error in `{path}`: {exc}"]
    return []


def check_yaml_syntax(path: str, data: bytes) -> list[str]:
    """Validate YAML files when PyYAML is available."""
    if yaml is None:
        return []
    try:
        yaml.safe_load(data.decode("utf-8"))
    except (UnicodeDecodeError, yaml.YAMLError) as exc:
        return [f"YAML parse error in `{path}`: {exc}"]
    return []


def find_sdk_tool(name: str) -> str | None:
    """Locate `dart` or `flutter` from PATH or standard Flutter SDK install locations."""
    found = shutil.which(name)
    if found:
        return found

    candidates: list[Path] = []
    flutter_root = os.environ.get("FLUTTER_ROOT")
    if flutter_root:
        candidates.append(Path(flutter_root) / "bin" / name)

    home = Path.home()
    for match in sorted(glob.glob(str(home / ".cache/flutter-sdk-*/flutter/bin" / name)), reverse=True):
        candidates.append(Path(match))
    candidates.extend(
        [
            home / "flutter" / "bin" / name,
            home / "fvm" / "default" / "bin" / name,
            Path("/opt/flutter/bin") / name,
        ]
    )

    if os.name == "nt":
        win_candidates = [Path(str(c) + ext) for c in candidates for ext in (".bat", ".exe", "")]
        candidates = win_candidates + candidates

    for candidate in candidates:
        if candidate.is_file() and (os.name == "nt" or os.access(candidate, os.X_OK)):
            return str(candidate)
    return None


def check_dart_format_blob(dart_bin: str, path: str, data: bytes) -> list[str]:
    """Run `dart format --output=none --set-exit-if-changed --stdin-name <path>` on exact blob."""
    proc = subprocess.run(
        [dart_bin, "format", "--output=none", "--set-exit-if-changed", "--stdin-name", path],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode == 0:
        return []
    detail = (proc.stderr or proc.stdout).decode("utf-8", errors="replace").strip()
    return [f"Dart formatting required for `{path}` (`dart format {path}`): {detail}"]


def _repo_root(cwd: Path | None = None) -> Path:
    base = cwd or Path.cwd()
    return Path(_git_text(base, ["rev-parse", "--show-toplevel"]).strip())


def _read_index_blob(repo: Path, rel_path: str) -> bytes:
    return _git_bytes(repo, ["show", f":{rel_path}"])


def _read_rev_blob(repo: Path, rev: str, rel_path: str) -> bytes:
    return _git_bytes(repo, ["show", f"{rev}:{rel_path}"])


def _read_index_or_head_text(repo: Path, staged: set[str], rel_path: str) -> str | None:
    if rel_path in staged:
        return _read_index_blob(repo, rel_path).decode("utf-8", errors="replace")
    if _git_ok(repo, ["cat-file", "-e", f":{rel_path}"]):
        return _read_index_blob(repo, rel_path).decode("utf-8", errors="replace")
    if _git_ok(repo, ["cat-file", "-e", f"HEAD:{rel_path}"]):
        return _read_rev_blob(repo, "HEAD", rel_path).decode("utf-8", errors="replace")
    return None


def cmd_commit_msg(args: argparse.Namespace) -> int:
    msg_path = Path(args.msg_file)
    raw = msg_path.read_text(encoding="utf-8", errors="replace")
    errors = validate_commit_message(raw)
    if errors:
        print("[commit-msg] Commit message rejected:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


def cmd_pre_commit(_args: argparse.Namespace) -> int:
    repo = _repo_root()
    raw_diff = _git_bytes(repo, ["diff", "--cached", "--name-status", "-z", "--diff-filter=ACMR"])
    staged_paths = _parse_nul_name_status(raw_diff)
    if not staged_paths:
        return 0

    errors: list[str] = []
    errors.extend(check_forbidden_paths(staged_paths))

    staged_set = set(staged_paths)
    staged_blobs: dict[str, bytes] = {}
    for path in staged_paths:
        blob = _read_index_blob(repo, path)
        staged_blobs[path] = blob
        errors.extend(check_conflict_markers(path, blob))
        lower = path.lower()
        if lower.endswith(".py"):
            errors.extend(check_python_syntax(path, blob))
        elif lower.endswith((".yml", ".yaml")):
            errors.extend(check_yaml_syntax(path, blob))

    if "pubspec.yaml" in staged_set or "lib/core/app_info.dart" in staged_set:
        pubspec_text = _read_index_or_head_text(repo, staged_set, "pubspec.yaml")
        app_info_text = _read_index_or_head_text(repo, staged_set, "lib/core/app_info.dart")
        if pubspec_text is None or app_info_text is None:
            errors.append("Both `pubspec.yaml` and `lib/core/app_info.dart` must exist when either changes.")
        else:
            errors.extend(check_app_info_sync(pubspec_text, app_info_text))

    if "pubspec.lock" in staged_set:
        errors.extend(check_gal_pin(staged_blobs["pubspec.lock"].decode("utf-8", errors="replace")))

    staged_dart = [p for p in staged_paths if p.lower().endswith(".dart")]
    if staged_dart:
        dart_bin = find_sdk_tool("dart")
        if not dart_bin:
            errors.append("`dart` executable not found in PATH or standard Flutter SDK directories.")
        else:
            for path in staged_dart:
                errors.extend(check_dart_format_blob(dart_bin, path, staged_blobs[path]))

    analyze_triggers = [
        p
        for p in staged_paths
        if p.lower().endswith(".dart") or p in {"pubspec.yaml", "pubspec.lock", "analysis_options.yaml"}
    ]
    if analyze_triggers:
        # Ensure working tree matches staged Dart/config files before running flutter analyze.
        unstaged = _parse_nul_lines(
            _git_bytes(repo, ["diff", "--name-only", "-z", "--", *analyze_triggers])
        )
        if unstaged:
            errors.append(
                "Staged Dart/pubspec files also have unstaged working-tree edits; stage or stash them before committing: "
                + ", ".join(unstaged)
            )
        else:
            flutter_bin = find_sdk_tool("flutter")
            if not flutter_bin:
                errors.append("`flutter` executable not found in PATH or standard Flutter SDK directories.")
            else:
                proc = subprocess.run(
                    [flutter_bin, "analyze", "--no-pub"],
                    cwd=str(repo),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                )
                if proc.returncode != 0:
                    errors.append(f"`flutter analyze --no-pub` failed:\n{proc.stdout.strip()}")

    if errors:
        print("[pre-commit] Staged checks failed:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


def _parse_nul_lines(raw: bytes) -> list[str]:
    if not raw:
        return []
    return [item.decode("utf-8", errors="surrogateescape") for item in raw.split(b"\x00") if item]


def _resolve_commits(repo: Path, base: str, head: str) -> list[str]:
    rev_args = ["rev-list", head]
    zero_sha = "0" * 40
    exclusions = list(BASELINE_COMMITS)
    if base and base != zero_sha:
        exclusions.append(base)
    for commit in exclusions:
        if _git_ok(repo, ["cat-file", "-e", f"{commit}^{{commit}}"]):
            rev_args.append(f"^{commit}")
    out = _git_text(repo, rev_args).strip()
    return [line.strip() for line in out.splitlines() if line.strip()]


def _collect_commit_changed_paths(repo: Path, commits: Sequence[str]) -> list[str]:
    changed: list[str] = []
    seen: set[str] = set()
    for sha in commits:
        raw = _git_bytes(
            repo,
            [
                "diff-tree",
                "--no-commit-id",
                "--name-status",
                "-r",
                "-z",
                "-m",
                "--first-parent",
                "--diff-filter=ACMR",
                sha,
            ],
        )
        for path in _parse_nul_name_status(raw):
            if path not in seen:
                seen.add(path)
                changed.append(path)
    return changed


def cmd_ci_check(args: argparse.Namespace) -> int:
    repo = _repo_root()
    commits = _resolve_commits(repo, args.base or "", args.head)
    changed_paths = _collect_commit_changed_paths(repo, commits) if commits else []
    existing_paths = [p for p in changed_paths if _git_ok(repo, ["cat-file", "-e", f"{args.head}:{p}"])]

    if args.list_dart_only:
        for path in existing_paths:
            if path.lower().endswith(".dart"):
                print(path)
        return 0

    errors: list[str] = []
    for sha in commits:
        msg = _git_text(repo, ["log", "-1", "--format=%B", sha])
        for err in validate_commit_message(msg):
            errors.append(f"Commit `{sha[:8]}` message error: {err}")
        commit_paths = _collect_commit_changed_paths(repo, [sha])
        for err in check_forbidden_paths(commit_paths):
            errors.append(f"Commit `{sha[:8]}` path error: {err}")

    dart_paths: list[str] = []
    head_blobs: dict[str, bytes] = {}
    for path in existing_paths:
        blob = _read_rev_blob(repo, args.head, path)
        head_blobs[path] = blob
        errors.extend(check_conflict_markers(path, blob))
        lower = path.lower()
        if lower.endswith(".py"):
            errors.extend(check_python_syntax(path, blob))
        elif lower.endswith((".yml", ".yaml")):
            errors.extend(check_yaml_syntax(path, blob))
        elif lower.endswith(".dart"):
            dart_paths.append(path)

    if _git_ok(repo, ["cat-file", "-e", f"{args.head}:pubspec.yaml"]) and _git_ok(
        repo, ["cat-file", "-e", f"{args.head}:lib/core/app_info.dart"]
    ):
        pubspec_text = _read_rev_blob(repo, args.head, "pubspec.yaml").decode("utf-8", errors="replace")
        app_info_text = _read_rev_blob(repo, args.head, "lib/core/app_info.dart").decode(
            "utf-8", errors="replace"
        )
        errors.extend(check_app_info_sync(pubspec_text, app_info_text))

    if _git_ok(repo, ["cat-file", "-e", f"{args.head}:pubspec.lock"]):
        lock_text = _read_rev_blob(repo, args.head, "pubspec.lock").decode("utf-8", errors="replace")
        errors.extend(check_gal_pin(lock_text))

    if args.check_dart_format and dart_paths:
        dart_bin = find_sdk_tool("dart")
        if not dart_bin:
            errors.append("`--check-dart-format` requested but `dart` executable was not found.")
        else:
            for path in dart_paths:
                errors.extend(check_dart_format_blob(dart_bin, path, head_blobs[path]))

    if errors:
        print(
            f"[ci-check] Failed across {len(commits)} commit(s) and {len(existing_paths)} changed path(s):",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(
        f"[ci-check] Verified {len(commits)} commit(s), {len(existing_paths)} changed path(s), "
        f"and {len(dart_paths)} changed Dart file(s) at {args.head}."
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_msg = sub.add_parser("commit-msg", help="Validate commit message file.")
    p_msg.add_argument("msg_file", help="Path to the commit message file.")
    p_msg.set_defaults(func=cmd_commit_msg)

    p_pre = sub.add_parser("pre-commit", help="Validate staged changes before commit.")
    p_pre.set_defaults(func=cmd_pre_commit)

    p_ci = sub.add_parser("ci-check", help="Validate commit range and head invariants in CI.")
    p_ci.add_argument("--base", default="", help="Base commit SHA (or empty/all-zero on new refs).")
    p_ci.add_argument("--head", default="HEAD", help="Target commit/ref to validate.")
    p_ci.add_argument("--check-dart-format", action="store_true", help="Verify dart format on changed Dart blobs.")
    p_ci.add_argument("--list-dart-only", action="store_true", help="Print changed Dart paths and exit.")
    p_ci.set_defaults(func=cmd_ci_check)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
