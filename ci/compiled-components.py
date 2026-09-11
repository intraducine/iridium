#!/usr/bin/env python3
"""Retain completed compiler stages before runtime staging or IPA packaging."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[1]
spec = spec_from_file_location('prepared', ROOT / 'ci/prepared-runtime.py')
prepared = module_from_spec(spec)
spec.loader.exec_module(prepared)
reuse, inputs = prepared.reuse, prepared.inputs
M = 'testrepos/Madeira/'
# Keep the configured Wine tree and import libraries: later DXMT compilation
# and prefix creation use them. Object files are not needed after a stage passes.
PATHS = {
    'native': (
        M + 'toolchains/llvm-ios-build/lib', M + 'toolchains/llvm-ios-build/include',
        M + 'toolchains/gnutls-ios', M + 'build/freetype-ios/build',
        M + 'wine/build-macos', M + 'FEX/build-ios',
        'iridium-fex-ios/build-iridium-ios-iphoneos', 'iridium-wine-ios/build-iridium-ios',
        'iridium/apps/ios/MediaRuntime', 'iridium/apps/ios/ControllerRuntime',
        'iridium/apps/ios/.build/media',
    ) + tuple(name for name in prepared.FILES if name.endswith('.a')),
    'wine': (M + 'wine/build-macos',),
    'windows': (M + 'FEX/build-arm64ec/Source/Windows/ARM64EC',
                M + 'research/dxmt/build-arm64ec-ci/src', M + 'research/dxmt/build-aarch64-ci/src'),
    'graphics': tuple(t for t in prepared.TREES if t.endswith('.framework')) +
                (M + 'app/Madeira/legal/ANGLE-LICENSE.txt', '.build/corresponding-source'),
    'jit': ('iridium/apps/ios/BuiltinJIT/Vendor/StikJIT.xcframework', '.build/corresponding-source'),
}


def allowed(name, component):
    p = Path(name)
    if p.is_absolute() or '..' in p.parts or '.git' in p.parts or str(p) != name:
        return False
    if p.suffix in {'.o', '.obj', '.p12', '.pfx', '.mobileprovision'}:
        return False
    if p.is_relative_to('.build/corresponding-source'):
        # Each compiler owns only its own source archives and inventories.
        prefixes = ('angle', 'depot') if component == 'graphics' else ('StikJIT', 'idevice', 'rust-')
        return p.name.startswith(prefixes)
    return any(p == Path(base) or p.is_relative_to(base) for base in PATHS[component])


def package(root, component):
    out = root / '.build' / (component + '-compiled-transfer')
    out.mkdir(parents=True, exist_ok=False)
    archive = out / 'compiled.tar.gz'
    names = set()
    for base in PATHS[component]:
        p = root / base
        if not p.exists():
            raise ValueError('Missing compiler output: ' + base)
        paths = p.rglob('*') if p.is_dir() else (p,)
        for path in paths:
            name = path.relative_to(root).as_posix()
            if path.is_file() and allowed(name, component):
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError('Compiler output escapes checkout: ' + name)
                names.add(name)
    if not names:
        raise ValueError('No compiler outputs')
    with tarfile.open(archive, 'w:gz', dereference=True) as tar:
        for name in sorted(names):
            tar.add(root / name, arcname='compiled/' + name, recursive=False)
    record = {'revision': reuse.git(root, 'rev-parse', 'HEAD'), 'component': component,
              'toolchain': os.environ['NATIVE_TOOLCHAIN'], 'workspace': str(root.resolve()),
              'sha256': inputs.digest(archive)}
    (out / 'manifest.json').write_text(json.dumps(record) + '\n')
    print(f'Saved {component}: {len(names)} files, {archive.stat().st_size // 1048576} MiB')


def restore(root, component, run_id):
    revision = reuse.verify_producer(root, run_id, component, os.environ['GITHUB_REF_NAME'])
    transfer = root / '.build' / (component + '-compiled-transfer')
    archive, manifest = transfer / 'compiled.tar.gz', transfer / 'manifest.json'
    if archive.is_symlink() or manifest.is_symlink():
        raise ValueError('Transfer files must not be symlinks')
    record = json.loads(manifest.read_text())
    if (record.get('revision') != revision or record.get('component') != component
            or record.get('toolchain') != os.environ['NATIVE_TOOLCHAIN']
            or record.get('workspace') != str(root.resolve())
            or record.get('sha256') != inputs.digest(archive)):
        raise ValueError('Compiler artifact provenance, toolchain, workspace or checksum mismatch')
    with tarfile.open(archive) as tar:
        names = set()
        for member in tar:
            name = member.name.removeprefix('compiled/')
            if (not member.name.startswith('compiled/') or not member.isfile()
                    or not allowed(name, component) or name in names):
                raise ValueError('Unexpected compiler artifact member: ' + member.name)
            names.add(name)
    if not names:
        raise ValueError('Empty compiler artifact')
    with tempfile.TemporaryDirectory(dir=root / '.build') as temp:
        staged = Path(temp) / 'compiled'
        inputs.unpack(archive, staged, 'compiled')
        for name in names:
            if not (root / name).resolve().is_relative_to(root.resolve()):
                raise ValueError('Restore destination escapes checkout')
        for name in names:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(staged / name, target)
    print('Restored completed ' + component + ' compilation')


if __name__ == '__main__':
    if sys.argv[1:] == ['toolchain']:
        with open(os.environ['GITHUB_ENV'], 'a') as out:
            out.write('NATIVE_TOOLCHAIN=' + prepared.toolchain() + '\n')
        raise SystemExit(0)
    if len(sys.argv) != 3 or sys.argv[1] not in ('select', 'package', 'restore') or sys.argv[2] not in PATHS:
        raise SystemExit('Usage: compiled-components.py select|package|restore native|wine|windows|graphics|jit')
    action, component = sys.argv[1:]
    os.environ['NATIVE_TOOLCHAIN'] = hashlib.sha256(
        (os.environ['NATIVE_TOOLCHAIN'] + str(ROOT.resolve())).encode()).hexdigest()
    if action == 'select':
        run = reuse.select(ROOT, component, os.environ['GITHUB_REF_NAME']) if os.environ.get('REUSE_ASSETS', 'true') == 'true' else ''
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(f'run_id={run}\nartifact={reuse.artifact_name(component)}\n')
    elif action == 'package':
        package(ROOT, component)
    else:
        restore(ROOT, component, os.environ['COMPONENT_RUN_ID'])
