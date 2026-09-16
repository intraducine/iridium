#!/usr/bin/env python3
"""Reject local IPA builds that mix current app code with a stale native runtime."""
import importlib.util
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "iridium-runtime-sdk/build/iridium-runtime-base"
MANIFEST = BUNDLE / "manifest.json"


def load_reuse():
    spec = importlib.util.spec_from_file_location("reuse_build_assets", ROOT / "ci/reuse-build-assets.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def producer_from_version(version: str) -> str:
    match = re.fullmatch(r"ci-([0-9a-f]{12})", version or "")
    if not match:
        raise ValueError(
            "Local runtime manifest does not identify its producer commit. "
            "Refresh the staged native runtime before building the IPA."
        )
    return match.group(1)


def resolve_commit(short_sha: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", short_sha + "^{commit}"],
            text=True,
        ).strip()
    except subprocess.CalledProcessError as error:
        raise ValueError(
            f"Local runtime producer {short_sha} is not present in this checkout. "
            "Refresh the staged native runtime before building the IPA."
        ) from error


def main() -> None:
    if not MANIFEST.is_file():
        raise SystemExit(f"Missing local runtime manifest: {MANIFEST}")
    manifest = json.loads(MANIFEST.read_text())
    try:
        short_sha = producer_from_version(str(manifest.get("version", "")))
        revision = resolve_commit(short_sha)
        reuse = load_reuse()
        reuse.compatible(ROOT, revision, "native-runtime")
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(
            "Stale local native runtime: " + str(error) + "\n"
            "The local IPA build reuses iridium-runtime-sdk/build. Do not package this "
            "runtime with newer app source. Refresh native dependencies or use a fresh "
            "GitHub Actions IPA build."
        ) from error
    print(f"Local native runtime is source-compatible: {revision[:12]}")


if __name__ == "__main__":
    main()
