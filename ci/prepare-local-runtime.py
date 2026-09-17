#!/usr/bin/env python3
"""Incrementally refresh locally staged native runtime inputs before IPA builds.

Local IPA builds keep a native-input fingerprint in .build. Pure Swift/UI edits
reuse the existing FEX/Wine/DXMT/native outputs. Changes to those sources,
compiler recipes, toolchain identity, or staged media/userland/prefix artifacts
refresh the native stack before packaging.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "ci"
STATE = ROOT / ".build/local-native-runtime-state.json"
INCOMPLETE = STATE.with_suffix(".incomplete")
RUNTIME_ROOT = ROOT / "iridium-runtime-sdk/build/iridium-runtime-base"
APP = ROOT / "testrepos/Madeira/app/Madeira"
TRANSLATOR = ROOT / "iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a"
WORKFLOW = ".github/workflows/build-unsigned-ipa.yml"
MEDIA = ROOT / "iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a"
PREFIX = APP / "prefix-template.tar.gz"
USERLAND = RUNTIME_ROOT / "Userland/wine-userland.tar.zst"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def run(*args: str) -> None:
    print("+ " + " ".join(args), flush=True)
    subprocess.run(args, cwd=ROOT, check=True)


def output(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def head_short() -> str:
    return output("git", "rev-parse", "--short=12", "HEAD")


def existing_producer(provenance) -> str | None:
    manifest = RUNTIME_ROOT / "manifest.json"
    if not manifest.is_file():
        return None
    try:
        version = str(json.loads(manifest.read_text()).get("version", ""))
        return provenance.resolve_commit(provenance.producer_from_version(version))
    except (ValueError, subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def native_fingerprint(provenance) -> str:
    reuse = provenance.load_reuse()
    digest = hashlib.sha256()

    def add(label: str, value: str) -> None:
        digest.update(label.encode())
        digest.update(b"\0")
        digest.update(value.encode())
        digest.update(b"\0")

    paths = provenance.native_contract_inputs(reuse)
    for path in paths:
        add("tree:" + path, reuse.git(ROOT, "ls-tree", "HEAD", "--", path))

    # HEAD alone misses uncommitted source fixes. Include tracked working-tree
    # changes (including managed submodule changes) without deleting any edits.
    add("working-tree", reuse.git(ROOT, "diff", "--binary", "--submodule=diff", "--ignore-submodules=none", "HEAD", "--", *paths))
    untracked = reuse.git(ROOT, "ls-files", "--others", "--exclude-standard", "-z", "--", *paths)
    for name in sorted(filter(None, untracked.split("\0"))):
        path = ROOT / name
        add("untracked:" + name, os.readlink(path) if path.is_symlink() else file_digest(path))
    workflow = reuse.git(ROOT, "show", "HEAD:" + WORKFLOW)
    for component in ("native", "wine", "windows"):
        add("recipe:" + component, reuse.producer_job(workflow, component))

    for command in (
        ("xcodebuild", "-version"),
        ("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"),
        ("uname", "-m"),
    ):
        add("tool:" + " ".join(command), output(*command))

    # These artifacts are deliberately reused by the local native build. Include
    # their actual bytes in the fingerprint so replacing one invalidates the
    # native cache even when git source did not change.
    for label, path in (("media", MEDIA), ("prefix", PREFIX), ("userland", USERLAND)):
        add("artifact:" + label, file_digest(path) if path.is_file() else "missing")

    return digest.hexdigest()


def native_worktree_dirty(provenance) -> bool:
    reuse = provenance.load_reuse()
    paths = provenance.native_contract_inputs(reuse)
    return bool(reuse.git(ROOT, "diff", "--name-only", "--ignore-submodules=none", "HEAD", "--", *paths)
                or reuse.git(ROOT, "ls-files", "--others", "--exclude-standard", "--", *paths))


def read_state() -> dict:
    try:
        data = json.loads(STATE.read_text())
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_state(fingerprint: str, retained_revision: str) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "fingerprint": fingerprint,
        "revision": output("git", "rev-parse", "HEAD"),
        "runtimeVersion": "local-" + head_short(),
        "retainedRevision": retained_revision,
        "outputs": load("local_staging", CI / "local_runtime_staging.py").native_output_inventory(ROOT),
    }
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(STATE)


def ensure_prefix_transfer() -> None:
    target = ROOT / ".build/prefix-transfer/prefix-template.tar.gz"
    if target.is_file() and PREFIX.is_file() and file_digest(target) == file_digest(PREFIX):
        return
    if not PREFIX.is_file():
        raise RuntimeError(
            "No staged Wine prefix is available. Run the full GitHub Actions IPA build once."
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PREFIX, target)


def rebuild_native_runtime(previous: str | None) -> None:
    if not USERLAND.is_file():
        raise RuntimeError(
            "The staged runtime has no Wine userland to reuse. Run the full GitHub Actions IPA build once."
        )
    if not MEDIA.is_file():
        raise RuntimeError(
            "The staged media SDK is missing. Run the full GitHub Actions IPA build once."
        )

    ensure_prefix_transfer()
    run("python3", "ci/prepare-local-runtime-inputs.py")

    # CMake/Ninja/Make/Meson keep their local build directories. A refresh is
    # therefore incremental even though all stages are invoked in dependency order.
    run("bash", "ci/prepare-native-runtime.sh")
    run("bash", "ci/compile-wine.sh")
    run("bash", "ci/compile-windows-modules.sh")
    run("bash", "ci/prepare-windows-runtime.sh")

    if not TRANSLATOR.is_file():
        raise RuntimeError(f"Native rebuild did not produce translator: {TRANSLATOR}")

    with tempfile.TemporaryDirectory(dir=ROOT / ".build") as temp_name:
        temp = Path(temp_name)
        saved_userland = temp / "wine-userland.tar.zst"
        shutil.copy2(USERLAND, saved_userland)
        rebuilt = temp / "iridium-runtime-base"
        run(
            "bash",
            "iridium-runtime-sdk/scripts/build_runtime_bundle.sh",
            "--bundle-version",
            "local-" + head_short(),
            "--translator",
            str(TRANSLATOR),
            "--userland",
            str(saved_userland),
            "--output-root",
            str(rebuilt),
        )
        if not (rebuilt / "manifest.json").is_file():
            raise RuntimeError("Runtime bundle rebuild did not produce a manifest")

        backup = RUNTIME_ROOT.with_name(RUNTIME_ROOT.name + ".previous")
        if backup.exists():
            shutil.rmtree(backup)
        if RUNTIME_ROOT.exists():
            RUNTIME_ROOT.rename(backup)
        try:
            shutil.move(str(rebuilt), str(RUNTIME_ROOT))
        except BaseException:
            if RUNTIME_ROOT.exists():
                shutil.rmtree(RUNTIME_ROOT)
            if backup.exists():
                backup.rename(RUNTIME_ROOT)
            raise
        else:
            if backup.exists():
                shutil.rmtree(backup)

    print(
        "Local native runtime refreshed"
        + (f" from {previous[:12]}" if previous else "")
        + f" to {head_short()}",
        flush=True,
    )


def verify_retained_inputs(reuse, revision: str) -> None:
    """A native refresh must not relabel incompatible Linux/media assets."""
    stages = {
        "media": reuse.MEDIA_INPUTS,
        "prefix": reuse.PREFIX_INPUTS,
        "linux-userland": tuple(reuse.linux.INPUTS),
        "graphics": reuse.COMPONENT_INPUTS["graphics"],
        "jit": reuse.COMPONENT_INPUTS["jit"],
    }
    old_workflow = reuse.git(ROOT, "show", revision + ":" + WORKFLOW)
    new_workflow = reuse.git(ROOT, "show", "HEAD:" + WORKFLOW)
    corrections = load("fex_runtime_corrections", CI / "apply-fex-runtime-corrections.py")
    problems = []
    for stage, paths in stages.items():
        changed = [path for path in paths
                   if reuse.git(ROOT, "ls-tree", revision, "--", path)
                   != reuse.git(ROOT, "ls-tree", "HEAD", "--", path)]
        tracked = reuse.git(ROOT, "diff", "--name-only", "-z", "HEAD", "--", *paths)
        untracked = reuse.git(ROOT, "ls-files", "--others", "--exclude-standard", "-z", "--", *paths)
        dirty = set(filter(None, tracked.split("\0")))
        dirty.update(filter(None, untracked.split("\0")))

        # fex-thread-init-failure.patch intentionally edits Madeira Wine source,
        # while PREFIX_INPUTS conservatively covers the whole Wine tree. Ignore
        # only files proven to be byte-for-byte HEAD plus that managed patch.
        # Any extra edit, mode change, deletion, symlink, or unrelated Wine file
        # remains dirty and still invalidates retained prefix provenance.
        dirty.difference_update(
            corrections.exact_managed_patch_changes(ROOT, corrections.THREAD_PATCH, dirty)
        )
        if changed or dirty or reuse.producer_job(old_workflow, stage) != reuse.producer_job(new_workflow, stage):
            problems.append(stage)
    if problems:
        raise RuntimeError("Retained inputs need matching producers: " + ", ".join(problems)
                           + ". The local native build does not rebuild these components. "
                             "Restore matching inputs via docs/actions-ipa.md; no compiler work started.")


def main() -> None:
    staging = load("local_staging", CI / "local_runtime_staging.py")
    staging.recover_bundle(ROOT)
    staging.check_retained_inputs(ROOT)
    provenance = load("local_runtime_provenance", CI / "check-local-runtime-provenance.py")
    state = read_state()
    producer = existing_producer(provenance)
    pending = {}
    if INCOMPLETE.exists():
        try:
            pending = json.loads(INCOMPLETE.read_text())
        except (OSError, ValueError):
            pass
    if not isinstance(pending, dict):
        pending = {}
    retained = pending.get("retainedRevision") or state.get("retainedRevision") or producer
    if not retained:
        raise RuntimeError("Cannot identify the retained runtime producer. Restore matching runtime inputs before building.")
    reuse = provenance.load_reuse()
    verify_retained_inputs(reuse, retained)
    fingerprint = native_fingerprint(provenance)

    contract_ok = False
    if producer is not None:
        try:
            provenance.verify_native_contract(reuse, producer)
            contract_ok = True
        except (ValueError, subprocess.CalledProcessError):
            pass
    try:
        outputs = staging.native_output_inventory(ROOT)
    except (OSError, ValueError) as error:
        print(str(error), flush=True)
        outputs = None

    force = os.environ.get("IRIDIUM_FORCE_NATIVE_REBUILD") == "1" or INCOMPLETE.exists()
    if (not force and state.get("fingerprint") == fingerprint and contract_ok
            and outputs is not None and state.get("outputs") == outputs):
        print(
            f"Local native runtime unchanged; reusing {state.get('revision', producer or 'unknown')[:12]}",
            flush=True,
        )
        return

    # Only seed a genuinely complete, compatible initial staging. A failed
    # rebuild leaves INCOMPLETE and can never enter this path on the next run.
    if (not force and not state and contract_ok and outputs is not None
            and not native_worktree_dirty(provenance)):
        write_state(fingerprint, retained)
        print(f"Local native runtime compatible; seeded cache from {producer[:12]}", flush=True)
        return

    reason = "forced/interrupted refresh" if force else "inputs changed or compiler outputs missing/changed"
    print(f"Refreshing local native runtime: {reason}", flush=True)
    INCOMPLETE.parent.mkdir(parents=True, exist_ok=True)
    INCOMPLETE.write_text(json.dumps({"retainedRevision": retained}) + "\n")
    STATE.unlink(missing_ok=True)
    rebuild_native_runtime(producer)
    fingerprint = native_fingerprint(provenance)
    producer = existing_producer(provenance)
    if producer is None:
        raise RuntimeError("Rebuilt local runtime does not identify its producer")
    provenance.verify_native_contract(reuse, producer)
    # Publish success only after validating provenance AND compiler outputs.
    write_state(fingerprint, retained)
    INCOMPLETE.unlink()


if __name__ == "__main__":
    main()
