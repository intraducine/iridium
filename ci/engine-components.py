#!/usr/bin/env python3
"""Reuse audited console outputs through the existing trusted compiler artifacts."""
import argparse
import engine_pins
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'ci' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


components = load('compiled-components')
phase3 = load('build-phase3')
PSP = '.build/ppsspp/iphoneos/'
BRIDGE = 'iridium/apps/ios/RuntimeBridge/'
PATHS = {
    'psp': (PSP + 'libIridiumPPSSPPNative.dylib', PSP + 'component.json', PSP + 'assets', PSP + 'licenses',
            '.build/psp-atlas-fonts') + tuple('.build/runtime-downloads/' + item['sha256'] + '.tar'
                for item in json.loads((ROOT / engine_pins.get('ppsspp')['buildDependencies']['moltenVK']['inputs']).read_text())),
    'sameboy': tuple('.build/sameboy/iphoneos/' + name for name in
                    ('libIridiumSameBoy.a', 'SameBoyNamespace.h', 'source-manifest.json')),
}
INPUTS = {
    'psp': ('vendor/PPSSPP', 'ci/build-ppsspp-native.py', 'ci/build-ppsspp-moltenvk.py',
            'ci/build-ppsspp-atlases.py', 'ci/ppsspp-native.cmake', 'ci/ppsspp_sources.py',
            'ci/ppsspp_native_overlay.py', 'ci/ppsspp_sensor_overlay.py', 'ci/ppsspp_picker_overlay.py',
            'ci/ppsspp_callback_overlay.py', 'ci/ppsspp_frontend_overlay.py', 'ci/ppsspp_gl_sync_overlay.py',
            'ci/ppsspp_exec_overlay.py', 'ci/ppsspp_atlas_resources.py', 'ci/psp-atlas-resources.json',
            'ci/psp-atlas-inputs.json', 'ci/psp-atlas-host', engine_pins.get('ppsspp')['buildDependencies']['moltenVK']['inputs'],
            'ci/fetch-runtime-inputs.py', 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases',
            'iridium/apps/ios/RuntimeSupport/Notices/PPSSPPFonts',
            'iridium/apps/ios/MadeiraSupport/Notices/MoltenVK') + tuple(BRIDGE + name for name in
                ('IRPPSSPPNative.mm', 'IRPPSSPPNative.h', 'IRPPSSPPCodecCheck.c', 'IRJITDiagnostic.h',
                 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRPSPExecutableMemory.h',
                 'IRPSPExecutableMemory.cpp', 'IRPSPTeardownObservation.h')),
    'sameboy': ('vendor/SameBoy', 'ci/build-sameboy.py', 'ci/sameboy_bootroms.py', 'ci/sameboy-bootroms.json'),
}
for engine in ('host', *phase3.PINS):
    folder = '.build/phase3/' + engine + '/iphoneos/'
    binary = {'host': 'libIridiumRetroPlayer.dylib', 'dolphin': 'libIridiumDolphin.dylib',
              'azahar': 'azahar_libretro.dylib', 'play': 'play_libretro_ios.dylib',
              'flycast': 'flycast_libretro.dylib'}[engine]
    PATHS[engine] = (folder + binary, folder + 'component.json')
    if engine != 'host':
        PATHS[engine] += tuple(folder + name for name in ('assets', 'licenses', 'embedding'))
    if engine == 'azahar':
        PATHS[engine] += tuple('.build/phase3-downloads/' + name for name in phase3.AZAHAR_DOWNLOADS)
        PATHS[engine] += ('.build/phase3-downloads/' + phase3.azahar_module().source_archive().removesuffix('.tar.xz'),
                         '.build/azahar/moltenvk-source',
                         '.build/azahar/moltenvk-derived/package-iphoneos/component.json',
                         '.build/azahar/moltenvk-derived/package-iphoneos/Build/Products/Release-iphoneos/libMoltenVK.a')
        PATHS[engine] += tuple('.build/runtime-downloads/' + item['sha256'] + '.tar'
                              for item in json.loads((ROOT / engine_pins.get('azahar')['buildDependencies']['moltenVK']['inputs']).read_text()))
    INPUTS[engine] = (engine_pins.get(engine_pins.STAGES[engine])['path'],
                     *phase3.input_paths(engine))
for engine in INPUTS:
    INPUTS[engine] += ('ci/engine_pins.py', engine_pins.MANIFEST)
components.PATHS.update(PATHS)
# Generated compiler inputs are restored for the existing source audit, without object files.
for engine in ('host', *phase3.PINS):
    components.PATHS[engine] += ('.build/phase3/' + engine + '/iphoneos/build',)
components.reuse.COMPONENT_INPUTS.update({name: paths + ('ci/engine-components.py',)
                                        for name, paths in INPUTS.items()})


