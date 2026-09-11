#!/usr/bin/env python3
"""Stage generated Wine PE resources without copying Unix libraries or host data."""
from pathlib import Path
import shutil
import struct
import sys

SUFFIXES = {'.dll', '.exe', '.drv', '.sys', '.acm', '.cpl', '.tlb', '.ax', '.ocx', '.mui', '.rll'}
# Linked ARM64EC images commonly use AMD64's machine ID; this checks the
# container, not the hybrid-code metadata. Compiler targets are set by the recipe.
MACHINES = {'aarch64': {0xaa64}, 'arm64ec': {0x8664, 0xa641, 0xa64e}}


def check_pe(path, architecture):
    with path.open('rb') as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:2] != b'MZ':
            raise ValueError(f'Not a PE module: {path.name}')
        stream.seek(struct.unpack_from('<I', header, 0x3c)[0])
        signature = stream.read(6)
    if len(signature) != 6 or signature[:4] != b'PE\0\0':
        raise ValueError(f'Invalid PE header: {path.name}')
    if struct.unpack_from('<H', signature, 4)[0] not in MACHINES[architecture]:
        raise ValueError(f'Wrong PE architecture: {path.name} ({architecture})')


def stage(build, app):
    for architecture in MACHINES:
        folder = f'{architecture}-windows'
        destination = app / folder
        destination.mkdir(parents=True, exist_ok=True)
        seen = set()
        for group in ['dlls', 'programs']:
            for path in sorted((build / group).glob(f'*/{folder}/*')):
                if path.is_file() and path.suffix.lower() in SUFFIXES:
                    if path.name.casefold() in seen:
                        raise ValueError(f'Duplicate Windows resource: {path.name}')
                    seen.add(path.name.casefold())
                    if path.suffix != '.tlb':
                        check_pe(path, architecture)
                    shutil.copyfile(path, destination / path.name)
        check_pe(destination / 'ntdll.dll', architecture)
    for folder, suffix in [('nls', '*.nls'), ('fonts', '*.ttf')]:
        files = list((build / folder).glob(suffix))
        if not files:
            raise ValueError(f'Wine build did not produce {folder}')
        (app / folder).mkdir(exist_ok=True)
        for path in files:
            shutil.copyfile(path, app / folder / path.name)


def check(app):
    for architecture in MACHINES:
        for name in ['ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'user32.dll', 'd3d11.dll', 'dxgi.dll', 'winemetal.dll']:
            check_pe(app / f'{architecture}-windows' / name, architecture)
    check_pe(app / 'arm64ec-windows/xtajit64.dll', 'arm64ec')
    for path in ['prefix-template.tar.gz', 'nls/l_intl.nls']:
        if not (app / path).is_file() or not (app / path).stat().st_size:
            raise ValueError(f'Missing runtime resource: {path}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: stage-windows-runtime.py BUILD APP | --check APP')
    if sys.argv[1] == '--check':
        check(Path(sys.argv[2]))
    else:
        stage(Path(sys.argv[1]), Path(sys.argv[2]))
