#!/usr/bin/env python3
"""Transfer completed native dependencies and source, never compiler build trees."""
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

reuse = load('reuse', 'reuse-build-assets.py')
inputs = load('inputs', 'fetch-runtime-inputs.py')
prerequisites = load('prerequisites', 'check-ipa-prerequisites.py')
M = 'testrepos/Madeira/'
APP = M + 'app/Madeira/'
IOS = 'iridium/apps/ios/'
# Only final link inputs, generated headers, resources, and their notices.
TREES = (
    'iridium-runtime-sdk/build/iridium-runtime-base',
    APP + 'aarch64-windows', APP + 'arm64ec-windows', APP + 'nls', APP + 'fonts',
    IOS + 'MediaRuntime', IOS + 'ControllerRuntime',
    IOS + 'BuiltinJIT/Vendor/StikJIT.xcframework',
    'Amethyst-iOS/Natives/resources/Frameworks/libEGL.framework',
    'Amethyst-iOS/Natives/resources/Frameworks/libGLESv2.framework',
)
ARCHIVES = (
    M + 'FEX/build-ios', 'iridium-fex-ios/build-iridium-ios-iphoneos',
    'iridium-wine-ios/build-iridium-ios/wine-build-iphoneos/artifacts', IOS + '.build/media',
)
FILES = tuple(APP + 'lib' + name + '.a' for name in (
    'wineserver', 'ntdll_unix', 'win32u_unix', 'dxmt_combined', 'gnutls', 'hogweed', 'nettle', 'gmp'
)) + (APP + 'prefix-template.tar.gz', APP + 'legal/ANGLE-LICENSE.txt')
HEADERS = tuple(M + 'FEX/External/' + name + '/include' for name in ('fmt', 'range-v3', 'unordered_dense'))
SOURCE = '.build/corresponding-source'
LINK_ARCHIVES = tuple('lib' + name + '.a' for name in re.findall(
    r'^\s+- -l([\w-]+)\s*$', (ROOT / IOS / 'project.yml').read_text(), re.M))


def allowed(name):
    path = Path(name)
    if (path.is_absolute() or '..' in path.parts or '.git' in path.parts or str(path) != name
            or path.suffix.lower() in {'.p12', '.pfx', '.key', '.mobileprovision'}):
        return False
    if name in FILES:
        return True
    if any(path.is_relative_to(tree) for tree in TREES + HEADERS):
        return True
    if any(path.is_relative_to(tree) for tree in ARCHIVES):
        return path.suffix in {'.a', '.h', '.hpp', '.inc'}
    return (path.parent == Path(SOURCE) and path.name != 'cerbero-1.28.6.tar.xz'
            and path.name not in {'iridium.tar.gz', 'repository-revisions.json', 'iridium.tar.patch'})


def toolchain():
    # Do not reuse a framework compiled with a different Swift compiler/SDK.
    commands = [
        ['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'],
        ['xcrun', '--sdk', 'iphoneos', 'metal', '--version'],
        ['xcrun', 'swiftc', '--version'], ['sw_vers', '-buildVersion'], ['uname', '-m'],
        ['brew', 'list', '--versions'],
    ]
    record = [' '.join(command) + '\n' + subprocess.check_output(command, text=True).strip()
              for command in commands]
    # Brew's inventory order is not an input, but every installed version is.
    record[-1] = '\n'.join(sorted(record[-1].splitlines()))
    record.append(inputs.digest(ROOT / '.build/media-transfer/media-sdk.tar.gz'))
    record.append(inputs.digest(ROOT / '.build/linux-transfer/wine-userland.tar.zst'))
    return fingerprint(record)


# Run 34650568812 retained native and Wine before failing in Windows compilation.
# Reconstruct its old hash with ONLY the random Metal mount replaced. Reuse is
# allowed only if every other tool version and input digest matches that hash.
LEGACY_METAL_MOUNTS = {
    'e0cc2593b08c5647be9351b79a2fca0d75b5a728f502fa251c5fb1420b412291':
        '/private/var/run/com.apple.security.cryptexd/mnt/'
        'com.apple.MobileAsset.MetalToolchain-v27.1.5252.6.uJXdU9/'
        'Metal.xctoolchain/usr/metal/current/bin',
}


def fingerprint(record):
    def digest(parts):
        return hashlib.sha256('\n'.join(parts).encode()).hexdigest()
    for expected, mount in LEGACY_METAL_MOUNTS.items():
        legacy = list(record)
        legacy[2] = '\n'.join('InstalledDir: ' + mount if line.startswith('InstalledDir:') else line
                              for line in legacy[2].splitlines())
        if digest(legacy) == expected:
            return expected
    stable = list(record)
    stable[2] = '\n'.join(line for line in stable[2].splitlines()
                          if not line.startswith('InstalledDir:'))
    return digest(stable)


def select():
    key = toolchain()
    os.environ['NATIVE_TOOLCHAIN'] = key
    run = ''
    if os.environ.get('REUSE_ASSETS', 'true') == 'true':
        run = reuse.select(ROOT, 'native-runtime', os.environ['GITHUB_REF_NAME'])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'run_id={run}\nartifact={reuse.artifact_name("native-runtime")}\n')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'NATIVE_TOOLCHAIN={key}\nNATIVE_RUN_ID={run}\n')
    print('Native dependencies: ' + ('reuse run ' + run if run else 'build fresh'))


