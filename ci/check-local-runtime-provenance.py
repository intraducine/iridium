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
WORKFLOW = ".github/workflows/build-unsigned-ipa.yml"


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


def native_contract_inputs(reuse) -> tuple[str, ...]:
    paths = set()
    for component in ("native", "wine", "windows", "graphics"):
        paths.update(reuse.COMPONENT_INPUTS[component])
    # These files are compiled into the app on every local build but define the
    # contract consumed by the staged Wine/FEX binaries. A newer app bridge must
    # never be paired with an older translator that does not understand it.
    paths.update(
        {
            "iridium/apps/ios/MadeiraSupport/NativePool.c",
            "iridium/apps/ios/MadeiraSupport/MadeiraNative.h",
            "testrepos/Madeira/app/Madeira/Winios/Winios.m",
            "testrepos/Madeira/app/Madeira/WineProcessBridge.m",
            "testrepos/Madeira/app/Madeira/WineServerBridge.m",
            "ci/prepare-legacy-bundle.sh",
        }
    )
    return tuple(sorted(paths))


def verify_native_contract(reuse, revision: str) -> None:
    for path in native_contract_inputs(reuse):
        old = reuse.git(ROOT, "ls-tree", revision, "--", path)
        new = reuse.git(ROOT, "ls-tree", "HEAD", "--", path)
        if old != new:
            raise ValueError(f"native/runtime input changed since {revision[:12]}: {path}")

    old_workflow = reuse.git(ROOT, "show", revision + ":" + WORKFLOW)
    new_workflow = reuse.git(ROOT, "show", "HEAD:" + WORKFLOW)
    for component in ("native", "wine", "windows", "graphics"):
        if reuse.producer_job(old_workflow, component) != reuse.producer_job(new_workflow, component):
            raise ValueError(f"{component} compiler recipe changed since {revision[:12]}")


def main() -> None:
    if not MANIFEST.is_file():
        raise SystemExit(f"Missing local runtime manifest: {MANIFEST}")
    manifest = json.loads(MANIFEST.read_text())
    try:
        short_sha = producer_from_version(str(manifest.get("version", "")))
        revision = resolve_commit(short_sha)
        reuse = load_reuse()
        verify_native_contract(reuse, revision)
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(
            "Stale local native runtime: " + str(error) + "\n"
            "The local IPA build reuses iridium-runtime-sdk/build plus staged Wine/FEX "
            "outputs. Do not package those binaries with newer app/runtime bridge code. "
            "Refresh native dependencies or use a fresh GitHub Actions IPA build."
        ) from error
    print(f"Local native runtime is source-compatible: {revision[:12]}")


if __name__ == "__main__":
    main()
