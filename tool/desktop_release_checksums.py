"""Generate one SHA256SUMS.txt for the packages in a desktop build plan."""

import argparse
import hashlib
import json
from pathlib import Path


def write_checksums(artifacts, plan, output, build_windows=False):
    entries = plan["include"]
    editions = [entry["edition"] for entry in entries]
    if not entries or len(set(editions)) != len(editions):
        raise ValueError("Build plan must contain distinct editions")
    if not set(editions) <= {"standard", "remoteUpload"}:
        raise ValueError("Unknown desktop edition")
    versions = {entry["version"] for entry in entries}
    if len(versions) != 1:
        raise ValueError("Edition versions differ")
    expected = {entry["dmg"] for entry in entries}
    if len(expected) != len(entries):
        raise ValueError("Edition package names must be distinct")
    if build_windows:
        if "standard" not in editions:
            raise ValueError("Windows requires the standard edition")
        version = next(iter(versions)).split("+")[0]
        prefix = f"Plana-App-Desktop-Windows-{version}-x64"
        expected.update({prefix + ".zip", prefix + "-setup.exe"})

    packages = {}
    for path in artifacts.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".dmg", ".exe", ".zip"}:
            if path.name in packages:
                raise ValueError(f"Duplicate package: {path.name}")
            packages[path.name] = path
    if packages.keys() != expected:
        missing = sorted(expected - packages.keys())
        unexpected = sorted(packages.keys() - expected)
        raise ValueError(f"Package set differs from build plan: missing={missing}, unexpected={unexpected}")

    lines = []
    for name, path in sorted(packages.items()):
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        lines.append(f"{digest}  {name}\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(lines), encoding="ascii")
    return len(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--build-windows", action="store_true")
    args = parser.parse_args()
    try:
        count = write_checksums(
            args.artifacts,
            json.loads(args.plan.read_text()),
            args.output,
            args.build_windows,
        )
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"release checksums: {error}\n")
    print(f"Verified {count} packages; wrote {args.output}")


if __name__ == "__main__":
    main()
