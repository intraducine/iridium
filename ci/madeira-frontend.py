#!/usr/bin/env python3
"""Build the Iridium-owned app against pinned native engine components."""
import engine_pins
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import shlex
import hashlib
import importlib.util
import inspect
import json
import os
import time
import sys
import tempfile
import madeira_audio_volume
import madeira_threads

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/Madeira'
FRONTEND = ROOT / 'iridium/apps/ios/MadeiraFrontend'
RUNTIME_SUPPORT = ROOT / 'iridium/apps/ios/RuntimeSupport'
RUNTIME_BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
OUTPUT = ROOT / '.build/madeira-frontend'
REVISION = engine_pins.get('madeira')['revision']
PSP_REVISION = engine_pins.get('ppsspp')['revision']
FREETYPE_REVISION = engine_pins.get('madeira')['buildDependencies']['freetype']['revision']
PSP_OUTPUT = ROOT / '.build/ppsspp/iphoneos'
RUNTIME_HEADERS = '\n#import "IridiumCoreBridge.h"\n#import "IRPSPNativeBridge.h"\n'
CRYPTO_LIBRARIES = ('gnutls', 'hogweed', 'nettle', 'gmp')
PSP_PRIVACY_DESCRIPTIONS = {
    'NSCameraUsageDescription': 'PSP and 3DS games can request camera input while you play.',
    'NSMicrophoneUsageDescription': 'PSP and 3DS games can request microphone input while you play.',
    'NSMotionUsageDescription': 'Wii, 3DS, and PSP controls use device motion while you play.',
    'NSLocationWhenInUseUsageDescription': 'A PSP game can use your location to emulate the Go!Explore GPS accessory while playing.',
    'NSPhotoLibraryUsageDescription': 'Choose a photo for the PPSSPP background when you request it.',
    'NSLocalNetworkUsageDescription': 'Iridium uses the local network for PSP and Dreamcast multiplayer and on-device JIT pairing.',
}
def overlay(name, text):
    """Legacy test entry point: read maintained shipping source, never rewrite upstream UI."""
    import iridium_app_sources as app_sources
    owned = app_sources.logical_source(name)
    return text if owned is None else owned


def verify_pin():
    if not (ROOT / '.git').exists():
        revisions = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())
        if revisions.get('vendor/Madeira') != REVISION:
            raise ValueError('Unexpected Madeira source package revision')
        expected = json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']['dependencies']
        for name, revision in expected.items():
            if revisions.get('vendor/Madeira/' + name) != revision or not (UPSTREAM / name).is_dir():
                raise ValueError('Incomplete source package: ' + name)
        return  # Supplied source can be modified for LGPL replacement.
    actual = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION:
        raise ValueError(f'Expected Madeira {REVISION}; found {actual}. Review the overlay before updating.')
    repos = [UPSTREAM]
    for line in subprocess.check_output(['git', '-C', str(UPSTREAM), 'submodule', 'status', '--recursive'], text=True).splitlines():
        if line.startswith('-'): continue  # Large test-only submodules stay uninitialized.
        if not line.startswith(' '): raise ValueError('Unexpected dependency revision: ' + line.split()[1])
        repos.append(UPSTREAM / line.split()[1])
    for repo in repos:
        changes = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
        if repo == UPSTREAM / 'FEX':
            for managed, adapt in [('FEXCore/Source/Utils/AllocWatch.cpp', madeira_threads.apply_fex),
                                   ('Source/Windows/ARM64EC/Module.cpp', madeira_threads.apply_fex_arm64ec)]:
                if managed not in changes: continue
                original = subprocess.check_output(['git', '-C', str(repo), 'show', 'HEAD:' + managed], text=True)
                if (repo / managed).read_text() == adapt(original): changes.remove(managed)
        if any(Path(name).suffix in {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.cc', '.js', '.pbxproj', '.y', '.l',
                                     '.sh', '.rs', '.metal', '.S', '.inc', '.in', '.cmake'}
               or Path(name).name == 'CMakeLists.txt' for name in changes):
            raise ValueError(f'Pinned source has changes: {repo}. Preserve them before preparing the overlay.')
        if repo.parent == UPSTREAM:
            expected = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD:' + repo.name], text=True).strip()
            actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            if expected != actual: raise ValueError(f'Unexpected dependency revision: {repo.name}')


