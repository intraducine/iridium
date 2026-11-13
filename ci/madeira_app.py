"""Stage, link and audit the Iridium iOS app using built runtime components."""
import argparse
import copy
import hashlib
import importlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys

import engine_pins
import madeira_components

# The hyphenated filename remains the supported compiler CLI.
compiler = importlib.import_module('madeira-frontend')
ROOT = compiler.ROOT
UPSTREAM = compiler.UPSTREAM
OUTPUT = compiler.OUTPUT
REVISION = compiler.REVISION
RUNTIME_BRIDGE = compiler.RUNTIME_BRIDGE
verify_pin = compiler.verify_pin
compiler_identity = compiler.compiler_identity
check_psp_jit_interface = compiler.check_psp_jit_interface

FRONTEND = ROOT / 'iridium/apps/ios/MadeiraFrontend'
RUNTIME_SUPPORT = ROOT / 'iridium/apps/ios/RuntimeSupport'
PSP_REVISION = engine_pins.get('ppsspp')['revision']
PSP_OUTPUT = ROOT / '.build/ppsspp/iphoneos'
RUNTIME_HEADERS = '\n#import "IRJITPrepare.h"\n#import "IridiumCoreBridge.h"\n#import "IRPSPNativeBridge.h"\n#import "IRArchive.h"\n'
PSP_PRIVACY_DESCRIPTIONS = {
    'NSCameraUsageDescription': 'PSP and 3DS games can request camera input while you play.',
    'NSMicrophoneUsageDescription': 'PSP and 3DS games can request microphone input while you play.',
    'NSMotionUsageDescription': 'Wii, 3DS, and PSP controls use device motion while you play.',
    'NSLocationWhenInUseUsageDescription': 'A PSP game can use your location to emulate the Go!Explore GPS accessory while playing.',
    'NSPhotoLibraryUsageDescription': 'Choose a photo for the PPSSPP background when you request it.',
    'NSLocalNetworkUsageDescription': 'Iridium uses the local network for Steam transfers, PSP and Dreamcast multiplayer, and on-device JIT pairing.',
}


def overlay(name, text):
    """Legacy test entry point: read maintained shipping source, never rewrite upstream UI."""
    import iridium_app_sources as app_sources
    owned = app_sources.logical_source(name)
    return text if owned is None else owned


