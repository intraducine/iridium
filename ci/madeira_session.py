"""Build the replaceable Madeira adapter's Windows session launcher."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import engine_pins

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('iridium/apps/ios/App/Adapters/Madeira/Session')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(root=ROOT):
    records = {str(SOURCE / name): digest(root / SOURCE / name)
               for name in ('IRWindowsLauncher.c', 'IRWindowsSession.h')}
    records['ci/madeira_session.py'] = digest(root / 'ci/madeira_session.py')
    return records


def toolchain(root=ROOT):
    return next(item for item in json.loads((root / 'ci/runtime-inputs.json').read_text()) if item['name'] == 'llvm-mingw')


def build(destination, root=ROOT):
    engine = root / engine_pins.get('madeira')['path']
    compiler_pin = toolchain(root)
    folder = compiler_pin['destination'].replace('testrepos/Madeira/', engine_pins.get('madeira')['path'] + '/', 1)
    compiler = root / folder / 'bin/x86_64-w64-mingw32-clang'
    if not compiler.is_file():
        raise ValueError('Prepare the pinned Madeira cross compiler before building the session adapter')
    (root / '.build').mkdir(exist_ok=True)
    before = inputs(root)
    with tempfile.TemporaryDirectory(prefix='madeira-session-', dir=root / '.build') as temporary:
        output = Path(temporary)
        binary = output / 'iridium-session.exe'
        subprocess.run([str(compiler), '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-municode', '-mwindows', '-static', '-Wl,--strip-all', '-Wl,--no-insert-timestamp',
                        '-o', str(binary), str(root / SOURCE / 'IRWindowsLauncher.c')], check=True)
        if inputs(root) != before: raise ValueError('Madeira session inputs changed during compilation')
        record = {'protocol': 1, 'enginePin': engine_pins.selected('madeira-native'),
                  'sources': before, 'toolchainSHA256': compiler_pin['sha256'], 'sha256': digest(binary)}
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, destination / binary.name)
        (destination / 'iridium-session.json').write_text(json.dumps(record, sort_keys=True) + '\n')
        # The launcher statically links the same pinned MinGW runtime as Madeira Dock.
        notices = engine / 'app/Madeira/arm64ec-windows/dock-notices.txt'
        if not notices.is_file(): raise ValueError('Madeira cross-compiler runtime notices are missing')
        shutil.copy2(notices, destination / 'iridium-session-notices.txt')
        verify(destination, root)


def verify(destination, root=ROOT):
    record = json.loads((destination / 'iridium-session.json').read_text())
    binary = (destination / 'iridium-session.exe').read_bytes()
    offset = int.from_bytes(binary[0x3c:0x40], 'little')
    if (len(binary) < offset + 94 or binary[offset:offset+4] != b'PE\0\0'
            or int.from_bytes(binary[offset+4:offset+6], 'little') != 0x8664
            or int.from_bytes(binary[offset+92:offset+94], 'little') != 2):
        raise ValueError('Madeira session launcher must be a Windows x64 GUI-subsystem executable')
    if (record.get('protocol') != 1 or record.get('enginePin') != engine_pins.selected('madeira-native')
            or record.get('toolchainSHA256') != toolchain(root)['sha256']
            or record.get('sources') != inputs(root) or record.get('sha256') != digest(destination / 'iridium-session.exe')
            or not (destination / 'iridium-session-notices.txt').is_file()):
        raise ValueError('Madeira session adapter differs from its source or runtime pin')