def project(source, names):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(source)]))
    objects = data['objects']
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Madeira')
    target['name'] = target['productName'] = 'Iridium'
    objects[target['productReference']]['path'] = 'Iridium.app'
    group = next(v for v in objects.values() if v.get('isa') == 'PBXGroup' and v.get('path') == 'Madeira')
    sources = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
    for index, name in enumerate(names):
        reference, build = f'F000000000000000{index:08X}', f'F100000000000000{index:08X}'
        kind = 'sourcecode.c.c' if name.endswith('.c') else 'sourcecode.swift'
        objects[reference] = dict(isa='PBXFileReference', lastKnownFileType=kind, path=name, sourceTree='<group>')
        objects[build] = dict(isa='PBXBuildFile', fileRef=reference)
        group['children'].append(reference); sources['files'].append(build)
    # This separately embedded component exports only its C interface. Never
    # flatten emulator C++ archives into Madeira's native executable.
    component_ref, component_build, embed = 'F20000000000000000000001', 'F20000000000000000000002', 'F20000000000000000000003'
    objects[component_ref] = dict(isa='PBXFileReference', lastKnownFileType='compiled.mach-o.dylib',
        path='../../ppsspp/$(PLATFORM_NAME)/libIridiumPPSSPPNative.dylib', sourceTree='SOURCE_ROOT')
    objects[component_build] = dict(isa='PBXBuildFile', fileRef=component_ref,
                                   settings={'ATTRIBUTES': ['CodeSignOnCopy']})
    objects[embed] = dict(isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='',
        dstSubfolderSpec=10, files=[component_build], name='Embed PSP component', runOnlyForDeploymentPostprocessing=0)
    target['buildPhases'].append(embed); group['children'].append(component_ref)
    asset_ref, asset_build = 'F20000000000000000000004', 'F20000000000000000000005'
    objects[asset_ref] = dict(isa='PBXFileReference', lastKnownFileType='folder', path='PSP', sourceTree='<group>')
    objects[asset_build] = dict(isa='PBXBuildFile', fileRef=asset_ref)
    resources = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXResourcesBuildPhase')
    resources['files'].append(asset_build); group['children'].append(asset_ref)
    if (os.environ.get('IRIDIUM_PHASE3') == '1'):
        phase3 = [('host', 'libIridiumRetroPlayer.dylib'), ('dolphin', 'libIridiumDolphin.dylib'),
                  ('azahar', 'azahar_libretro.dylib'), ('play', 'play_libretro_ios.dylib'), ('flycast', 'flycast_libretro.dylib')]
        embedded = objects[embed]
        for index, (engine, binary) in enumerate(phase3):
            ref, build = f'F300000000000000{index:08X}', f'F400000000000000{index:08X}'
            objects[ref] = dict(isa='PBXFileReference', lastKnownFileType='compiled.mach-o.dylib',
                path=f'../../phase3/{engine}/$(PLATFORM_NAME)/{binary}', sourceTree='SOURCE_ROOT')
            objects[build] = dict(isa='PBXBuildFile', fileRef=ref,
                                  settings={'ATTRIBUTES': ['CodeSignOnCopy']})
            embedded['files'].append(build); group['children'].append(ref)
        ref, build = 'F30000000000000000000010', 'F40000000000000000000010'
        objects[ref] = dict(isa='PBXFileReference', lastKnownFileType='folder', path='Phase3', sourceTree='<group>')
        objects[build] = dict(isa='PBXBuildFile', fileRef=ref)
        resources['files'].append(build); group['children'].append(ref)
        for index, path in enumerate(('Phase3/dolphin/Sys', 'GameConfig.xml')):
            ref, build = f'F300000000000001{index:08X}', f'F400000000000001{index:08X}'
            objects[ref] = dict(isa='PBXFileReference', lastKnownFileType='folder' if index == 0 else 'text.xml', path=path, sourceTree='<group>')
            objects[build] = dict(isa='PBXBuildFile', fileRef=ref)
            resources['files'].append(build); group['children'].append(ref)
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[config]['buildSettings']
        settings['PRODUCT_NAME'] = 'Iridium'
        settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
        def append(key, additions, unique=True):
            existing = settings.get(key, ['$(inherited)'])
            if isinstance(existing, str): existing = shlex.split(existing)
            settings[key] = existing + [item for item in additions if not unique or item not in existing]
        append('HEADER_SEARCH_PATHS', ['$(SRCROOT)/../../sameboy/$(PLATFORM_NAME)',
                                      '$(SRCROOT)/../../../vendor/SameBoy/libretro',
                                      '$(SRCROOT)/../../ppsspp/$(PLATFORM_NAME)/include'])
        append('LIBRARY_SEARCH_PATHS', ['$(SRCROOT)/../../sameboy/$(PLATFORM_NAME)'])
        append('OTHER_LDFLAGS', ['-lIridiumSameBoy', '-framework', 'CoreFoundation'], unique=False)
        append('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['IRIDIUM_PPSSPP'])
        if (os.environ.get('IRIDIUM_PHASE3') == '1'): append('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['IRIDIUM_PHASE3'])
    for value in objects.values():
        if value.get('isa') == 'XCBuildConfiguration':
            value['buildSettings']['MARKETING_VERSION'] = '0.2.1'
            value['buildSettings']['CURRENT_PROJECT_VERSION'] = '1'
            value['buildSettings']['DEVELOPMENT_TEAM'] = ''
            value['buildSettings']['MADEIRA_BUNDLE_IDENTIFIER'] = 'software.iridium'
    return data


def refresh_generated_tree(source, destination):
    """Replace only a known generated tree; never follow a stale output link."""
    if destination.is_symlink() or any(p.is_symlink() for p in destination.parents):
        raise ValueError('Generated component directory contains a symbolic link')
    if destination.exists():
        if not destination.is_dir():
            raise ValueError('Generated component directory is not a directory')
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def prepare():
    import iridium_app_sources as app_sources
    import ppsspp_gl_sync_overlay as psp_gl_sync
    verify_pin()
    subprocess.run([sys.executable, str(ROOT / 'ci/check-engine-upgrade.py'),
                    '--madeira-source', str(UPSTREAM)], check=True)
    check_sameboy_component()
    app = OUTPUT / 'app'
    # Only generated presentation files are replaced. Native build outputs are
    # retained at their upstream locations, with the same project link paths.
    # Recreate generated staging so removed or renamed upstream resources cannot
    # survive a pin change. Never replace runtime sources or delivered packages.
    app.parent.mkdir(parents=True, exist_ok=True)
    refresh_generated_tree(UPSTREAM / 'app', app)
    for name in ('FEX', 'wine', 'dxmt', 'madeira-dock', 'madeira-d3d12', 'build', 'LICENSES', 'toolchains'):
        link = OUTPUT / name
        if not link.is_symlink() and link.exists():
            raise ValueError('Refusing to replace an existing build directory: ' + str(link))
        target = (UPSTREAM / name).resolve()
        if link.is_symlink() and link.resolve() != target: link.unlink()
        if not link.is_symlink(): link.symlink_to(target, target_is_directory=True)
    for name in ('COPYING', 'LICENSE', 'LICENSE-EXCEPTION.md', 'THIRD-PARTY-NOTICES.md'):
        shutil.copy2(UPSTREAM / name, OUTPUT / name)
    for source, name in [('COPYING', 'LICENSE-MADEIRA-GPL-3.0.txt'), ('LICENSE-EXCEPTION.md', 'LICENSE-MADEIRA-EXCEPTION.txt')]:
        shutil.copy2(UPSTREAM / source, app / 'Madeira/licenses' / name)
    shutil.copy2(ROOT / 'LICENSE', app / 'Madeira/licenses/LICENSE-IRIDIUM.txt')
    # Native Wine substitutes remain bundled. Optional Microsoft redistributables
    # must be supplied by the user, rather than copied from a maintainer's games.
    (app / 'Madeira/x86_64-vcruntime').mkdir(exist_ok=True)
    names = app_sources.stage(app)
    sources = sorted(p for p in RUNTIME_BRIDGE.glob('*.c')
        if p.name not in ('IRPSPBridge.c', 'IRPPSSPPCodecCheck.c', 'IRJITExecutionProbe.c'))
    for source in sources:
        shutil.copy2(source, app / 'Madeira' / source.name)
        names.append(source.name)
    for name in ('IridiumCoreBridge.h', 'IRCoreOptions.h', 'IRCheats.h', 'IRWindowsThreads.h', 'IRPSPNativeBridge.h', 'IRJITDiagnostic.h', 'IRPSPExecutableMemory.h', 'IRPSPTeardownObservation.h', 'IRPhase3.h', 'IRDolphinAPI.h', 'IRAudioVolume.h', 'IRJITMemory.h'):
        shutil.copy2(RUNTIME_BRIDGE / name, app / 'Madeira' / name)
    header = app / 'Madeira/Madeira-Bridging-Header.h'
    header.write_text(header.read_text() + RUNTIME_HEADERS + '\n#import "IRJITMemory.h"\n#import "IRPhase3.h"\n#import "IRDolphinAPI.h"\n#import "IRAudioVolume.h"\n#import "IRWindowsThreads.h"\n')
    import madeira_session
    madeira_session.build(app / 'Madeira/arm64ec-windows')
    psp = json.loads((PSP_OUTPUT / 'component.json').read_text())
    component = PSP_OUTPUT / 'libIridiumPPSSPPNative.dylib'
    if psp.get('enginePin') != engine_pins.selected('psp') or psp.get('componentType') != 'native-ios-player' or psp.get('revision') != PSP_REVISION or hashlib.sha256(component.read_bytes()).hexdigest() != psp.get('sha256'):
        raise ValueError('Build and audit the pinned PSP component before preparing the app')
    check_psp_jit_interface(psp)
    psp_gl_sync.validate_component(psp, ROOT / 'vendor/PPSSPP')
    refresh_generated_tree(PSP_OUTPUT / 'assets', app / 'Madeira/PSP/PPSSPP')
    refresh_generated_tree(PSP_OUTPUT / 'licenses', app / 'Madeira/licenses/PPSSPP')
    if (os.environ.get('IRIDIUM_PHASE3') == '1'):
        from phase3_app import stage_phase3
        stage_phase3(app / 'Madeira', refresh_generated_tree)
    shutil.copy2(ROOT / 'vendor/SameBoy/LICENSE', app / 'Madeira/licenses/LICENSE-SAMEBOY.txt')
    api = (ROOT / 'vendor/SameBoy/libretro/libretro.h').read_text()
    notice = api.split('*/', 1)[0]
    if (not api.startswith('/*') or '*/' not in api or 'Copyright' not in notice
            or 'Permission is hereby granted' not in notice or 'THE SOFTWARE IS PROVIDED' not in notice):
        raise ValueError('Missing Libretro API license notice')
    (app / 'Madeira/licenses/LICENSE-SAMEBOY-SUPPORT.txt').write_text(api[:api.index('*/') + 2] + '\n')
    generated = app / 'Madeira.xcodeproj/project.pbxproj'
    generated.write_bytes(plistlib.dumps(project(ROOT / app_sources.PROJECT, names)))
    info = app / 'Madeira/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['CFBundleDisplayName'] = 'Iridium'
    data['LSApplicationQueriesSchemes'] = list(dict.fromkeys(data.get('LSApplicationQueriesSchemes', []) + ['livecontainer', 'livecontainer2', 'livecontainer3']))
    data['IridiumFrontendSource'] = 'app-owned'
    data['IridiumMadeiraRevision'] = REVISION
    data['IridiumPPSSPPRevision'] = PSP_REVISION
    if (os.environ.get('IRIDIUM_PHASE3') == '1'):
        spec = importlib.util.spec_from_file_location('phase3_identity', ROOT / 'ci/build-phase3.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        data['IridiumPhase3Revisions'] = {engine: pin[1] for engine, pin in builder.PINS.items()}
    from build_source_identity import source_identity
    data.update(source_identity(ROOT, PSP_REVISION))
    if (os.environ.get('IRIDIUM_PHASE3') == '1'):
        data['IridiumRuntimeRevisions'].update({name: builder.PINS[engine][1]
            for engine, name in [('dolphin', 'Dolphin'), ('azahar', 'Azahar'), ('play', 'Play!'), ('flycast', 'Flycast')]})
    data.update(PSP_PRIVACY_DESCRIPTIONS)
    info.write_bytes(plistlib.dumps(data))
    verify()
    print(generated.parent)


def check_sameboy_component():
    spec = importlib.util.spec_from_file_location('sameboy_builder', ROOT / 'ci/build-sameboy.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    builder.verify_component(ROOT / '.build/sameboy/iphoneos')


def verify():
    import iridium_app_sources as app_sources
    check_sameboy_component()
    verify_pin()
    app_sources.verify(OUTPUT / 'app')
    for path in (UPSTREAM / 'app/Madeira').rglob('*'):
        if not path.is_file() or path.suffix not in {'.h', '.c', '.m', '.mm', '.cpp'}: continue
        if path.name == 'WiniosGamepad.c': continue  # Maintained input adapter.
        generated = OUTPUT / 'app/Madeira' / path.relative_to(UPSTREAM / 'app/Madeira')
        expected = path.read_bytes()
        if path.name == 'Madeira-Bridging-Header.h': expected += (RUNTIME_HEADERS + '\n#import "IRJITMemory.h"\n#import "IRPhase3.h"\n#import "IRDolphinAPI.h"\n#import "IRAudioVolume.h"\n#import "IRWindowsThreads.h"\n').encode()
        if not generated.is_file() or generated.read_bytes() != expected:
            raise ValueError('Staged native input differs from its pinned source: ' + str(path))
    print('Iridium-owned app sources verified; pinned native inputs match their source.')


def check_psp_jit_interface(record):
    if ('_ir_native_psp_check_jit' not in record.get('exports', [])
        or '_ir_native_psp_check_jit_diagnostic' not in record.get('exports', [])
        or not {'_ir_native_psp_exec_version', '_ir_native_psp_exec_prepare_shared', '_ir_native_psp_exec_prepare', '_ir_native_psp_exec_prepare_diagnostic', '_ir_native_psp_exec_detach',
                '_ir_native_psp_exec_accept_shutdown', '_ir_native_psp_exec_restored', '_ir_native_psp_exec_restored_diagnostic', '_ir_native_psp_exec_advance',
                '_ir_native_psp_exec_cancel', '_ir_native_psp_exec_end'}.issubset(record.get('exports', []))
        or record.get('diagnosticHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITDiagnostic.h').read_bytes()).hexdigest()
        or record.get('sharedMemoryHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITMemory.h').read_bytes()).hexdigest()
        or record.get('executableMemoryHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPSPExecutableMemory.h').read_bytes()).hexdigest()
        or '_ir_native_psp_set_volume' not in record.get('exports', [])
        or record.get('audioVolumeHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRAudioVolume.h').read_bytes()).hexdigest()
        or record.get('optionsHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPPSSPPOptions.h').read_bytes()).hexdigest()
        or record.get('cheatsHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRCheats.h').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRAudioVolume.c') != hashlib.sha256((RUNTIME_BRIDGE / 'IRAudioVolume.c').read_bytes()).hexdigest()
        or record.get('adapterSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPPSSPPNative.mm').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRPSPExecutableMemory.cpp') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPSPExecutableMemory.cpp').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRJITExecutionProbe.c') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITExecutionProbe.c').read_bytes()).hexdigest()):
        raise ValueError('Rebuild the PSP component with the matching JIT validation interface')


