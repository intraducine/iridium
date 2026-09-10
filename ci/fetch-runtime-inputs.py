#!/usr/bin/env python3
"""Fetch digest-locked build inputs. Existing source directories are never replaced."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def destination(root, entry):
    path = root / entry["destination"]
    if not path.resolve().is_relative_to(root.resolve()) or path.resolve() == root.resolve():
        raise ValueError("Input destination escapes the checkout")
    if not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]):
        raise ValueError("Input requires an exact SHA-256 digest")
    if not entry["url"].startswith("https://"):
        raise ValueError("Build input must use HTTPS")
    return path


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def unpack(archive, target, archive_root):
    if target.exists():
        raise ValueError(f"Refusing to overwrite source directory: {target}")
    # Extract beside the destination, then rename only after all members pass
    # tarfile's data filter (blocks traversal, devices, and escaping links).
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent, prefix=".extract-") as temp:
        with tarfile.open(archive) as tar:
            if any(Path(member.name).parts[0] != archive_root for member in tar if Path(member.name).parts):
                raise ValueError("Unexpected archive root")
            tar.extractall(temp, filter="data")
        source = Path(temp) / archive_root
        if not source.is_dir() or source.is_symlink():
            raise ValueError("Archive has no source directory")
        source.rename(target)


def fetch(root, entry):
    target = destination(root, entry)
    archive = root / ".build/runtime-downloads" / (entry["sha256"] + ".tar")
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as temp:
            temporary = Path(temp.name)
            try:
                with urllib.request.urlopen(entry["url"], timeout=120) as response:
                    shutil.copyfileobj(response, temp)
                temp.flush()
                if digest(temporary) != entry["sha256"]:
                    raise ValueError(f"Digest mismatch for {entry['name']}; nothing extracted")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    if digest(archive) != entry["sha256"]:
        raise ValueError(f"Cached input digest mismatch: {entry['name']}")
    if "archive_root" in entry:
        unpack(archive, target, entry["archive_root"])
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and digest(target) != entry["sha256"]:
            raise ValueError(f"Refusing to overwrite changed input: {target}")
        shutil.copyfile(archive, target)
    print(f"Verified {entry['name']}: {entry['sha256']}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", action="store_true", help="List inputs without downloading or changing files")
    args = parser.parse_args()
    entries = json.loads((ROOT / "ci/runtime-inputs.json").read_text())
    for entry in entries:
        destination(ROOT, entry)
        if args.plan:
            print(f"{entry['name']}: {entry['url']} -> {entry['destination']}")
        else:
            fetch(ROOT, entry)
