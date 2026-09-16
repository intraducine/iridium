#!/usr/bin/env python3
"""Repair local staging from the canonical archive without rebuilding Linux.

The extracted cache stays outside iridium-runtime-base so native refreshes and
SwiftPM resource copies cannot delete it or duplicate it into the IPA. Validation
runs the actual Xcode stage script in read-only mode, not a second ELF validator.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'iridium-runtime-sdk/build/iridium-runtime-base'
STAGED = 'iridium-runtime-sdk/build/wine-userland-linux-x86_64/staged-root'
MARKER = '.iridium-local-extraction.json'


def load(root, filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), root / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def archive_identity(root):
    bundle = root / BUNDLE
    archive = bundle / 'Userland/wine-userland.tar.zst'
    manifest = json.loads((bundle / 'manifest.json').read_text())
    records = [item for item in manifest.get('artifacts', [])
               if item.get('identifier') == 'wine-userland'
               and item.get('relativePath') == 'Userland/wine-userland.tar.zst']
    if len(records) != 1:
        raise ValueError('Canonical manifest must identify exactly one Wine userland archive.')
    checksum = digest(archive)
    if records[0].get('checksum') != checksum or records[0].get('sizeBytes') != archive.stat().st_size:
        raise ValueError('Canonical Wine userland checksum/size mismatch; keep the archive with its matching manifest.')
    return archive, checksum


def tree_inventory(root):
    """Detect deleted, replaced or edited cache files without reading every DLL."""
    entries = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative == MARKER:
                continue
            stat = path.lstat()
            if path.is_symlink():
                # Neither validation nor a later ditto may follow a host link.
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError('Userland link escapes its staging root: ' + relative)
                entries[relative] = ['link', os.readlink(path)]
            elif path.is_file():
                entries[relative] = ['file', stat.st_size, stat.st_mtime_ns, stat.st_mode]
            elif not path.is_dir():
                raise ValueError('Unexpected userland file type: ' + relative)
    return entries


def validate_sources(root, staged):
    env = dict(os.environ, SRCROOT=str(root / 'iridium/apps/ios'),
               TARGET_BUILD_DIR=str(root / '.build/local-staging-check'),
               UNLOCALIZED_RESOURCES_FOLDER_PATH='Iridium.app',
               FRAMEWORKS_FOLDER_PATH='Iridium.app/Frameworks',
               IRIDIUM_RUNTIME_BUNDLE_ROOT=str(root / BUNDLE),
               IRIDIUM_WINE_STAGED_ROOT=str(staged))
    result = subprocess.run(['sh', str(root / 'iridium/apps/ios/Scripts/stage_runtime_userland.sh'), '--check'],
                            env=env, text=True, capture_output=True, check=False, timeout=120)
    if result.returncode:
        raise ValueError('Runtime staging preflight failed:\n' + result.stdout + result.stderr)


def ensure_userland(root):
    root = Path(root).resolve()
    archive, checksum = archive_identity(root)
    target = root / STAGED
    if target.is_symlink() or not target.parent.resolve().is_relative_to(root):
        raise ValueError('Refusing to replace a userland staging path outside the checkout.')
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        record = json.loads((target / MARKER).read_text())
        unchanged = (isinstance(record, dict) and record.get('sha256') == checksum and record.get('files') == tree_inventory(target))
    except (OSError, ValueError):
        unchanged = False
    if unchanged:
        validate_sources(root, target)
        print('Local Linux userland unchanged; reusing validated extracted files.', flush=True)
        return target

    extractor = load(root, 'stage-linux-userland.py')
    with tempfile.TemporaryDirectory(prefix='.userland-', dir=target.parent) as temporary:
        temporary = Path(temporary)
        payload = temporary / 'payload'
        extractor.extract(archive, payload)
        files = tree_inventory(payload)
        validate_sources(root, payload)
        # Do not publish an extraction made while its input archive was changing.
        if digest(archive) != checksum:
            raise ValueError('Wine userland archive changed during extraction; retry the build.')
        if (payload / MARKER).exists() or (payload / MARKER).is_symlink():
            raise ValueError('Archive contains reserved local cache metadata.')
        (payload / MARKER).write_text(json.dumps({'sha256': checksum, 'files': files}, sort_keys=True) + '\n')
        previous = temporary / 'previous'
        if target.exists():
            target.rename(previous)
        try:
            payload.rename(target)
        except BaseException:
            if previous.exists():
                previous.rename(target)
            raise
    print('Restored and validated local Linux userland from the canonical archive.', flush=True)
    return target


def recover_bundle(root):
    """Recover an interrupted directory swap without touching compiler caches."""
    bundle = root / BUNDLE
    previous = bundle.with_name(bundle.name + '.previous')
    if (bundle.is_symlink() or previous.is_symlink()
            or not bundle.parent.resolve().is_relative_to(root.resolve())):
        raise ValueError('Runtime bundle and recovery paths must not be symlinks.')
    if not bundle.exists() and previous.is_dir():
        previous.rename(bundle)
        print('Recovered the previous canonical runtime after an interrupted refresh.', flush=True)


def retained_inputs(root):
    required = load(root, 'check-ipa-prerequisites.py').REQUIRED
    return [*required['legacy graphics frameworks'], *required['StikJIT framework'],
            'testrepos/Madeira/app/Madeira/prefix-template.tar.gz',
            'iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a',
            BUNDLE + '/manifest.json', BUNDLE + '/Userland/wine-userland.tar.zst']


def check_retained_inputs(root):
    missing = [name for name in retained_inputs(root)
               if not (root / name).is_file() or not (root / name).stat().st_size]
    if missing:
        raise ValueError('Missing retained build inputs (no compiler work started):\n  '
                         + '\n  '.join(missing)
                         + '\nRestore matching runtime dependencies as described in docs/actions-ipa.md. '
                           'Do not delete compiler caches or bypass the package audit.')
    archive_identity(root)


def native_output_inventory(root):
    """Track required outputs as well as all staged DLLs and FEX link archives."""
    required = load(root, 'check-ipa-prerequisites.py').REQUIRED
    groups = ('legacy runtime host and userland', 'legacy native link libraries',
              'Madeira native runtime', 'Windows modules and clean prefix', 'media and input runtime')
    names = {name for group in groups for name in required[group]}
    # The embedded bridge is not a monolithic archive; its companion libraries
    # are still linked by Xcode. A deleted companion must invalidate reuse too.
    fex = 'iridium-fex-ios/build-iridium-ios-iphoneos/'
    names.update(fex + name for name in (
        'Source/Tools/CommonTools/libCommonTools.a', 'Source/Common/libCommon.a',
        'Source/Common/cpp-optparse/libcpp-optparse.a', 'FEXCore/Source/libFEXCore.a',
        'FEXCore/Source/libFEXCore_Base.a', 'FEXCore/Source/libJemallocLibs.a',
        'External/fmt/libfmt.a', 'External/xxhash/cmake_unofficial/libxxhash.a',
        'External/rpmalloc/librpmalloc.a', 'External/tiny-json/libtiny-json.a',
        'External/cephes/libcephes_128bit.a', 'External/SoftFloat-3e/libsoftfloat_3e.a'))
    for directory in ('testrepos/Madeira/app/Madeira/arm64ec-windows',
                      'testrepos/Madeira/app/Madeira/aarch64-windows',
                      'iridium/apps/ios/MediaRuntime', 'iridium/apps/ios/ControllerRuntime'):
        names.update(p.relative_to(root).as_posix() for p in (root / directory).rglob('*') if p.is_file())
    missing = [name for name in sorted(names) if not (root / name).is_file() or not (root / name).stat().st_size]
    if missing:
        raise ValueError('Missing native compiler outputs:\n  ' + '\n  '.join(missing))
    return {name: [(root / name).stat().st_size, (root / name).stat().st_mtime_ns] for name in sorted(names)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-inputs', action='store_true')
    args = parser.parse_args()
    try:
        if args.check_inputs:
            check_retained_inputs(ROOT)
        else:
            ensure_userland(ROOT)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Local runtime staging: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