def check_bundle(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('IridiumPhase3Revisions') is not None:
        from phase3_app import check_phase3_bundle
        check_phase3_bundle(app, info['IridiumPhase3Revisions'])
    elif (os.environ.get('IRIDIUM_PHASE3') == '1'):
        raise ValueError('Console engine capability metadata is missing')
    if any(info.get(name) != value for name, value in PSP_PRIVACY_DESCRIPTIONS.items()):
        raise ValueError('The native PSP platform permission descriptions are missing or changed')
    if info.get('IridiumMadeiraRevision') != REVISION:
        raise ValueError('Unexpected Madeira source pin in the app')
    if info.get('IridiumPPSSPPRevision') != PSP_REVISION:
        raise ValueError('Unexpected PSP source pin in the app')
    component = app / 'Frameworks/libIridiumPPSSPPNative.dylib'
    psp = json.loads((PSP_OUTPUT / 'component.json').read_text())
    check_psp_jit_interface(psp)
    if not component.is_file() or component.is_symlink() or hashlib.sha256(component.read_bytes()).hexdigest() != psp['sha256']:
        raise ValueError('The app does not contain the audited PSP component')
    for name, expected in psp['assetSHA256'].items():
        resource = app / 'PSP/PPSSPP' / name
        if resource.is_symlink() or not resource.is_file() or hashlib.sha256(resource.read_bytes()).hexdigest() != expected:
            raise ValueError('A PSP runtime asset is missing or changed: ' + name)
    for name in ('arm64ec-windows', 'aarch64-windows', 'i386-windows'):
        source = UPSTREAM / 'app/Madeira' / name
        expected = {path.name for path in source.glob('*') if path.is_file() and not path.name.startswith('.')}
        actual = {path.name for path in (app / name).glob('*') if path.is_file() and not path.name.startswith('.')}
        if not expected or expected - actual:
            raise ValueError(f'Madeira runtime files are missing from {name}: {sorted(expected - actual)}')
    if not (app / 'arm64ec-windows/xtajit64.dll').is_file(): raise ValueError('The FEX translator is missing')
    if not (app / 'd3d12/libmetalirconverter.dylib').is_file(): raise ValueError('The D3D12 converter is missing')
    for name in ('aarch64-windows/xtajit.dll', 'aarch64-windows/wow64.dll',
                 'aarch64-windows/wow64win.dll', 'i386-windows/ntdll.dll',
                 'i386-windows/d3d9.dll', 'i386-windows/winemetal.dll'):
        if not (app / name).is_file() or not (app / name).stat().st_size:
            raise ValueError('The WoW64 runtime is missing: ' + name)

    import madeira_session
    madeira_session.verify(app / 'arm64ec-windows')


def compiler_tools():
    tools = (['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'],
             ['xcrun', '--sdk', 'iphoneos', 'metal', '--version'],
             ['xcrun', '--sdk', 'iphoneos', 'clang', '--version'], ['rustc', '-vV'],
             ['cmake', '--version'], ['meson', '--version'], ['clang', '--version'],
             ['bison', '--version'], ['flex', '--version'])
    record = {}
    for tool in tools:
        executable = shutil.which(tool[0])
        if executable is None: raise ValueError('Missing native build tool: ' + tool[0])
        version = subprocess.check_output(tool, text=True).strip()
        # Metal's mount changes after a restart; its version and target are inputs.
        if 'metal' in tool:
            version = '\n'.join(line for line in version.splitlines() if not line.startswith('InstalledDir:'))
        record[' '.join(tool)] = {'executable': str(Path(executable).resolve()), 'version': version}
        if tool[0] in ('bison', 'flex'):
            record[' '.join(tool)]['sha256'] = file_digest(Path(executable))
    return record


def compiler_identity():
    return hashlib.sha256(json.dumps(compiler_tools(), sort_keys=True).encode()).hexdigest()


def windows():
    """Build the untracked i386 farm using Madeira's original recipe."""
    verify_pin()
    recipe = UPSTREAM / 'build/wine-i386/build.sh'
    stamp = UPSTREAM / '.build/iridium-i386.json'
    key = hashlib.sha256(REVISION.encode() + inspect.getsource(windows).encode()
                         + inspect.getsource(run_checked_recipe).encode() + recipe.read_bytes()
                         + compiler_identity().encode()
                         + subprocess.check_output([str(UPSTREAM / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/i686-w64-mingw32-clang'), '--version'])).hexdigest()
    def digest(path):
        with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
    try:
        saved = json.loads(stamp.read_text())
        if saved['key'] == key and 0 <= time.time() - saved['completed'] < 14 * 86400 and saved['outputs'] and all(
            (UPSTREAM / name).is_file() and digest(UPSTREAM / name) == value for name, value in saved['outputs'].items()
        ):
            print('Reusing the completed Madeira i386 build; inputs and files match, within 14 days.')
            return
    except (OSError, ValueError, KeyError): pass
    # Xcode's macOS metal wrapper can be a stub even when the downloaded
    # toolchain is installed. Select the real tool without changing the recipe.
    metal = Path(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', 'metal'], text=True).strip())
    env = dict(os.environ, TOOLCHAINS=str(metal.parents[2]))
    run_checked_recipe('wine-i386', env=env)
    outputs = sorted(path for path in (UPSTREAM / 'app/Madeira/i386-windows').glob('*')
                     if path.is_file() and not path.name.startswith('.'))
    if not outputs: raise ValueError('Madeira built no i386 runtime files')
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(dict(key=key, completed=time.time(),
                                    outputs={str(path.relative_to(UPSTREAM)): digest(path) for path in outputs}), indent=2) + '\n')
    print('Saved the completed i386 build before app compilation and packaging.')


def toolchains():
    """Prepare locked tools and FreeType source even when outputs are restored."""
    spec = importlib.util.spec_from_file_location('fetch_inputs', ROOT / 'ci/fetch-runtime-inputs.py')
    fetcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fetcher)
    for entry in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()):
        if entry['name'] not in ('llvm', 'llvm-mingw'): continue
        entry = dict(entry, destination=entry['destination'].replace('testrepos/Madeira/', 'vendor/Madeira/', 1))
        if not (ROOT / entry['destination']).exists(): fetcher.fetch(ROOT, entry)
    prepare_freetype()


def prepare_freetype():
    """Prepare the pinned source before fingerprinting or restoring native outputs."""
    source = UPSTREAM / 'research/freetype'
    if not source.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', 'VER-2-13-3',
                        'https://github.com/freetype/freetype.git', str(source)], check=True)
    if (source / '.git').exists():
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    else:
        revision = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())['vendor/Madeira/research/freetype']
    if revision != FREETYPE_REVISION: raise ValueError('Unexpected FreeType revision')


