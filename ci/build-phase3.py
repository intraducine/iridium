#!/usr/bin/env python3
"""Build pinned Phase 3 upstream iOS components and retain complete receipts."""
import argparse
import engine_pins
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
PINS = {name: (Path(pin['path']).name, pin['revision'], pin['releaseTag'])
        for name in ('dolphin', 'azahar', 'play', 'flycast') for pin in [engine_pins.get(name)]}
NATIVE_EXPORTS = {'_ir_native_engine_' + name for name in ('abi', 'create', 'pause', 'stop', 'frames', 'set_volume')}
DOLPHIN_EXPORTS = NATIVE_EXPORTS | {'_ir_dolphin_api'}
AZAHAR_DOWNLOADS = {item['filename']: item['sha256']
                    for item in engine_pins.get('azahar')['artifacts'].values()}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*command):
    print(' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, cwd=ROOT)


def output(*command):
    return subprocess.check_output(list(map(str, command)), text=True, cwd=ROOT).strip()


def source_state(source):
    """Verify initialized dependency pins; tolerate only zlib's exact CMake rename."""
    revisions = {}
    def visit(repo):
        revision = output('git', '-C', repo, 'rev-parse', 'HEAD')
        changed = output('git', '-C', repo, 'diff', '--name-status', '--ignore-submodules=all', 'HEAD')
        if changed:
            renamed = 'deps/zlib-1.3.1/zconf.h'
            included = repo / (renamed + '.included')
            original = subprocess.check_output(['git', '-C', str(repo), 'show', 'HEAD:' + renamed]) if changed == 'D\t' + renamed else None
            if original is None or not included.is_file() or included.is_symlink() or included.read_bytes() != original:
                raise ValueError('Modified upstream source: ' + repo.relative_to(ROOT).as_posix())
        untracked = output('git', '-C', repo, 'ls-files', '--others', '--exclude-standard', '-z').split('\0')
        if any(name and (name != 'deps/zlib-1.3.1/zconf.h.included' or not changed) for name in untracked):
            raise ValueError('Untracked upstream source: ' + repo.relative_to(ROOT).as_posix())
        revisions[repo.relative_to(ROOT).as_posix()] = revision
        records = output('git', '-C', repo, 'ls-files', '--stage', '-z').split('\0')
        for record in records:
            if not record.startswith('160000 '): continue
            meta, name = record.split('\t', 1)
            child = repo / name
            if not (child / '.git').exists(): continue
            if output('git', '-C', child, 'rev-parse', 'HEAD') != meta.split()[1]:
                raise ValueError('Dependency differs from its pin: ' + child.relative_to(ROOT).as_posix())
            visit(child)
    visit(source)
    return revisions


def input_paths(engine):
    names = ['ci/engine_pins.py', 'ci/build-phase3.py', 'ci/phase3-cmake-hook.cmake', 'ci/phase3-targets.cmake',
             'iridium/apps/ios/RuntimeBridge/IRPhase3.h']
    bridge = {'host': ['IRRetroPlayer.mm'], 'dolphin': ['IRDolphin.mm', 'IRDolphinAPI.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'], 'azahar': ['IRAzaharJIT.cpp', 'IRAzaharGraphics.mm', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
              'play': ['IRPlayProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
              'flycast': ['IRFlycastProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h']}
    names += ['iridium/apps/ios/RuntimeBridge/' + name for name in bridge[engine]]
    if engine != 'host': names += ['ci/phase3_' + engine + '.py', 'ci/' + engine + '-targets.cmake']
    if engine in ('host', 'dolphin'):
        names += ['iridium/apps/ios/RuntimeBridge/IRAudioVolume.c', 'iridium/apps/ios/RuntimeBridge/IRAudioVolume.h']
    if engine == 'host': names += ['vendor/Flycast/core/deps/libretro-common/include/libretro.h']
    if engine == 'azahar': names += [engine_pins.get('azahar')['buildDependencies']['moltenVK']['inputs'], 'ci/build-ppsspp-moltenvk.py']
    return names


def fixed_inputs(engine):
    return {**{name: digest(ROOT / name) for name in input_paths(engine)},
            'enginePin': hashlib.sha256(json.dumps(engine_pins.selected(engine), sort_keys=True).encode()).hexdigest()}


def verify_inputs(record):
    if record.get('buildInputs') != fixed_inputs(record['engine']):
        raise ValueError('Phase 3 build recipe or ABI changed: ' + record['engine'])
    if record['engine'] != 'host':
        source = ROOT / engine_pins.get(record['engine'])['path']
        if record.get('sourceRevisions') != source_state(source):
            raise ValueError('Phase 3 dependency revisions changed: ' + record['engine'])
    for name, expected in record.get('compiledInputs', {}).items():
        if digest(ROOT / name) != expected:
            raise ValueError('Phase 3 compiled input changed: ' + name)
    for name, expected in record.get('embedding', {}).items():
        directory = ROOT / '.build/phase3' / record['engine'] / record['sdk'] / 'embedding'
        if digest(directory / name) != expected:
            raise ValueError('Phase 3 generated adapter changed: ' + name)
    if record['engine'] == 'azahar':
        library, moltenvk = azahar_moltenvk(record['sdk'])
        if record.get('moltenVK') != moltenvk or digest(library) != moltenvk['archiveSHA256']:
            raise ValueError('Azahar linked MoltenVK source closure changed')


def engine_module(engine):
    spec = importlib.util.spec_from_file_location('phase3_' + engine, ROOT / 'ci' / ('phase3_' + engine + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def azahar_module():
    return engine_module('azahar')


def azahar_moltenvk(sdk, jobs=None):
    return azahar_module().moltenvk(ROOT, sdk, jobs)


def public_arguments(arguments):
    return [str(value).replace(str(ROOT), '${IRIDIUM_ROOT}') for value in arguments]


def generated(engine, destination):
    directory = destination / 'embedding'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'native.exports').write_text('\n'.join(sorted(DOLPHIN_EXPORTS if engine == 'dolphin' else NATIVE_EXPORTS)) + '\n')
    (directory / 'retro.exports').write_text('_retro_*\n' + ('_ir_phase3_core_check_jit\n' if engine in ('azahar', 'play', 'flycast') else '') + ('_ir_phase3_core_pause\n' if engine in ('play', 'flycast') else '') + ('_ir_phase3_core_prepare\n' if engine == 'play' else '') + ('_ir_phase3_core_prepare_jit\n_ir_phase3_core_jit_status\n_ir_phase3_core_set_metal_surface\n' if engine == 'azahar' else ''))
    (directory / 'toolchain.cmake').write_text('set(CMAKE_SYSTEM_NAME iOS)\nset(CMAKE_SYSTEM_PROCESSOR aarch64)\nset(IOS ON)\n')
    if engine == 'azahar':
        azahar_module().generated(ROOT, directory)
    if engine == 'dolphin':
        engine_module(engine).generated(ROOT, directory)
    if engine == 'play':
        engine_module(engine).generated(ROOT, directory)
    if engine == 'flycast':
        engine_module(engine).generated(ROOT, directory)
    return directory


def audit(binary, sdk, native=False):
    symbols = set(output('xcrun', 'nm', '-gUj', binary).splitlines())
    if native:
        expected = DOLPHIN_EXPORTS if binary.name == 'libIridiumDolphin.dylib' else NATIVE_EXPORTS
        if symbols != expected:
            raise ValueError('Native player exports differ: ' + str(symbols ^ expected))
    elif not all(s.startswith('_retro_') or s in {'_ir_phase3_core_check_jit', '_ir_phase3_core_prepare', '_ir_phase3_core_pause', '_ir_phase3_core_prepare_jit', '_ir_phase3_core_jit_status', '_ir_phase3_core_set_metal_surface'} for s in symbols):
        raise ValueError('Upstream C++ symbols escape the core boundary')
    if not native and '_retro_run' not in symbols:
        raise ValueError('Missing upstream core interface')
    platform = 'IOSSIMULATOR' if sdk == 'iphonesimulator' else 'IOS'
    build = output('xcrun', 'vtool', '-show-build', binary)
    if re.findall(r'platform\s+(\w+)', build) != [platform]:
        raise ValueError('Wrong native platform')
    if output('xcrun', 'lipo', '-archs', binary) != 'arm64':
        raise ValueError('Wrong native architecture')
    libraries = [s.strip().split(' (', 1)[0] for s in output('xcrun', 'otool', '-L', binary).splitlines()[1:]]
    identity = '@rpath/' + binary.name
    if not libraries or libraries[0] != identity or any(not lib.startswith(('/usr/lib/', '/System/Library/Frameworks/')) for lib in libraries[1:]):
        raise ValueError('Unreviewed dynamic dependency or install name: ' + str(libraries))
    return dict(sha256=digest(binary), exports=sorted(symbols), platform=platform, dynamicLibraries=libraries)


def notices(source, destination, allowed=None):
    target = destination / 'licenses'
    if target.exists(): shutil.rmtree(target)
    target.mkdir(exist_ok=True)
    for path in (source.rglob('*') if allowed is None else (source / name for name in allowed)):
        if not path.is_file() or '.git' in path.parts:
            continue
        name = path.name.lower()
        if name.startswith(('license', 'copying', 'notice', 'copyright')) or name == 'authors':
            relative = path.relative_to(source)
            output_path = target / relative
            output_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, output_path)


def build(engine, sdk, jobs):
    inputs = fixed_inputs(engine)
    name, revision, release = PINS[engine]
    source = ROOT / engine_pins.get(engine)['path']
    if output('git', '-C', source, 'rev-parse', 'HEAD') != revision:
        raise ValueError('Unexpected upstream pin for ' + name)
    source_state(source)
    destination = ROOT / '.build/phase3' / engine / sdk
    destination.mkdir(parents=True, exist_ok=True)
    binary_name = {'dolphin': 'libIridiumDolphin.dylib', 'azahar': 'azahar_libretro.dylib',
                   'play': 'play_libretro_ios.dylib', 'flycast': 'flycast_libretro.dylib'}[engine]
    binary = destination / binary_name
    arguments = []
    if engine == 'azahar':
        expanded, archive_files = azahar_module().prepare_source(ROOT, revision, AZAHAR_DOWNLOADS)
    embedding = generated(engine, destination)
    build_dir = destination / 'build'
    arguments = ['cmake', '-S', str(expanded if engine == 'azahar' else source), '-B', str(build_dir), '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=' + str(embedding / 'toolchain.cmake'), '-DCMAKE_OSX_SYSROOT=' + sdk,
        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
        '-DCMAKE_PROJECT_INCLUDE=' + str(ROOT / 'ci/phase3-cmake-hook.cmake'),
        '-DIRIDIUM_ROOT=' + str(ROOT), '-DIRIDIUM_PHASE3_GENERATED=' + str(embedding),
        '-DIRIDIUM_PHASE3_TARGET_HOOK=' + str(ROOT / 'ci/phase3-targets.cmake')]
    adapter = engine_module(engine)
    if engine == 'azahar':
        moltenvk_library, moltenvk_receipt = azahar_moltenvk(sdk, jobs)
        arguments += adapter.arguments(moltenvk_library)
    else:
        arguments += adapter.arguments()
    target, relative = adapter.TARGET, adapter.OUTPUT
    run(*arguments)
    if engine == 'azahar':
        azahar_module().check_compile_commands(build_dir, embedding)
    run('cmake', '--build', build_dir, '--target', target, '-j', jobs)
    shutil.copy2(build_dir / relative, binary)
    record = audit(binary, sdk, native=engine == 'dolphin')
    if fixed_inputs(engine) != inputs:
        raise ValueError('Phase 3 build inputs changed during compilation: ' + engine)
    record.update(engine=engine, sdk=sdk, revision=revision, release=release, arguments=public_arguments(arguments),
                  buildInputs=fixed_inputs(engine), sourceRevisions=source_state(source),
                  recipeSHA256=digest(Path(__file__)),
                  embedding={p.relative_to(embedding).as_posix(): digest(p) for p in embedding.rglob('*') if p.is_file()})
    bridge_sources = {'dolphin': ['IRDolphin.mm', 'IRPhase3.h', 'IRDolphinAPI.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'], 'azahar': ['IRAzaharJIT.cpp', 'IRAzaharGraphics.mm', 'IRPhase3.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
        'play': ['IRPlayProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
        'flycast': ['IRFlycastProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h']}[engine]
    record['adapterSources'] = {name: digest(BRIDGE / name) for name in bridge_sources}
    if engine == 'azahar':
        notices(expanded, destination, allowed=archive_files)
        record['moltenVK'] = moltenvk_receipt
        azahar_module().collect_licenses(ROOT, destination, moltenvk_receipt)
    else:
        notices(source, destination)
    assets = destination / 'assets'
    if assets.exists(): shutil.rmtree(assets)
    assets.mkdir(exist_ok=True)
    if engine == 'dolphin':
        shutil.copytree(source / 'Data/Sys', assets / 'Sys', dirs_exist_ok=True)
    if engine == 'play':
        shutil.copy2(source / 'GameConfig.xml', assets / 'GameConfig.xml')
    if engine == 'azahar':
        record['officialArtifacts'] = AZAHAR_DOWNLOADS
    if engine != 'host':
        commands = json.loads((build_dir / 'compile_commands.json').read_text())
        record['compiledInputs'] = {Path(item['file']).resolve().relative_to(ROOT).as_posix(): digest(Path(item['file'])) for item in commands}
    record['files'] = {p.relative_to(destination).as_posix(): digest(p)
        for folder in (assets, destination / 'licenses') for p in folder.rglob('*') if p.is_file()}
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(engine=engine, sdk=sdk, binary=str(binary), sha256=record['sha256'])), flush=True)


def host(sdk):
    inputs = fixed_inputs('host')
    destination = ROOT / '.build/phase3/host' / sdk
    destination.mkdir(parents=True, exist_ok=True)
    exports = destination / 'native.exports'; exports.write_text('\n'.join(sorted(NATIVE_EXPORTS)) + '\n')
    binary = destination / 'libIridiumRetroPlayer.dylib'
    target = 'arm64-apple-ios18.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
    arguments = ['xcrun', '--sdk', sdk, 'clang++', '-std=c++17', '-fobjc-arc', '-dynamiclib', '-O2',
        '-target', target, '-isysroot', output('xcrun', '--sdk', sdk, '--show-sdk-path'),
        '-I', ROOT / 'vendor/Flycast/core/deps/libretro-common/include', '-I', BRIDGE,
        BRIDGE / 'IRRetroPlayer.mm', BRIDGE / 'IRAudioVolume.c', '-Wl,-exported_symbols_list,' + str(exports),
        '-framework', 'UIKit', '-framework', 'AVFAudio', '-framework', 'CoreGraphics',
        '-framework', 'OpenGLES', '-framework', 'QuartzCore', '-install_name', '@rpath/' + binary.name, '-o', binary]
    run(*arguments)
    if fixed_inputs('host') != inputs:
        raise ValueError('Phase 3 host inputs changed during compilation')
    record = audit(binary, sdk, native=True)
    record.update(engine='host', sdk=sdk, buildInputs=fixed_inputs('host'), arguments=public_arguments(arguments))
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', choices=(*PINS, 'host', 'all'), default='all')
    parser.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), default='iphoneos')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 16:
        parser.error('Choose between 1 and 16 build jobs')
    if args.engine in ('all', 'host'):
        host(args.sdk)
    for engine in PINS if args.engine == 'all' else [args.engine] if args.engine != 'host' else []:
        build(engine, args.sdk, args.jobs)