def project(source, names):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(source)]))
    objects = data['objects']
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Madeira')
    current = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-',
        str(UPSTREAM / 'app/Madeira.xcodeproj/project.pbxproj')]))
    upstream_objects = current['objects']
    upstream_target = next(v for v in upstream_objects.values()
        if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Madeira')
    # Native sources follow the engine; Swift screens still come only from App.
    for key, value in upstream_objects.items():
        if key not in objects: objects[key] = copy.deepcopy(value)
    main_group = next(v for v in objects.values() if v.get('isa') == 'PBXGroup' and v.get('path') == 'Madeira')
    for kind in ('PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXResourcesBuildPhase'):
        old = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == kind)
        new = next(upstream_objects[key] for key in upstream_target['buildPhases'] if upstream_objects[key]['isa'] == kind)
        known = {objects[objects[key]['fileRef']].get('path') for key in old['files']}
        for key in new['files']:
            reference = upstream_objects[key]['fileRef']
            path = upstream_objects[reference].get('path', '')
            if path.endswith('.swift') or path in known: continue
            old['files'].append(key)
            if reference not in main_group['children']: main_group['children'].append(reference)
    memory_key = next(key for key, value in upstream_objects.items()
        if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'MadeiraMemoryHost')
    root_project = objects[data['rootObject']]
    if memory_key not in root_project['targets']: root_project['targets'].append(memory_key)
    for key in upstream_target.get('dependencies', []):
        if upstream_objects[key].get('target') == memory_key and key not in target['dependencies']:
            target['dependencies'].append(key)
    for key in upstream_target['buildPhases']:
        phase = upstream_objects[key]
        if phase['isa'] == 'PBXCopyFilesBuildPhase' and any(
                upstream_objects[upstream_objects[file]['fileRef']].get('path') == 'MadeiraMemoryHost.appex'
                for file in phase['files']):
            if key not in target['buildPhases']: target['buildPhases'].append(key)
    for key, value in upstream_objects.items():
        if value.get('isa') == 'PBXGroup' and value.get('path') == 'MadeiraMemoryHost':
            root = objects[root_project['mainGroup']]
            if key not in root['children']: root['children'].append(key)
    product = upstream_objects[memory_key]['productReference']
    products = objects[root_project['productRefGroup']]
    if product not in products['children']: products['children'].append(product)
    target['name'] = target['productName'] = 'Iridium'
    objects[target['productReference']]['path'] = 'Iridium.app'
    group = next(v for v in objects.values() if v.get('isa') == 'PBXGroup' and v.get('path') == 'Madeira')
    sources = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
    existing_sources = {objects[objects[key]['fileRef']].get('path') for key in sources['files']}
    for index, name in enumerate(names):
        if name in existing_sources: continue
        existing_sources.add(name)
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
        for index, path in enumerate(('Sys', 'GameConfig.xml')):
            ref, build = f'F300000000000001{index:08X}', f'F400000000000001{index:08X}'
            objects[ref] = dict(isa='PBXFileReference', lastKnownFileType='folder' if index == 0 else 'text.xml', path=path, sourceTree='<group>')
            objects[build] = dict(isa='PBXBuildFile', fileRef=ref)
            resources['files'].append(build); group['children'].append(ref)
    if os.environ.get('IRIDIUM_MELONX') == '1':
        from iridium_app_sources import melonx_component
        component = melonx_component()
        for index, (binary, name) in enumerate(component.packaged_files()):
            framework = '/' in name
            source = binary.parent if framework else binary
            ref, build = f'F500000000000000{index:08X}', f'F600000000000000{index:08X}'
            objects[ref] = dict(isa='PBXFileReference',
                lastKnownFileType='wrapper.framework' if framework else 'compiled.mach-o.dylib',
                path='../../' + source.relative_to(ROOT / '.build').as_posix(), sourceTree='SOURCE_ROOT')
            objects[build] = dict(isa='PBXBuildFile', fileRef=ref,
                                  settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})
            objects[embed]['files'].append(build)
            group['children'].append(ref)
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
        append('OTHER_LDFLAGS', ['-lIridiumSameBoy', '-larchive', '-framework', 'CoreFoundation'], unique=False)
        append('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['IRIDIUM_PPSSPP'])
        if (os.environ.get('IRIDIUM_PHASE3') == '1'): append('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['IRIDIUM_PHASE3'])
        if os.environ.get('IRIDIUM_MELONX') == '1':
            append('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['IRIDIUM_MELONX'])
    for value in objects.values():
        if value.get('isa') == 'XCBuildConfiguration':
            value['buildSettings']['MARKETING_VERSION'] = '0.3.0'
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


def prepare_helper_versions(app):
    for name in ('MadeiraJITHelper', 'MadeiraMemoryHost'):
        path = app / name / 'Info.plist'
        data = plistlib.loads(path.read_bytes())
        data['CFBundleShortVersionString'] = '$(MARKETING_VERSION)'
        data['CFBundleVersion'] = '$(CURRENT_PROJECT_VERSION)'
        if name == 'MadeiraMemoryHost': data['CFBundleDisplayName'] = 'Iridium Memory'
        path.write_bytes(plistlib.dumps(data))


def prepare():
    import iridium_app_sources as app_sources
    melonx = None
    if os.environ.get('IRIDIUM_MELONX') == '1':
        if os.environ.get('IRIDIUM_PHASE3') != '1':
            raise ValueError('MeloNX needs the shared console player build')
        melonx = app_sources.melonx_component()
        subprocess.run([sys.executable, '-B', str(ROOT / 'ci/build-melonx-core.py'), '--inspect'], check=True)
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
    import stikjit_frontend
    stikjit_frontend.stage(app)
    prepare_helper_versions(app)
    sources = sorted(p for p in RUNTIME_BRIDGE.glob('*.c')
        if p.name not in ('IRPSPBridge.c', 'IRPPSSPPCodecCheck.c'))
    for source in sources:
        shutil.copy2(source, app / 'Madeira' / source.name)
        names.append(source.name)
    for name in ('IridiumCoreBridge.h', 'IRArchive.h', 'IRCoreOptions.h', 'IRCheats.h', 'IRWindowsThreads.h', 'IRPSPNativeBridge.h', 'IRJITDiagnostic.h', 'IRPSPExecutableMemory.h', 'IRPSPTeardownObservation.h', 'IRPhase3.h', 'IRDolphinAPI.h', 'IRAudioVolume.h', 'IRJITMemory.h', 'IRJITPrepare.h'):
        shutil.copy2(RUNTIME_BRIDGE / name, app / 'Madeira' / name)
    for name in ('IRJITReadiness.h', 'IRJITExecutionProbe.h'):
        shutil.copy2(RUNTIME_BRIDGE / name, app / 'Madeira' / name)
    header = app / 'Madeira/Madeira-Bridging-Header.h'
    header.write_text(header.read_text() + RUNTIME_HEADERS + '\n#import "IRJITMemory.h"\n#import "IRPhase3.h"\n#import "IRDolphinAPI.h"\n#import "IRAudioVolume.h"\n#import "IRWindowsThreads.h"\n#import "IRJITReadiness.h"\n')
    import madeira_session
    for name in ('iridium-session.exe', 'iridium-session.json', 'iridium-session-notices.txt'):
        legacy = app / 'Madeira/arm64ec-windows' / name
        if legacy.is_symlink(): raise ValueError('Legacy session output must not be a symlink')
        legacy.unlink(missing_ok=True)
    madeira_session.build(app / 'Madeira/aarch64-windows')
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
    licenses = app / 'Madeira/licenses'
    if melonx:
        data['IridiumMeloNXRevision'] = melonx.REVISION
        data['IridiumRuntimeRevisions']['MeloNX'] = melonx.REVISION
        for name, source in app_sources.MELONX_LICENSES.items():
            shutil.copy2(melonx.SOURCE / source, licenses / name)
    else:
        for name in app_sources.MELONX_LICENSES:
            (licenses / name).unlink(missing_ok=True)
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
        if path.name == 'Madeira-Bridging-Header.h': expected += (RUNTIME_HEADERS + '\n#import "IRJITMemory.h"\n#import "IRPhase3.h"\n#import "IRDolphinAPI.h"\n#import "IRAudioVolume.h"\n#import "IRWindowsThreads.h"\n#import "IRJITReadiness.h"\n').encode()
        if not generated.is_file() or generated.read_bytes() != expected:
            raise ValueError('Staged native input differs from its pinned source: ' + str(path))
    print('Iridium-owned app sources verified; pinned native inputs match their source.')


def check_bundle(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if 'IridiumMeloNXRevision' in info:
        from iridium_app_sources import MELONX_LICENSES, melonx_component
        melonx = melonx_component()
        record = json.loads(melonx.RECEIPT.read_text())
        if info['IridiumMeloNXRevision'] != melonx.REVISION or record != melonx.component_record():
            raise ValueError('MeloNX source or component receipt differs')
        for name, source in MELONX_LICENSES.items():
            notice = app / 'licenses' / name
            if not notice.is_file() or notice.read_bytes() != (melonx.SOURCE / source).read_bytes():
                raise ValueError('MeloNX packaged notice differs or is missing: ' + name)
        for source, name in melonx.packaged_files():
            binary = app / 'Frameworks' / name
            if binary.is_symlink() or not binary.is_file() or (
                melonx.digest(binary) != record['files'][name] and
                madeira_components.unsigned_digest(binary) != madeira_components.unsigned_digest(source)
            ):
                raise ValueError('MeloNX packaged binary differs: ' + name)
    elif os.environ.get('IRIDIUM_MELONX') == '1' or (app / 'Frameworks/libIridiumMeloNX.dylib').exists():
        raise ValueError('MeloNX component metadata is missing')
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

    import stikjit_frontend
    stikjit_frontend.verify(app / "Frameworks/StikJIT.framework")
    receipts = madeira_components.verify(UPSTREAM, app, compiler_identity())
    import madeira_session
    madeira_session.verify(app / 'aarch64-windows')
    return receipts


def app(reuse_psp):
    import stikjit_frontend
    stikjit_frontend.build()
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
               'ENABLE_DEBUG_DYLIB=NO', 'LD_GENERATE_MAP_FILE=YES',
               'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym']
    if os.environ.get('IRIDIUM_BUILD_NUMBER'):
        value = os.environ['IRIDIUM_BUILD_NUMBER']
        if not all(part.isdigit() for part in value.split('.')): raise ValueError('Invalid build number')
        command.append('CURRENT_PROJECT_VERSION=' + value)
    subprocess.run(command + ['build'], cwd=ROOT, check=True)
    bundle = ROOT / '.build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app'
    # Xcode can retain a removed folder in an incremental app bundle.
    duplicate = bundle / 'Phase3/dolphin/Sys'
    if duplicate.is_symlink() or any(p.is_symlink() for p in duplicate.parents):
        raise ValueError('Stale Dolphin resource path contains a symbolic link')
    if duplicate.exists():
        shutil.rmtree(duplicate)
    if not (bundle.with_suffix('.app.dSYM') / 'Contents/Resources/DWARF/Iridium').is_file():
        raise ValueError('Missing Iridium debug symbols')
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'strip', '-x', bundle / 'Iridium'], check=True)
    verify()
    check_bundle(bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('app', 'prepare', 'verify', 'check-bundle'))
    parser.add_argument('app', nargs='?', type=Path)
    parser.add_argument('--reuse-psp-component', action='store_true', help='Validate and retain an explicitly rebuilt PSP component during relinking')
    args = parser.parse_args()
    if args.reuse_psp_component and args.action != 'app': parser.error('--reuse-psp-component requires app')
    if args.action == 'check-bundle':
        if args.app is None: parser.error('check-bundle requires the built app path')
        check_bundle(args.app)
        print('The built app contains the pinned Madeira runtime farms, WoW64 and D3D12.')
    else:
        if args.app is not None: parser.error('Only check-bundle accepts a path')
        {'prepare': prepare, 'verify': verify, 'app': lambda: app(reuse_psp=args.reuse_psp_component)}[args.action]()


if __name__ == '__main__':
    main()
