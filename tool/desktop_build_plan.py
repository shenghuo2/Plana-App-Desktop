"""Pin both editions before building; reject mismatched release versions."""

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
        "dmg": "Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg" if remote else "Plana-App-Desktop-macOS-arm64.dmg",
        "artifact": "Plana-App-Desktop-RemoteUpload-macOS-ad-hoc" if remote else "Plana-App-Desktop-macOS-ad-hoc",
        "volume": "Plana App Desktop Remote Upload" if remote else "Plana App Desktop",
    }


def validate_versions(entries):
    if len({e["version"] for e in entries}) != 1:
        raise ValueError("Edition versions/build numbers differ; merge the release version into feature/remote-upload first")


def main():
    dispatch = os.environ["BUILD_EVENT"] == "workflow_dispatch"
    release_tag = not dispatch and os.environ.get("BUILD_REF_TYPE") == "tag"
    entries = []
    if release_tag:
        entries.append(entry("standard", os.environ["BUILD_BRANCH"], os.environ["BUILD_SHA"]))
        remote = os.environ["REMOTE_BRANCH"]
        entries.append(entry("remoteUpload", remote, branch_sha(remote)))
        if entries[0]["version"].split("+")[0] != os.environ["BUILD_BRANCH"].removeprefix("v"):
            raise ValueError("Release tag does not match pubspec version")
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
        branch = os.environ["BUILD_BRANCH"]
        edition = "remoteUpload" if branch == "feature/remote-upload" else "standard"
        entries.append(entry(edition, branch, os.environ["BUILD_SHA"]))
    validate_versions(entries)
    standard = next((e for e in entries if e["edition"] == "standard"), None)
    windows = standard is not None and (
        not dispatch or os.environ["BUILD_WINDOWS"].lower() == "true"
    )
    matrix = {"include": entries}
    Path("desktop-build-plan.json").write_text(json.dumps(matrix, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
        output.write(f"standard_sha={standard['sha'] if standard else ''}\n")
        output.write(f"build_windows={str(windows).lower()}\n")
    print(json.dumps(matrix, indent=2))


if __name__ == "__main__":
    main()