def validate(engine):
    if engine == 'sameboy':
        record = load('build-sameboy').verify_component(ROOT / '.build/sameboy/iphoneos')
        if record.get('sdk') != 'iphoneos' or record.get('target') != 'arm64-apple-ios18.0':
            raise ValueError('SameBoy platform differs')
        return record
    if engine == 'psp':
        builder = load('build-ppsspp-native')
        directory = ROOT / PSP
        record = json.loads((directory / 'component.json').read_text())
        if record.get('sdk') != 'iphoneos' or record.get('binary') != 'libIridiumPPSSPPNative.dylib':
            raise ValueError('PSP platform or binary differs')
        if record.get('enginePin') != engine_pins.selected('psp') or record.get('revision') != builder.REVISION or record.get('sourceRevisions') != builder.revisions(ROOT / 'vendor/PPSSPP'):
            raise ValueError('PSP source revisions differ')
        if builder.digest(directory / record['binary']) != record['sha256']:
            raise ValueError('PSP binary checksum differs')
        builder.audit(directory / record['binary'], 'iphoneos')
        load('madeira-frontend').check_psp_jit_interface(record)
        builder.overlay.gl_sync.validate_component(record, ROOT / 'vendor/PPSSPP')
        for name, expected in record['assetSHA256'].items():
            if builder.digest(directory / 'assets' / name) != expected:
                raise ValueError('PSP resource differs: ' + name)
        builder.atlases.locked_inputs(ROOT / 'vendor/PPSSPP')
        for item in record['moltenVK']['sourceInputs']:
            if builder.digest(ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')) != item['sha256']:
                raise ValueError('PSP corresponding source differs: ' + item['name'])
        return record
    directory = ROOT / '.build/phase3' / engine / 'iphoneos'
    record = json.loads((directory / 'component.json').read_text())
    if record.get('engine') != engine or record.get('sdk') != 'iphoneos':
        raise ValueError('Console engine or platform differs')
    phase3.verify_inputs(record)
    if engine != 'host':
        for folder in ('assets', 'licenses'):
            if not any(name.startswith(folder + '/') for name in record.get('files', {})):
                (directory / folder).mkdir(exist_ok=True)
    binary = next(name for name in PATHS[engine] if name.endswith('.dylib'))
    if phase3.audit(ROOT / binary, 'iphoneos', native=engine in ('host', 'dolphin'))['sha256'] != record['sha256']:
        raise ValueError('Console binary checksum differs: ' + engine)
    for name, expected in record.get('files', {}).items():
        if phase3.digest(directory / name) != expected:
            raise ValueError('Console resource differs: ' + name)
    return record


def compile(engine):
    if engine == 'psp':
        command = ['ci/build-ppsspp-native.py', '--output', PSP, '--sdk', 'iphoneos']
    elif engine == 'sameboy':
        command = ['ci/build-sameboy.py', '--output', '.build/sameboy/iphoneos', '--sdk', 'iphoneos',
                   '--target', 'arm64-apple-ios18.0']
    else:
        if engine == 'azahar':
            folder = ROOT / '.build/phase3-downloads'
            folder.mkdir(parents=True, exist_ok=True)
            subprocess.run(['gh', 'release', 'download', engine_pins.get('azahar')['releaseTag'],
                            '--repo', engine_pins.get('azahar')['upstream'].removeprefix('https://github.com/'),
                            '--dir', str(folder), *[arg for name in phase3.AZAHAR_DOWNLOADS
                                                   for arg in ('--pattern', name)]], check=True)
        command = ['ci/build-phase3.py', '--engine', engine, '--sdk', 'iphoneos', '--jobs', '3']
    subprocess.run([sys.executable, *command], cwd=ROOT, check=True)


def ensure(engine):
    reuse = components.reuse
    branch = os.environ['GITHUB_REF_NAME']
    run_id = reuse.select(ROOT, engine, branch) if os.environ.get('REUSE_ASSETS', 'true') == 'true' else ''
    if run_id:
        transfer = ROOT / '.build' / (engine + '-compiled-transfer')
        subprocess.run(['gh', 'run', 'download', run_id, '--repo', reuse.REPO,
                        '--name', reuse.artifact_name(engine), '--dir', str(transfer)], check=True)
        components.restore(ROOT, engine, run_id)
        validate(engine)
        print(f'{engine}: restored verified compilation from run {run_id}', flush=True)
    else:
        print(f'{engine}: no matching saved compilation; building once', flush=True)
        compile(engine)
        record = validate(engine)
        if engine in ('host', *phase3.PINS):
            generated = tuple(name for name in record.get('compiledInputs', {})
                              if Path(name).is_relative_to('.build/phase3/' + engine + '/iphoneos/build'))
            components.PATHS[engine] = PATHS[engine] + generated
        components.package(ROOT, engine)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'rebuilt={str(not bool(run_id)).lower()}\nartifact={reuse.artifact_name(engine)}\n')
    if run_id:
        shutil.rmtree(transfer)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', choices=PATHS)
    args = parser.parse_args()
    os.environ['NATIVE_TOOLCHAIN'] = hashlib.sha256(
        (os.environ['NATIVE_TOOLCHAIN'] + str(ROOT.resolve())).encode()).hexdigest()
    ensure(args.engine)
