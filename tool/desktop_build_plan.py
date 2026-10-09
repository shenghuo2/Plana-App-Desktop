"""Build saved release branches or pin development refs for both editions."""

import json
import os
from pathlib import Path
import re
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def branch_sha(branch):
    ref = f"refs/heads/{branch}"
    git("check-ref-format", ref)
    matches = git("ls-remote", "--heads", "origin", ref).splitlines()
    if len(matches) != 1 or matches[0].split()[1] != ref:
        raise ValueError(f"Branch not found: {branch}")
    return matches[0].split()[0]


def entry(edition, branch, sha):
    git("fetch", "--no-tags", "--depth=1", "origin", sha)
    pubspec = git("show", f"{sha}:pubspec.yaml")
    version = re.search(r"^version:\s*(\S+)\s*$", pubspec, re.M).group(1)
    source = git("show", f"{sha}:lib/core/desktop_edition.dart")
    if f"const kDesktopEdition = DesktopEdition.{edition};" not in source:
        raise ValueError(f"{branch} is not the {edition} edition")
    remote = edition == "remoteUpload"
    return {
        "edition": edition,
        "branch": branch,
        "sha": sha,
        "version": version,
        "architecture": "arm64",
        "dmg": "Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg" if remote else "Plana-App-Desktop-macOS-arm64.dmg",
        "artifact": "Plana-App-Desktop-RemoteUpload-macOS-ad-hoc" if remote else "Plana-App-Desktop-macOS-ad-hoc",
        "volume": "Plana App Desktop Remote Upload" if remote else "Plana App Desktop",
    }


def validate_versions(entries):
    if len({e["version"] for e in entries}) != 1:
        raise ValueError("Edition versions/build numbers differ; synchronize both source branches first")


def release_branches(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+-desktop(?:\.[0-9A-Za-z-]+)*", version):
        raise ValueError("Invalid desktop release version; use a version such as 1.2.0-desktop.1 without +build")
    return f"release/{version}", f"release/remote-upload/{version}"


def release_branch_version(branch):
    for prefix in ("release/remote-upload/", "release/"):
        if branch.startswith(prefix):
            return branch.removeprefix(prefix)
    return ""


def main():
    dispatch = os.environ["BUILD_EVENT"] == "workflow_dispatch"
    release_tag = not dispatch and os.environ.get("BUILD_REF_TYPE") == "tag"
    branch = os.environ["BUILD_BRANCH"]
    requested_input = os.environ.get("RELEASE_VERSION", "").strip() if dispatch else ""
    requested = requested_input.removeprefix("v")
    if requested_input:
        release_branches(requested)
    derived = branch.removeprefix("v") if release_tag else release_branch_version(branch)
    if requested and derived and requested != derived:
        raise ValueError("Requested release version differs from the selected release branch")
    version = derived or requested
    entries = []
    if version:
        if dispatch and os.environ["BUILD_EDITIONS"] != "both":
            raise ValueError("Release builds must include both editions")
        standard, remote = release_branches(version)
        standard_sha, remote_sha = branch_sha(standard), branch_sha(remote)
        if release_tag and standard_sha != os.environ["BUILD_SHA"]:
            raise ValueError("Release tag does not point to the saved standard release branch")
        if not dispatch and not release_tag:
            pushed_sha = standard_sha if branch == standard else remote_sha
            if pushed_sha != os.environ["BUILD_SHA"]:
                raise ValueError("Release branch changed after the build was triggered")
        entries.append(entry("standard", standard, standard_sha))
        entries.append(entry("remoteUpload", remote, remote_sha))
    elif dispatch:
        selection = os.environ["BUILD_EDITIONS"]
        if selection not in {"both", "standard", "remote-upload"}:
            raise ValueError("Invalid edition selection")
        for edition, key, selected in [
            ("standard", "STANDARD_BRANCH", selection in {"both", "standard"}),
            ("remoteUpload", "REMOTE_BRANCH", selection in {"both", "remote-upload"}),
        ]:
            if selected:
                branch = os.environ[key]
                entries.append(entry(edition, branch, branch_sha(branch)))
    else:
        edition = "remoteUpload" if branch == "feature/remote-upload" else "standard"
        entries.append(entry(edition, branch, os.environ["BUILD_SHA"]))
    validate_versions(entries)
    if version and entries[0]["version"].split("+")[0] != version:
        raise ValueError("Saved release branches do not match the requested release version")
    standard = next((e for e in entries if e["edition"] == "standard"), None)
    remote_upload = next((e for e in entries if e["edition"] == "remoteUpload"), None)
    windows = standard is not None and (
        not dispatch or os.environ["BUILD_WINDOWS"].lower() == "true"
    )
    matrix = {"include": entries}
    Path("desktop-build-plan.json").write_text(json.dumps(matrix, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
        output.write(f"standard={json.dumps(standard or {}, separators=(',', ':'))}\n")
        output.write(f"remote_upload={json.dumps(remote_upload or {}, separators=(',', ':'))}\n")
        output.write(f"standard_sha={standard['sha'] if standard else ''}\n")
        output.write(f"remote_sha={remote_upload['sha'] if remote_upload else ''}\n")
        output.write(f"build_windows={str(windows).lower()}\n")
    print(json.dumps(matrix, indent=2))


if __name__ == "__main__":
    main()
