#!/usr/bin/env python3
"""Prepare pinned runtime sources for repeated local native builds.

Unlike the clean-runner Actions helper, local builds may already have extracted
source trees. Preserve those trees and fetch only missing pinned inputs, then
refresh the exact git submodules and apply the reviewed rpmalloc patch
idempotently.
"""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / "testrepos/Madeira"


def run(*args: str, cwd: Path = ROOT) -> None:
    print("+ " + " ".join(args), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def main() -> None:
    run("xcodebuild", "-downloadComponent", "MetalToolchain")
    run("xcrun", "--sdk", "iphoneos", "metal", "--version")

    entries = json.loads((ROOT / "ci/runtime-inputs.json").read_text())
    for entry in entries:
        destination = ROOT / entry["destination"]
        if destination.exists():
            print(f"Reuse local runtime input {entry['name']}: {destination}", flush=True)
            continue
        run("python3", "ci/fetch-runtime-inputs.py", "--only", entry["name"])

    modules = []
    for fork in ("iridium-fex-ios", "testrepos/Madeira/FEX"):
        for module in ("fmt", "range-v3", "rpmalloc", "unordered_dense", "vixl", "xxhash"):
            modules.append(f"{fork}/External/{module}")
        modules.append(f"{fork}/Source/Common/cpp-optparse")
    modules.append("testrepos/Madeira/research/dxmt/include/native/directx")
    run("git", "submodule", "update", "--init", "--depth", "1", "--", *modules)

    allocator = MADEIRA / "FEX/External/rpmalloc"
    patch = ROOT / "ci/patches/rpmalloc-host-arena.patch"
    reverse = subprocess.run(
        ["git", "-C", str(allocator), "apply", "--reverse", "--check", str(patch)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if reverse.returncode == 0:
        print("rpmalloc host-arena patch already applied", flush=True)
        return
    run("git", "-C", str(allocator), "apply", "--check", str(patch))
    run("git", "-C", str(allocator), "apply", str(patch))


if __name__ == "__main__":
    main()
