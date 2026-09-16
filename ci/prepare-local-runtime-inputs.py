#!/usr/bin/env python3
"""Prepare pinned runtime sources for repeated local native builds.

Unlike the clean-runner Actions helper, local builds may already have extracted
source trees, parent-managed submodules, or standalone checkouts at gitlink
paths. Repair only clean submodules owned by this Iridium checkout; preserve
standalone/local source and initialize only genuinely missing dependencies.
"""
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / "testrepos/Madeira"
STATE = ROOT / ".build/local-runtime-inputs.json"


def run(*args: str, cwd: Path = ROOT) -> None:
    print("+ " + " ".join(args), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def read_state() -> dict[str, str]:
    try:
        data = json.loads(STATE.read_text())
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_state(state: dict[str, str]) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    temporary.replace(STATE)


def refresh_pinned_inputs() -> None:
    entries = json.loads((ROOT / "ci/runtime-inputs.json").read_text())
    state = read_state()
    first_state = not state
    for entry in entries:
        name = entry["name"]
        expected = entry["sha256"]
        destination = ROOT / entry["destination"]
        recorded = state.get(name)
        if destination.exists() and (recorded == expected or first_state):
            # Existing local trees predate this cache file. Seed their current pin
            # once; future pin changes are then explicit and reproducible.
            print(f"Reuse local runtime input {name}: {destination}", flush=True)
            state[name] = expected
            continue
        if destination.exists():
            print(f"Pinned runtime input changed; replacing {name}: {destination}", flush=True)
            if destination.is_dir() and not destination.is_symlink():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        run("python3", "ci/fetch-runtime-inputs.py", "--only", name)
        state[name] = expected
    write_state(state)


def expected_gitlink(module: str) -> str:
    line = subprocess.check_output(
        ["git", "ls-tree", "HEAD", "--", module], cwd=ROOT, text=True
    ).strip()
    fields = line.split()
    if len(fields) < 3 or fields[0] != "160000":
        raise RuntimeError(f"Expected gitlink is missing for local dependency: {module}")
    return fields[2]


def checkout_info(path: Path) -> tuple[str | None, bool]:
    """Return (HEAD, managed_by_this_superproject) for a standalone Git worktree."""
    try:
        top = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None, False
    if Path(top).resolve() != path.resolve():
        return None, False

    head = subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()
    superproject = subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "--show-superproject-working-tree"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    managed = bool(superproject) and Path(superproject).resolve() == ROOT.resolve()
    return head, managed


def checkout_dirty(path: Path) -> bool:
    status = subprocess.check_output(
        ["git", "-C", str(path), "status", "--porcelain"], text=True
    )
    return bool(status.strip())


def prepare_submodules(modules: list[str]) -> None:
    update = []
    for module in modules:
        path = ROOT / module
        if path.is_symlink():
            raise RuntimeError(f"Refusing symlink at local submodule path: {module}")
        if not path.is_dir() or not any(path.iterdir()):
            update.append(module)
            continue

        expected = expected_gitlink(module)
        actual, managed = checkout_info(path)
        if actual is None:
            print(f"Reuse local submodule source {module}: existing source tree", flush=True)
            continue
        if actual == expected:
            detail = actual[:12] + (" (local changes preserved)" if checkout_dirty(path) else "")
            print(f"Reuse local submodule source {module}: {detail}", flush=True)
            continue

        if managed:
            if checkout_dirty(path):
                raise RuntimeError(
                    f"Managed submodule {module} is at {actual[:12]}, expected {expected[:12]}, "
                    "and has local changes. Refusing to overwrite them."
                )
            print(
                f"Repair clean managed submodule {module}: {actual[:12]} -> {expected[:12]}",
                flush=True,
            )
            update.append(module)
            continue

        raise RuntimeError(
            f"Standalone checkout {module} is at {actual[:12]}, expected {expected[:12]}. "
            "Refusing to overwrite local source."
        )

    if update:
        run("git", "submodule", "update", "--init", "--depth", "1", "--", *update)


def main() -> None:
    run("xcodebuild", "-downloadComponent", "MetalToolchain")
    run("xcrun", "--sdk", "iphoneos", "metal", "--version")
    refresh_pinned_inputs()

    modules = []
    for fork in ("iridium-fex-ios", "testrepos/Madeira/FEX"):
        for module in ("fmt", "range-v3", "rpmalloc", "unordered_dense", "vixl", "xxhash"):
            modules.append(f"{fork}/External/{module}")
        modules.append(f"{fork}/Source/Common/cpp-optparse")
    modules.append("testrepos/Madeira/research/dxmt/include/native/directx")
    prepare_submodules(modules)

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