def check_source(root):
    source = root / SOURCE
    required = ('native-producer-iridium.tar.gz', 'native-producer-revisions.json',
                'angle-revisions.json', 'StikJIT.tar.gz', 'idevice.tar.gz',
                'idevice-dependencies.json', 'idevice-ios-dependencies.txt',
                'rust-standard-library.tar.gz', 'rust-license-texts.tar.gz',
                'rust-standard-library-COPYRIGHT.html', 'rust-toolchain.txt')
    for name in required:
        if not (source / name).is_file() or not (source / name).stat().st_size:
            raise ValueError('Missing prepared dependency source: ' + name)


def check_outputs(root):
    linked = {path.name for tree in ARCHIVES[1:3] for path in (root / tree).rglob('*.a')}
    for name in LINK_ARCHIVES:
        if name not in linked:
            raise ValueError('Missing app link archive: ' + name)
    for group, paths in prerequisites.REQUIRED.items():
        for name in paths:
            if not (root / name).is_file() or not (root / name).stat().st_size:
                raise ValueError('Missing prepared dependency: ' + name)


def package(root):
    check_outputs(root)
    transfer = root / '.build/native-transfer'
    transfer.mkdir(parents=True, exist_ok=False)
    source = root / SOURCE
    # Keep the producer checkout even when the final IPA uses newer app source.
    for old, new in [('iridium.tar.gz', 'native-producer-iridium.tar.gz'),
                     ('repository-revisions.json', 'native-producer-revisions.json'),
                     ('iridium.tar.patch', 'native-producer-iridium.patch')]:
        if (source / old).exists():
            shutil.copyfile(source / old, source / new)
    check_source(root)
    names = set(FILES)
    for tree in TREES + ARCHIVES + HEADERS + (SOURCE,):
        if not (root / tree).is_dir():
            raise ValueError('Missing transfer directory: ' + tree)
        names.update(str(p.relative_to(root)) for p in (root / tree).rglob('*')
                     if p.is_file() and allowed(str(p.relative_to(root))))
    archive = transfer / 'native-runtime.tar.gz'
    # Dereference only after proving every selected file stays in this checkout.
    with tarfile.open(archive, 'w:gz', dereference=True) as tar:
        for name in sorted(names):
            path = root / name
            if not allowed(name) or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('Unsafe prepared dependency: ' + name)
            tar.add(path, arcname='runtime/' + name, recursive=False)
    record = {'revision': reuse.git(root, 'rev-parse', 'HEAD'),
              'toolchain': os.environ['NATIVE_TOOLCHAIN'], 'sha256': inputs.digest(archive)}
    (transfer / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')


def restore(root, run_id):
    revision = reuse.verify_producer(root, run_id, 'native-runtime', os.environ['GITHUB_REF_NAME'])
    transfer = root / '.build/native-transfer'
    archive = transfer / 'native-runtime.tar.gz'
    manifest = transfer / 'manifest.json'
    if archive.is_symlink() or manifest.is_symlink():
        raise ValueError('Transfer files must not be symlinks')
    record = json.loads(manifest.read_text())
    if (record.get('revision') != revision or record.get('toolchain') != os.environ['NATIVE_TOOLCHAIN']
            or record.get('sha256') != inputs.digest(archive)):
        raise ValueError('Prepared runtime provenance, toolchain, or checksum mismatch')
    # Validate the full archive before touching the checkout. No links or devices.
    with tarfile.open(archive) as tar:
        seen = set()
        for member in tar:
            name = member.name.removeprefix('runtime/')
            if (not member.name.startswith('runtime/') or not member.isfile() or not allowed(name)
                    or name in seen):
                raise ValueError('Unexpected prepared archive member: ' + member.name)
            seen.add(name)
    resource = root / 'iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime'
    if resource.exists() or resource.is_symlink():
        raise ValueError('Refusing to replace bundled runtime resource')
    with tempfile.TemporaryDirectory(dir=root / '.build') as temp:
        staged = Path(temp) / 'runtime'
        inputs.unpack(archive, staged, 'runtime')
        check_outputs(staged)
        check_source(staged)
        for name in seen:
            target = root / name
            if not target.resolve().is_relative_to(root.resolve()):
                raise ValueError('Restore destination escapes checkout')
            # Tracked resource notices can already exist. Only identical files
            # are accepted, except the explicitly generated ANGLE license.
            if target.exists() and (target.is_symlink() or not target.is_file()
                    or (inputs.digest(target) != inputs.digest(staged / name)
                        and name != APP + 'legal/ANGLE-LICENSE.txt')):
                raise ValueError('Refusing to overwrite changed file: ' + name)
        for name in seen:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(staged / name, target)
            shutil.copymode(staged / name, target)
    shutil.copytree(root / 'iridium-runtime-sdk/build/iridium-runtime-base', resource)
    print('Restored verified native libraries, Windows modules, graphics, JIT, and corresponding source')


if __name__ == '__main__':
    if sys.argv[1:] == ['select']:
        select()
    elif sys.argv[1:] == ['package']:
        package(ROOT)
    elif sys.argv[1:] == ['restore']:
        restore(ROOT, os.environ['NATIVE_RUN_ID'])
    else:
        raise SystemExit('Usage: prepared-runtime.py select|package|restore')