def stage_crypto_libraries():
    archives = [UPSTREAM / 'toolchains/gnutls-ios/lib' / f'lib{name}.a' for name in CRYPTO_LIBRARIES]
    if any(not path.is_file() or not path.stat().st_size for path in archives):
        raise ValueError('The rebuilt crypto libraries are missing or empty')
    for path in archives: shutil.copy2(path, UPSTREAM / 'app/Madeira' / path.name)
    return archives


def run_checked_recipe(name, env=None):
    """Keep upstream retries, but never install outputs after failed compilation."""
    text = (UPSTREAM / 'build' / name / 'build.sh').read_text()
    if name == 'ntdll-unix':
        generated_audio = OUTPUT / 'embedding/audio_null_ios.c'
        generated_audio.parent.mkdir(parents=True, exist_ok=True)
        original_audio = UPSTREAM / 'build/ntdll-unix/audio_null_ios.c'
        generated_audio.write_text(madeira_audio_volume.apply(original_audio.read_text()))
        patches = [
            ('compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"',
             'compile_one ' + shlex.quote(str(generated_audio)) + ' "audio_null_ios"'),
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/ntdll-unix'))),
            ('echo "Results: $SUCCEEDED succeeded, $FAILED failed"',
             'echo "Results: $SUCCEEDED succeeded, $FAILED failed"\n[ "$FAILED" -eq 0 ] || exit 1')]
        for source, object_name in [('process_ios.c', 'process'), ('thread_ios.c', 'thread')]:
            generated = OUTPUT / 'embedding' / source
            original = UPSTREAM / 'build/ntdll-unix' / source
            generated.write_text(madeira_threads.apply(original.read_text(), source, RUNTIME_BRIDGE / 'IRWindowsThreads.h'))
            patches.append(('compile_one "$BUILD_DIR/' + source + '" "' + object_name + '"',
                            'compile_one ' + shlex.quote(str(generated)) + ' "' + object_name + '" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/server_ios.c'
        generated.write_text(madeira_threads.apply_process_server((UPSTREAM / 'build/ntdll-unix/server_ios.c').read_text()))
        patches.append(('compile_one "$BUILD_DIR/server_ios.c" "server"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "server" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/file_ios.c'
        generated.write_text(madeira_threads.apply_file((UPSTREAM / 'wine/dlls/ntdll/unix/file.c').read_text()))
        patches.append(('    case "$name" in\n        loader)',
                        '    case "$name" in\n        file)\n            compile_one ' + shlex.quote(str(generated)) + ' "file"\n            ;;\n        loader)'))
        generated = OUTPUT / 'embedding/loader_ios.c'
        generated.write_text(madeira_threads.apply_loader((UPSTREAM / 'build/ntdll-unix/loader_ios.c').read_text()))
        patches.append(('compile_one "$BUILD_DIR/loader_ios.c" "loader"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "loader" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/signal_arm64_ios.c'
        generated.write_text(madeira_threads.apply_signal((UPSTREAM / 'build/ntdll-unix/signal_arm64_ios.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsThreads.h'))
        patches.append(('compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "signal_arm64" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/virtual_ios.c'
        madeira_threads.verify_futex_layout((UPSTREAM / 'wine/dlls/ntdll/unix/sync.c').read_text(),
                                           (UPSTREAM / 'wine/dlls/ntdll/sync.c').read_text())
        generated.write_text(madeira_threads.apply_virtual((UPSTREAM / 'build/ntdll-unix/virtual_ios.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsJITPool.h'))
        patches.append(('compile_one "$BUILD_DIR/virtual_ios.c" "virtual"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "virtual" -I"$BUILD_DIR"'))
    elif name == 'wineserver':
        generated = OUTPUT / 'embedding/mach_ios.c'
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text(madeira_threads.apply_server((UPSTREAM / 'build/wineserver/mach_ios.c').read_text()))
        patches = [
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/wineserver'))),
            ('"mach_ios:mach_ios.c:mach.o"', '"mach_ios:' + str(generated) + ':mach.o"')]
    elif name == 'win32u-unix':
        generated = OUTPUT / 'embedding/window_ios.c'
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text(madeira_threads.apply_window((UPSTREAM / 'wine/dlls/win32u/window.c').read_text()))
        classes = OUTPUT / 'embedding/class_ios.c'
        classes.write_text(madeira_threads.apply_class((UPSTREAM / 'build/win32u-unix/class_ios.c').read_text()))
        for unit, adapt in [('dc', madeira_threads.apply_dc), ('gdiobj', madeira_threads.apply_gdi)]:
            (OUTPUT / ('embedding/' + unit + '_ios.c')).write_text(adapt((UPSTREAM / 'wine/dlls/win32u' / (unit + '.c')).read_text()))
        patches = [
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/win32u-unix'))),
            ('    case "$name" in', '    case "$name" in\n        window)\n            compile_one '
             + shlex.quote(str(generated)) + ' "window"\n            continue\n            ;;')]
        for unit in ('dc', 'gdiobj'):
            patches.append(('    case "$name" in', '    case "$name" in\n        ' + unit + ')\n            compile_one '
                            + shlex.quote(str(OUTPUT / ('embedding/' + unit + '_ios.c'))) + ' "' + unit + '"\n            continue\n            ;;'))
        patches.append(('compile_one "$BUILD_DIR/class_ios.c" "class"',
                        'compile_one ' + shlex.quote(str(classes)) + ' "class"'))
        patches.append(('ar rcs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR"/*.o',
                        'rm -f "$OBJ_DIR/libwin32u_unix.a"\nar rcs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR"/*.o'))
    elif name == 'fex-arm64ec':
        for relative, adapt in [('FEXCore/Source/Utils/AllocWatch.cpp', madeira_threads.apply_fex),
                                ('Source/Windows/ARM64EC/Module.cpp', madeira_threads.apply_fex_arm64ec)]:
            source = UPSTREAM / 'FEX' / relative
            original = source.read_text()
            patched = adapt(original)
            if original != patched: source.write_text(patched)
        patches = [('R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"',
                    'R=' + shlex.quote(str(UPSTREAM))),
                   ('if [ ! -f "$B/CMakeCache.txt" ]; then', ''),
                   ('\nfi\ncmake --build', '\ncmake --build'),
                   ('-DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF',
                    '-DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE')]
    elif name == 'wine-i386':
        patches = [
            ('R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"', 'R=' + shlex.quote(str(UPSTREAM))),
            ('make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1\nset -e',
             'make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1\nBUILD_STATUS=$?\nset -e'),
            ('    [ -f "$t" ] && continue', '    [ "$BUILD_STATUS" -eq 0 ] && [ -f "$t" ] && continue')]
    else: raise ValueError('Unsupported checked native recipe: ' + name)
    for old, new in patches:
        if text.count(old) != 1: raise ValueError('Upstream build recipe changed: ' + name)
        text = text.replace(old, new)
    subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, env=env, check=True)


def bootstrap():
    toolchains()
    llvm = UPSTREAM / 'toolchains/llvm-project/llvm'
    module = llvm / 'cmake/modules/AddLLVM.cmake'
    text = module.read_text()
    if text.count('MATCHES "Darwin"') == 2:
        module.write_text(text.replace('MATCHES "Darwin"', 'MATCHES "Darwin|iOS"'))
    elif text.count('MATCHES "Darwin|iOS"') != 2: raise ValueError('Unexpected LLVM linker configuration')
    ios = UPSTREAM / 'toolchains/llvm-ios-build'
    if not (ios / 'lib/libLLVMPasses.a').is_file():
        host = UPSTREAM / 'toolchains/llvm-host-build'
        options = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
                   '-DLLVM_TARGETS_TO_BUILD=', '-DLLVM_ENABLE_PROJECTS=']
        options += ['-DLLVM_' + name + '=OFF' for name in (
            'ENABLE_ASSERTIONS', 'INCLUDE_TESTS', 'INCLUDE_EXAMPLES', 'INCLUDE_BENCHMARKS', 'INCLUDE_DOCS',
            'ENABLE_ZLIB', 'ENABLE_ZSTD', 'ENABLE_TERMINFO', 'ENABLE_LIBXML2', 'ENABLE_CURL', 'ENABLE_FFI', 'ENABLE_EH', 'ENABLE_RTTI')]
        subprocess.run(['cmake', '-S', str(llvm), '-B', str(host), *options], check=True)
        subprocess.run(['cmake', '--build', str(host), '--target', 'llvm-tblgen', '-j6'], check=True)
        subprocess.run(['cmake', '-S', str(llvm), '-B', str(ios), *options, '-DCMAKE_SYSTEM_NAME=iOS',
                        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
                        '-DLLVM_TABLEGEN=' + str(host / 'bin/llvm-tblgen'), '-DLLVM_BUILD_UTILS=OFF',
                        '-DLLVM_INCLUDE_TOOLS=OFF', '-DLLVM_INCLUDE_UTILS=OFF'], check=True)
        subprocess.run(['cmake', '--build', str(ios), '--target', 'LLVMPasses', 'LLVMBitWriter', '-j6'], check=True)
    crypto = UPSTREAM / 'toolchains/gnutls-ios'
    if (not (crypto / 'include/gnutls/gnutls.h').is_file() or any(
            not (crypto / 'lib' / f'lib{name}.a').is_file()
            or not (crypto / 'lib' / f'lib{name}.a').stat().st_size for name in CRYPTO_LIBRARIES)):
        subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=UPSTREAM / 'build/gnutls-ios/src', check=True)
        subprocess.run(['bash', 'build/gnutls-ios/build.sh'], cwd=UPSTREAM, check=True)


def build_native():
    """Build the upstream archives, including the absent cold-build server base."""
    verify_pin()
    run_checked_recipe('fex-arm64ec')
    def run(*args): subprocess.run(args, cwd=UPSTREAM, check=True)
    for name in ('llvm-project/llvm', 'llvm-ios-build/lib', 'gnutls-ios/include'):
        if not (UPSTREAM / 'toolchains' / name).is_dir():
            raise ValueError('Prepare the upstream toolchain first: toolchains/' + name)
    run('rustup', 'target', 'add', 'aarch64-apple-ios')
    run('bash', 'build/rppairing-ios/build.sh')
    run('bash', 'build/ffmpeg/build.sh')
    run('bash', 'build/freetype-ios/build.sh')
    run('cmake', '-S', 'FEX', '-B', 'FEX/build-ios', '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_SYSTEM_PROCESSOR=arm64', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
        '-DCMAKE_BUILD_TYPE=Release', '-DTUNE_CPU=generic', '-DBUILD_TESTING=OFF',
        '-DBUILD_THUNKS=OFF', '-DBUILD_FEXCONFIG=OFF', '-DBUILD_FEX_LINUX_TESTS=OFF',
        '-DBUILD_STEAM_SUPPORT=OFF', '-DENABLE_FEX_ALLOCATOR=OFF', '-DENABLE_ASSERTIONS=OFF',
        '-DENABLE_CLANG_THUNKS=ON', '-DENABLE_CCACHE=ON', '-DENABLE_WERROR=OFF',
        '-DENABLE_STRICT_WERROR=OFF', '-DENABLE_LTO=OFF', '-DENABLE_VIXL_DISASSEMBLER=OFF',
        '-DENABLE_VIXL_SIMULATOR=OFF', '-DENABLE_ZYDIS=OFF')
    run('cmake', '--build', 'FEX/build-ios', '--target', 'FEXCore', 'FEXCore_Base',
        'JemallocLibs', 'fmt', 'xxhash', 'cephes_128bit', 'softfloat_3e', '-j6')
    wine = UPSTREAM / 'wine/build-macos'
    wine.mkdir(exist_ok=True)
    subprocess.run(['../configure', '--enable-win64', '--enable-archs=aarch64,arm64ec',
                    '--without-x', '--without-freetype', '--disable-tests'], cwd=wine, check=True)
    subprocess.run(['make', '-j6', 'include/all', 'tools/winebuild/winebuild', 'tools/widl/widl'], cwd=wine, check=True)
    server = UPSTREAM / 'build/wineserver'
    if not (server / 'obj/libwineserver.a').exists():
        text = (server / 'build.sh').read_text().split('# Patched files:')[0]
        begin, end = text.index('# Copy the base library'), text.index('CC_FLAGS=')
        text = text[:begin] + text[end:]
        text = text.replace('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"', 'BUILD_DIR=' + shlex.quote(str(server)))
        # Compile the untouched members with the original compiler flags; the
        # upstream script then supplies all its iOS-specific replacement members.
        text += '''
for src in "$WINE_SRC"/server/*.c; do
    name=$(basename "$src" .c)
    case "$name" in request|main|mach|unicode|fd|process|window|mapping|queue) continue ;; esac
    compile_one "$src" "$name"
done
ar rcs "$OBJ_DIR/libwineserver.a" "$OBJ_DIR"/*.o
'''
        subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, check=True)
    for component in ('wineserver', 'ntdll-unix', 'win32u-unix'):
        run_checked_recipe(component)
    headers = UPSTREAM / 'build/dxmt-ios/shader-headers'
    headers.mkdir(parents=True, exist_ok=True)
    for name in ('air_msad', 'air_samplepos', 'air_tessellation'):
        source = UPSTREAM / f'dxmt/src/airconv/shaders/{name}.metal'
        if name == 'air_tessellation':
            # New Metal SDKs changed the private intrinsic's argument count.
            # The public operation has the same relaxed threadgroup semantics.
            text = source.read_text().replace(
                '__metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__)',
                'atomic_fetch_add_explicit(reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed)')
            source = headers / f'{name}.metal'
            source.write_text(text)
        air = headers / f'{name}.air'
        run('xcrun', '--sdk', 'iphoneos', 'metal', '-std=metal3.1', '--target=air64-apple-ios18.0', '-c', str(source), '-o', str(air))
        run('xxd', '-n', name, '-i', str(air), str(headers / f'{name}.h'))
    text = (UPSTREAM / 'build/dxmt-ios/build.sh').read_text()
    metal = OUTPUT / 'embedding/winemetal_ios.c'
    metal.parent.mkdir(parents=True, exist_ok=True)
    metal.write_text(madeira_threads.apply_metal(
        (UPSTREAM / 'dxmt/src/winemetal/unix/winemetal_unix.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsMetal.h'))
    signature = OUTPUT / 'embedding/dxbc_signature.cpp'
    signature.write_text(madeira_threads.apply_vertex_outputs(
        (UPSTREAM / 'dxmt/src/airconv/dxbc_signature.cpp').read_text()))
    marker = '    compile_cxx "$DXMT_SRC/airconv/$cpp" "$name"'
    if text.count(marker) != 1: raise ValueError('Madeira shader signature build recipe changed')
    text = text.replace(marker, '    if [ "$cpp" = dxbc_signature.cpp ]; then\n'
                        '        compile_cxx ' + shlex.quote(str(signature)) + ' "$name"\n'
                        '    else\n' + marker + '\n    fi')
    text = text.replace('INCLUDES="', 'INCLUDES="-iquote' + str(UPSTREAM / 'dxmt/src/airconv') + ' ', 1)
    marker = 'compile_objc "$DXMT_SRC/winemetal/unix/winemetal_unix.c" winemetal_unix'
    if text.count(marker) != 1: raise ValueError('Madeira Metal build recipe changed')
    text = text.replace(marker, 'INCLUDES="$INCLUDES -iquote' + str(UPSTREAM / 'dxmt/src/winemetal/unix')
                        + '"\ncompile_objc ' + shlex.quote(str(metal)) + ' winemetal_unix')
    text = text.replace('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
                        'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/dxmt-ios')))
    # Select the installed Metal tool. The AIR target and language remain the
    # original macOS 14 / Metal 3.1 values from Madeira's script.
    if subprocess.run(['xcrun', '--sdk', 'macosx', '--find', 'metal'], capture_output=True).returncode:
        text = text.replace('xcrun -sdk macosx metal', 'xcrun -sdk iphoneos metal')
    subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, check=True)
    run('xcrun', '--sdk', 'iphoneos', 'libtool', '-static', '-o', 'app/Madeira/libdxmt_combined.a',
        *map(str, sorted((UPSTREAM / 'build/dxmt-ios/obj').glob('*.o'))),
        *map(str, sorted((UPSTREAM / 'toolchains/llvm-ios-build/lib').glob('*.a'))))
    # New upstream units must be present in the archives that the app links.
    for name, required in {'libwineserver.a': 'storage_device_ios.o',
                           'libdxmt_combined.a': 'madeira_sc_pack.o'}.items():
        members = subprocess.check_output(['xcrun', 'ar', '-t', str(UPSTREAM / 'app/Madeira' / name)], text=True).splitlines()
        if required not in members:
            raise ValueError('Missing required native archive member: ' + name + '/' + required)
    run('bash', 'build/madeira-dock/build.sh', '--check')


def file_digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_source_inventory():
    """List tracked source inputs, including initialized dependencies, without changing them."""
    if not (ROOT / '.git').exists():
        inventory = json.loads((ROOT / 'MADEIRA-NATIVE-SOURCES.json').read_text())
        expected = {'vendor/Madeira': REVISION, 'vendor/Madeira/research/freetype': FREETYPE_REVISION}
        expected.update({'vendor/Madeira/' + name: revision for name, revision in
                         json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']['dependencies'].items()})
        if (inventory.get('schema') != 1 or not isinstance(inventory.get('files'), dict) or not inventory['files']
                or any(inventory.get('revisions', {}).get(name) != revision for name, revision in expected.items())):
            raise ValueError('Missing or invalid native source inventory')
        return inventory
    files, revisions = {}, {}
    def visit(repo, revision, required=False):
        label = repo.relative_to(ROOT).as_posix()
        revisions[label] = revision
        if not (repo / '.git').exists():
            if required: raise ValueError('Native source is not initialized: ' + label)
            return
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revision: raise ValueError('Unexpected native source revision: ' + label)
        rows = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-r', '-z', 'HEAD'])
        for row in filter(None, rows.split(b'\0')):
            meta, name = row.split(b'\t', 1)
            mode, kind, blob = meta.decode().split()
            name = name.decode()
            if kind == 'commit':
                child = (repo / name).relative_to(UPSTREAM).as_posix()
                required_child = child in ('FEX', 'wine', 'dxmt', 'madeira-dock',
                    'FEX/External/fmt', 'FEX/External/range-v3', 'FEX/External/rpmalloc',
                    'FEX/External/unordered_dense', 'FEX/External/vixl', 'FEX/External/xxhash',
                    'FEX/Source/Common/cpp-optparse') or child.startswith('dxmt/')
                visit(repo / name, blob, required_child)
            elif kind == 'blob':
                relative = (repo / name).relative_to(UPSTREAM).as_posix()
                if relative not in native_required_outputs(): files[label + '/' + name] = mode
    visit(UPSTREAM, REVISION, True)
    visit(UPSTREAM / 'research/freetype', FREETYPE_REVISION, True)
    return {'schema': 1, 'files': files, 'revisions': revisions}


def native_source_identity():
    inventory = native_source_inventory()
    digest = hashlib.sha256()
    for name, mode in sorted(inventory['files'].items()):
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not relative.is_relative_to('vendor/Madeira'):
            raise ValueError('Invalid native source path: ' + name)
        path = ROOT / relative
        if not path.resolve().is_relative_to(UPSTREAM.resolve()): raise ValueError('Native source escapes its tree: ' + name)
        if path.is_symlink():
            payload = os.readlink(path).encode()
            value = hashlib.sha256(payload).hexdigest()
            if path.is_file(): value += ':' + file_digest(path)
            observed_mode = '120000'
        elif path.is_file():
            if name == 'vendor/Madeira/FEX/FEXCore/Source/Utils/AllocWatch.cpp':
                value = hashlib.sha256(madeira_threads.apply_fex(path.read_text()).encode()).hexdigest()
            elif name == 'vendor/Madeira/FEX/Source/Windows/ARM64EC/Module.cpp':
                value = hashlib.sha256(madeira_threads.apply_fex_arm64ec(path.read_text()).encode()).hexdigest()
            else: value = file_digest(path)
            observed_mode = '100755' if path.stat().st_mode & 0o111 else '100644'
        else:
            raise ValueError('Missing native source file: ' + name)
        if mode not in ('100644', '100755', '120000'): raise ValueError('Invalid native source mode: ' + name)
        digest.update(json.dumps([name, observed_mode, value]).encode() + b'\n')
    return {'revisions': inventory['revisions'], 'trackedFiles': len(inventory['files']), 'sha256': digest.hexdigest()}


def native_inputs():
    tools = compiler_tools()
    bison = tools['bison --version']
    words = bison['version'].splitlines()[0].split() if bison['version'] else []
    major = words[-1].split('.')[0] if words else ''
    if not major.isdigit() or int(major) < 3:
        raise ValueError('Native build requires Bison >= 3.0 before bootstrap: ' + repr(bison))
    return {'revision': REVISION,
            'enginePin': engine_pins.selected('madeira-native', json.loads((ROOT / engine_pins.MANIFEST).read_text())),
            'recipes': {name: hashlib.sha256(inspect.getsource(fn).encode()).hexdigest() for name, fn in (
                ('build_native', build_native), ('bootstrap', bootstrap), ('toolchains', toolchains),
                ('prepare_freetype', prepare_freetype), ('verify_pin', verify_pin),
                ('native_source_inventory', native_source_inventory), ('native_source_identity', native_source_identity),
                ('run_checked_recipe', run_checked_recipe), ('stage_crypto_libraries', stage_crypto_libraries))},
            'files': {name: file_digest(ROOT / name) for name in (
                'ci/runtime-inputs.json', 'ci/local_build_tools.py', 'ci/fetch-runtime-inputs.py', 'ci/engine_pins.py', 'ci/madeira_audio_volume.py', 'ci/madeira_threads.py',
                'iridium/apps/ios/RuntimeBridge/IRAudioVolume.c', 'iridium/apps/ios/RuntimeBridge/IRAudioVolume.h',
                'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.c', 'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.h',
                'iridium/apps/ios/RuntimeBridge/IRWindowsMetal.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetalEvents.h')},
            'cryptoLibraries': list(CRYPTO_LIBRARIES), 'tools': tools, 'upstreamSources': native_source_identity()}


def native_key(inputs):
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def native_required_outputs():
    app = ['app/Madeira/lib' + name + '.a' for name in (
        'avcodec', 'avformat', 'avutil', 'swresample', 'dxmt_combined', 'madeira_rppairing',
        'ntdll_unix', 'win32u_unix', 'wineserver', *CRYPTO_LIBRARIES)]
    fex = ['FEX/build-ios/' + name for name in (
        'External/SoftFloat-3e/libsoftfloat_3e.a', 'External/cephes/libcephes_128bit.a',
        'External/fmt/libfmt.a', 'External/xxhash/cmake_unofficial/libxxhash.a',
        'FEXCore/Source/libFEXCore.a', 'FEXCore/Source/libFEXCore_Base.a', 'FEXCore/Source/libJemallocLibs.a')]
    return app + fex + ['toolchains/gnutls-ios/lib/lib' + name + '.a' for name in CRYPTO_LIBRARIES] + [
        'app/Madeira/arm64ec-windows/dockhost.exe', 'app/Madeira/arm64ec-windows/dock-notices.txt',
        'app/Madeira/arm64ec-windows/xtajit64.dll',
        'app/Madeira/legal/LICENSES-rppairing-crates.txt']


def native_record_issues(saved, inputs, upstream):
    """Validate portable relative outputs without touching the stamp or compiler trees."""
    issues = []
    if not isinstance(saved, dict): return ['invalid_record: expected an object']
    if saved.get('schema') != 2 or isinstance(saved.get('schema'), bool) or saved.get('state') != 'complete':
        issues.append('incomplete_record: schema=' + repr(saved.get('schema')) + ' state=' + repr(saved.get('state')))
    if saved.get('key') != native_key(inputs):
        issues.append('key_mismatch saved=' + repr(saved.get('key')) + ' current=' + native_key(inputs))
    def compare(old, new, label):
        if isinstance(old, dict) and isinstance(new, dict):
            for name in sorted(old.keys() | new.keys()):
                compare(old.get(name), new.get(name), label + '.' + name)
        elif old != new:
            issues.append('input_mismatch:' + label + ' saved=' + repr(old) + ' current=' + repr(new))
    compare(saved.get('inputs'), inputs, 'inputs')
    completed = saved.get('completed')
    now = time.time()
    if (isinstance(completed, bool) or not isinstance(completed, (int, float))
            or not 0 <= now - completed < 14 * 86400):
        issues.append('completion_expired_or_invalid completed=' + repr(completed)
                      + ' now=' + repr(now) + ' retentionSeconds=' + str(14 * 86400))
    outputs = saved.get('outputs')
    if not isinstance(outputs, dict) or not outputs: return issues + ['missing_outputs']
    present = {str(path.relative_to(upstream)) for path in (upstream / 'app/Madeira').glob('*.a')}
    present.update(str(path.relative_to(upstream)) for path in (upstream / 'FEX/build-ios').rglob('*.a'))
    for name in sorted((set(native_required_outputs()) | present) - outputs.keys()):
        issues.append('unrecorded_output:' + name)
    for name, expected in sorted(outputs.items()):
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or path.as_posix() != name:
            issues.append('invalid_output_path:' + name)
            continue
        path = upstream / path
        try:
            if path.is_symlink() or not path.resolve().is_relative_to(upstream.resolve()):
                issues.append('invalid_output_path:' + name)
            elif not path.is_file() or not path.stat().st_size:
                issues.append('missing_output:' + name)
            else:
                observed = file_digest(path)
                if observed != expected:
                    issues.append('changed_output:' + name + ' saved=' + str(expected) + ' current=' + observed)
        except OSError as error:
            issues.append('unreadable_output:' + name + ' ' + str(error))
    return issues


def validate_native_reuse(upstream=None, inputs=None):
    upstream = UPSTREAM if upstream is None else upstream
    inputs = native_inputs() if inputs is None else inputs
    stamp = upstream / '.build/iridium-native.json'
    try:
        if stamp.is_symlink(): raise ValueError('Completion record must not be a symlink')
        issues = native_record_issues(json.loads(stamp.read_text()), inputs, upstream)
    except (OSError, ValueError) as error:
        issues = ['unreadable_record:' + str(error)]
    print(json.dumps({'component': 'madeira-native', 'reuse': not issues, 'key': native_key(inputs),
                      'issues': issues}, sort_keys=True), flush=True)
    if issues: raise ValueError('Madeira native reuse rejected: ' + '; '.join(issues))


def require_fresh_native_substages():
    # A failed/expired receipt cannot authorize existence-only reuse inside these recipes.
    paths = ('toolchains/llvm-host-build', 'toolchains/llvm-ios-build', 'toolchains/gnutls-ios',
             'toolchains/ffmpeg-ios', 'build/ffmpeg/obj', 'build/gnutls-ios/obj', 'build/wineserver/obj',
             'build/ntdll-unix/obj', 'build/win32u-unix/obj', 'build/dxmt-ios/obj',
             'build/dxmt-ios/shader-headers', 'build/dxmt-ios/libdxmt_combined.a',
             'build/dxmt-ios/libdxmt_unix.a', 'FEX/build-ios', 'FEX/build-arm64ec', 'build/freetype-ios/build',
             'wine/build-macos', 'build/rppairing-ios/target')
    existing = [name for name in paths if (UPSTREAM / name).exists() or (UPSTREAM / name).is_symlink()]
    if existing:
        raise ValueError('Unverified native substages exist; use an independent fresh checkout, without deleting or '
                         'resealing these outputs: ' + ', '.join(existing))


def native(reuse_only=False):
    verify_pin()
    inputs = native_inputs()
    try:
        validate_native_reuse(inputs=inputs)
        return
    except ValueError:
        if reuse_only: raise
    require_fresh_native_substages()
    bootstrap()
    build_native()
    crypto = stage_crypto_libraries()
    outputs = sorted((UPSTREAM / 'app/Madeira').glob('*.a')) + sorted((UPSTREAM / 'FEX/build-ios').rglob('*.a'))
    outputs += crypto
    outputs += [UPSTREAM / 'app/Madeira' / name for name in (
        'arm64ec-windows/dockhost.exe', 'arm64ec-windows/dock-notices.txt',
        'arm64ec-windows/xtajit64.dll',
        'legal/LICENSES-rppairing-crates.txt')]
    if native_inputs() != inputs:
        raise ValueError('Native inputs changed during compilation; completion record not written')
    saved = dict(schema=2, state='complete', key=native_key(inputs), inputs=inputs, completed=time.time(),
                 outputs={str(path.relative_to(UPSTREAM)): file_digest(path) for path in outputs})
    issues = native_record_issues(saved, inputs, UPSTREAM)
    if issues: raise ValueError('Native build is incomplete: ' + '; '.join(issues))
    stamp = UPSTREAM / '.build/iridium-native.json'
    stamp.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=stamp.parent, prefix='iridium-native-', delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(json.dumps(saved, indent=2) + '\n')
    try:
        temporary.replace(stamp)
    finally:
        temporary.unlink(missing_ok=True)
    print('Saved the completed native build before app compilation and packaging.')


def app(reuse_psp):
    subprocess.run([sys.executable, str(ROOT / 'ci/build-sameboy.py'),
                    '--output', str(ROOT / '.build/sameboy/iphoneos'),
                    '--sdk', 'iphoneos', '--target', 'arm64-apple-ios18.0'], check=True)
    if not reuse_psp:
        subprocess.run([sys.executable, str(ROOT / 'ci/build-ppsspp-native.py'),
                        '--output', str(PSP_OUTPUT), '--sdk', 'iphoneos'], check=True)
    prepare()
    command = ['xcodebuild', '-project', str(OUTPUT / 'app/Madeira.xcodeproj'),
               '-scheme', 'Iridium', '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
               '-derivedDataPath', str(ROOT / '.build/madeira-frontend-derived'),
               'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'DEVELOPMENT_TEAM=',
               'ENABLE_DEBUG_DYLIB=NO', 'LD_GENERATE_MAP_FILE=YES']
    if os.environ.get('IRIDIUM_BUILD_NUMBER'):
        value = os.environ['IRIDIUM_BUILD_NUMBER']
        if not all(part.isdigit() for part in value.split('.')): raise ValueError('Invalid build number')
        command.append('CURRENT_PROJECT_VERSION=' + value)
    subprocess.run(command + ['build'], cwd=ROOT, check=True)
    verify()
    check_bundle(ROOT / '.build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'verify', 'app', 'native', 'windows', 'toolchains', 'check-bundle'))
    parser.add_argument('app', nargs='?', type=Path)
    parser.add_argument('--reuse-psp-component', action='store_true', help='Validate and retain an explicitly rebuilt PSP component during relinking')
    parser.add_argument('--reuse-only', action='store_true', help='Validate completed native outputs without building or writing')
    args = parser.parse_args()
    if args.reuse_psp_component and args.action != 'app': parser.error('--reuse-psp-component requires app')
    if args.reuse_only and args.action != 'native': parser.error('--reuse-only requires native')
    if args.action == 'check-bundle':
        if args.app is None: parser.error('check-bundle requires the built app path')
        check_bundle(args.app)
        print('The built app contains the pinned Madeira runtime farms, WoW64 and D3D12.')
    else:
        if args.app is not None: parser.error('Only check-bundle accepts an app path')
        {'prepare': prepare, 'verify': verify, 'app': lambda: app(reuse_psp=args.reuse_psp_component), 'native': lambda: native(reuse_only=args.reuse_only), 'windows': windows, 'toolchains': toolchains}[args.action]()
