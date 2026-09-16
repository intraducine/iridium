#!/usr/bin/env python3
"""Incrementally refresh locally staged native runtime inputs before IPA builds.

The bundled runtime manifest records the commit that produced the currently staged
native runtime. Compare only runtime/compiler inputs against that producer. Pure
app/UI commits therefore reuse native outputs, while FEX/Wine/DXMT/native bridge
changes rebuild the local native stack before packaging.
"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "ci"
RUNTIME_ROOT = ROOT / "iridium-runtime-sdk/build/iridium-runtime-base"
MANIFEST = RUNTIME_ROOT / "manifest.json"
APP = ROOT / "testrepos/Madeira/app/Madeira"
TRANSLATOR = ROOT / "iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a"
WORKFLOW = ".github/workflows/build-unsigned-ipa.yml"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def run(*args: str) -> None:
    print("+ " + " ".join(args), flush=True)
    subprocess.run(args, cwd=ROOT, check=True)


def changed_paths(reuse, revision: str, paths) -> list[str]:
    changed = []
    for path in sorted(set(paths)):
        old = reuse.git(ROOT, "ls-tree", revision, "--", path)
        new = reuse.git(ROOT, "ls-tree", "HEAD", "--", path)
        if old != new:
            changed.append(path)
    return changed


def recipe_changed(reuse, revision: str, stage: str) -> bool:
    old = reuse.git(ROOT, "show", revision + ":" + WORKFLOW)
    new = reuse.git(ROOT, "show", "HEAD:" + WORKFLOW)
    return reuse.producer_job(old, stage) != reuse.producer_job(new, stage)


def existing_producer(provenance) -> str:
    if not MANIFEST.is_file():
        raise ValueError(f"Missing local runtime manifest: {MANIFEST}")
    manifest = json.loads(MANIFEST.read_text())
    short_sha = provenance.producer_from_version(str(manifest.get("version", "")))
    return provenance.resolve_commit(short_sha)


def unsupported_changes(reuse, revision: str) -> list[str]:
    """Return dependencies that require the full cross-platform Actions pipeline."""
    reasons = []
    media = changed_paths(reuse, revision, reuse.MEDIA_INPUTS)
    if media or recipe_changed(reuse, revision, "media"):
        reasons.append("media SDK")

    prefix = changed_paths(reuse, revision, reuse.PREFIX_INPUTS)
    if prefix or recipe_changed(reuse, revision, "prefix"):
        reasons.append("Linux-built Wine prefix")

    linux_inputs = tuple(reuse.linux.INPUTS) + ("check-public-source.py",)
    linux = changed_paths(reuse, revision, linux_inputs)
    if linux or recipe_changed(reuse, revision, "linux-userland"):
        reasons.append("Linux Wine userland")

    graphics = changed_paths(reuse, revision, reuse.COMPONENT_INPUTS["graphics"])
    if graphics or recipe_changed(reuse, revision, "graphics"):
        reasons.append("ANGLE graphics frameworks")
    return reasons


def ensure_prefix_transfer() -> None:
    """Reuse the staged prefix when prefix-producing inputs are unchanged."""
    target = ROOT / ".build/prefix-transfer/prefix-template.tar.gz"
    if target.is_file():
        return
    source = APP / "prefix-template.tar.gz"
    if not source.is_file():
        raise RuntimeError(
            "No staged Wine prefix is available. Run the full GitHub Actions IPA build once."
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def rebuild_native_runtime(revision: str) -> None:
    userland = RUNTIME_ROOT / "Userland/wine-userland.tar.zst"
    media = ROOT / "iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a"
    if not userland.is_file():
        raise RuntimeError(
            "The staged runtime has no Wine userland to reuse. Run the full GitHub Actions IPA build once."
        )
    if not media.is_file():
        raise RuntimeError(
            "The staged media SDK is missing. Run the full GitHub Actions IPA build once."
        )

    ensure_prefix_transfer()

    # Local source trees persist between builds, unlike a clean Actions runner.
    # Fetch only missing pinned inputs and preserve already-extracted trees.
    run("python3", "ci/prepare-local-runtime-inputs.py")

    # These build systems are incremental: unchanged objects remain cached while
    # source changes invalidate only the affected CMake/Ninja/Make/Meson outputs.
    run("bash", "ci/prepare-native-runtime.sh")
    run("bash", "ci/compile-wine.sh")
    run("bash", "ci/compile-windows-modules.sh")
    run("bash", "ci/prepare-windows-runtime.sh")

    if not TRANSLATOR.is_file():
        raise RuntimeError(f"Native rebuild did not produce translator: {TRANSLATOR}")

    # Repackage the runtime with the freshly rebuilt embedded translator while
    # preserving the unchanged Linux userland. Build into a temporary directory
    # so a failed refresh never destroys the last usable staged runtime.
    with tempfile.TemporaryDirectory(dir=ROOT / ".build") as temp_name:
        temp = Path(temp_name)
        saved_userland = temp / "wine-userland.tar.zst"
        shutil.copy2(userland, saved_userland)
        output = temp / "iridium-runtime-base"
        version = "ci-" + subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--short=12", "HEAD"], text=True
        ).strip()
        run(
            "bash",
            "iridium-runtime-sdk/scripts/build_runtime_bundle.sh",
            "--bundle-version",
            version,
            "--translator",
            str(TRANSLATOR),
            "--userland",
            str(saved_userland),
            "--output-root",
            str(output),
        )
        if not (output / "manifest.json").is_file():
            raise RuntimeError("Runtime bundle rebuild did not produce a manifest")
        backup = RUNTIME_ROOT.with_name(RUNTIME_ROOT.name + ".previous")
        if backup.exists():
            shutil.rmtree(backup)
        if RUNTIME_ROOT.exists():
            RUNTIME_ROOT.rename(backup)
        try:
            shutil.move(str(output), str(RUNTIME_ROOT))
        except Exception:
            if RUNTIME_ROOT.exists():
                shutil.rmtree(RUNTIME_ROOT)
            if backup.exists():
                backup.rename(RUNTIME_ROOT)
            raise
        else:
            if backup.exists():
                shutil.rmtree(backup)

    print(
        f"Local native runtime refreshed from {revision[:12]} to "
        + subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--short=12", "HEAD"], text=True
        ).strip(),
        flush=True,
    )


def main() -> None:
    provenance = load("local_runtime_provenance", CI / "check-local-runtime-provenance.py")
    reuse = provenance.load_reuse()
    try:
        revision = existing_producer(provenance)
        provenance.verify_native_contract(reuse, revision)
    except (ValueError, subprocess.CalledProcessError) as stale:
        try:
            revision = existing_producer(provenance)
        except (ValueError, subprocess.CalledProcessError) as error:
            raise SystemExit(
                "Cannot incrementally refresh the local runtime because its producer is unknown: "
                + str(error)
                + "\nRun the full GitHub Actions IPA build once to seed local dependencies."
            ) from error

        blockers = unsupported_changes(reuse, revision)
        if blockers:
            raise SystemExit(
                "Local native runtime is stale, but this revision also changed "
                + ", ".join(blockers)
                + ". Those inputs are produced by the full cross-platform pipeline. "
                "Run python3 ci/dispatch-build.py instead of mixing generations."
            ) from stale

        print("Local native runtime is stale: " + str(stale), flush=True)
        rebuild_native_runtime(revision)
        provenance.verify_native_contract(reuse, existing_producer(provenance))
        return

    print(f"Local native runtime unchanged; reusing {revision[:12]}", flush=True)


if __name__ == "__main__":
    main()
