#!/usr/bin/env python3
"""Stage and validate the native Madeira package without Linux runtime resources."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
# Keep both Windows architectures: 64-bit titles can use 32-bit installers.
APP_FILES = (
    'arm64ec-windows/ntdll.dll', 'aarch64-windows/ntdll.dll',
    'aarch64-windows/xtajit.dll', 'i386-windows/ntdll.dll', 'i386-windows/d3d9.dll',
    'arm64ec-windows/d3d12.dll', 'd3d12/libmetalirconverter.dylib',
    'd3d12/METAL-SHADER-CONVERTER-AGREEMENT.txt',
    'd3d12/LICENSE-metal-shader-converter-headers.txt', 'd3d12/NOTICE.txt',
    'prefix-template.tar.gz', 'nls/l_intl.nls', 'fonts/tahoma.ttf',
    'MediaRuntime/mfreadwrite.dll', 'MediaRuntime/winegstreamer.dll',
    'ControllerRuntime/arm64ec/xinput.dll',
    'ControllerRuntime/aarch64/iridium-prerequisites.exe',
)
FRAMEWORKS = ('libEGL', 'libGLESv2')
LEGACY_PATHS = ('IridiumWineUserland', 'BundledRuntime',
                'Iridium_IridiumRuntime.bundle/BundledRuntime')


def require_files(root, names):
    for name in names:
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Runtime file escapes its root: ' + name)
        if not path.is_file() or not path.stat().st_size:
            raise ValueError('Missing Madeira runtime file: ' + name)


def check_app(app):
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('IridiumRuntimeProfile') != 'madeira':
        raise ValueError('Expected the Madeira runtime package profile')
    for name in LEGACY_PATHS:
        path = app / name
        if path.exists() or path.is_symlink():
            raise ValueError('Madeira package contains legacy runtime resources: ' + name)
    if any(app.rglob('wine-userland.tar.zst')):
        raise ValueError('Madeira package contains a Linux userland archive')
    require_files(app, APP_FILES + tuple('Frameworks/' + name + '.framework/' + name
                                       for name in FRAMEWORKS + ('MadeiraNative',)))


def remove_path(root, name):
    path = root / name
    # Refuse parent symlink traversal; unlink a final symlink without following it.
    if not path.parent.resolve().is_relative_to(root.resolve()):
        raise ValueError('Refusing to prune a runtime path outside its root: ' + name)
    if path.is_symlink():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def prepare(root):
    # SwiftPM requires a resource directory at manifest evaluation time. A small
    # profile marker supplies it without copying the canonical legacy bundle.
    resources = root / 'iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime'
    if not resources.resolve().is_relative_to(root.resolve()):
        raise ValueError('SwiftPM runtime resource path escapes checkout')
    resources.mkdir(parents=True, exist_ok=True)
    remove_path(resources, 'iridium-runtime-base')
    (resources / 'madeira-profile.json').write_text('{"runtimeProfile":"madeira"}\n')
    print('Prepared Madeira SwiftPM resource marker; no Linux payload copied.')


def finalize(app):
    app = Path(app)
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Expected a real built app directory')
    for name in LEGACY_PATHS:
        remove_path(app, name)
    check_app(app)
    print('Finalized Madeira runtime inventory; Linux resources are absent.')


def stage(check_only=False):
    srcroot = Path(os.environ['SRCROOT'])
    app_sources = srcroot / '../../../testrepos/Madeira/app/Madeira'
    for name in APP_FILES:
        source = srcroot if name.startswith(('MediaRuntime/', 'ControllerRuntime/')) else app_sources
        require_files(source, (name,))
    amethyst = Path(os.environ.get('IRIDIUM_AMETHYST_ROOT', str(srcroot / '../../../Amethyst-iOS')))
    source_frameworks = amethyst / 'Natives/resources/Frameworks'
    require_files(source_frameworks, tuple(name + '.framework/' + name for name in FRAMEWORKS))
    if check_only:
        print('Validated Madeira package sources without Linux runtime inputs.')
        return
    products = Path(os.environ['TARGET_BUILD_DIR'])
    app = products / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
    if app.name != 'Iridium.app' or not app.resolve().is_relative_to(products.resolve()):
        raise ValueError('Unexpected Madeira app staging path')
    framework_root = app / 'Frameworks'
    if not framework_root.resolve().is_relative_to(app.resolve()):
        raise ValueError('Framework staging path escapes app')
    framework_root.mkdir(parents=True, exist_ok=True)
    for name in FRAMEWORKS:
        destination = framework_root / (name + '.framework')
        remove_path(framework_root, destination.name)
        shutil.copytree(source_frameworks / destination.name, destination, symlinks=True)
        if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES' and os.environ.get('EXPANDED_CODE_SIGN_IDENTITY'):
            subprocess.run(['codesign', '--force', '--sign', os.environ['EXPANDED_CODE_SIGN_IDENTITY'],
                            '--timestamp=none', str(destination)], check=True)
    # Clean incremental transitions from an older profile before validating.
    for name in LEGACY_PATHS:
        remove_path(app, name)
    check_app(app)
    print('Staged Madeira shared graphics frameworks; Linux runtime omitted.')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['prepare']:
            prepare(ROOT)
        elif sys.argv[1:] in (['stage'], ['stage', '--check']):
            stage(check_only='--check' in sys.argv)
        elif len(sys.argv) == 3 and sys.argv[1] in {'finalize', 'check-app'}:
            (finalize if sys.argv[1] == 'finalize' else check_app)(Path(sys.argv[2]))
        else:
            raise ValueError('Usage: madeira-package.py prepare|stage [--check]|finalize APP|check-app APP')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('Madeira packaging: ' + str(error))
