# SPDX-License-Identifier: AGPL-3.0-only
"""Console engine app staging/audits, separate from Madeira compiler inputs."""
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


def stage_phase3(app, refresh_generated_tree):
    spec = importlib.util.spec_from_file_location('phase3_builder', ROOT / 'ci/build-phase3.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    for engine, name in [('host', 'libIridiumRetroPlayer.dylib'), ('dolphin', 'libIridiumDolphin.dylib'),
                         ('azahar', 'azahar_libretro.dylib'), ('play', 'play_libretro_ios.dylib'), ('flycast', 'flycast_libretro.dylib')]:
        directory = ROOT / '.build/phase3' / engine / 'iphoneos'
        record = json.loads((directory / 'component.json').read_text())
        builder.verify_inputs(record)
        binary = directory / name
        audited = builder.audit(binary, 'iphoneos', native=engine in ('host', 'dolphin'))
        if audited['sha256'] != record.get('sha256'): raise ValueError('Console engine binary differs: ' + engine)
        for source, expected in record.get('adapterSources', {}).items():
            if builder.digest(RUNTIME_BRIDGE / source) != expected: raise ValueError('Console engine adapter is stale: ' + engine)
        if engine == 'host': continue
        if record.get('revision') != builder.PINS[engine][1]: raise ValueError('Console engine source pin differs')
        for path, expected in record['files'].items():
            if builder.digest(directory / path) != expected: raise ValueError('Console engine resource differs: ' + path)
        refresh_generated_tree(directory / 'assets', app / 'Phase3' / engine)
        refresh_generated_tree(directory / 'licenses', app / 'licenses/Phase3' / engine)
        if engine == 'play': shutil.copy2(directory / 'assets/GameConfig.xml', app / 'GameConfig.xml')


def check_phase3_bundle(app, revisions):
    spec = importlib.util.spec_from_file_location('phase3_bundle', ROOT / 'ci/build-phase3.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    if revisions != {engine: pin[1] for engine, pin in builder.PINS.items()}:
        raise ValueError('Console engine packaged revision metadata differs')
    for engine, name in [('host', 'libIridiumRetroPlayer.dylib'), ('dolphin', 'libIridiumDolphin.dylib'),
                         ('azahar', 'azahar_libretro.dylib'), ('play', 'play_libretro_ios.dylib'), ('flycast', 'flycast_libretro.dylib')]:
        directory = ROOT / '.build/phase3' / engine / 'iphoneos'
        record = json.loads((directory / 'component.json').read_text())
        builder.verify_inputs(record)
        binary = app / 'Frameworks' / name
        if binary.is_symlink() or not binary.is_file() or builder.digest(binary) != record['sha256']:
            raise ValueError('Console engine packaged binary differs: ' + engine)
        builder.audit(binary, 'iphoneos', native=engine in ('host', 'dolphin'))
        for name, expected in record.get('files', {}).items():
            folder, relative = name.split('/', 1)
            target = app / ('Phase3/' + engine if folder == 'assets' else 'licenses/Phase3/' + engine) / relative
            if target.is_symlink() or not target.is_file() or builder.digest(target) != expected:
                raise ValueError('Console engine packaged resource differs: ' + name)
            if folder == 'assets' and engine in ('dolphin', 'play'):
                root_copy = app / relative
                if root_copy.is_symlink() or not root_copy.is_file() or builder.digest(root_copy) != expected:
                    raise ValueError('Upstream root resource differs: ' + relative)
