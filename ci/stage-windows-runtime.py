#!/usr/bin/env python3
"""Stage generated Wine PE resources without copying Unix libraries or host data."""
from pathlib import Path
import shutil
import struct
import sys

SUFFIXES = {'.dll', '.exe', '.drv', '.sys', '.acm', '.cpl', '.tlb', '.ax', '.ocx', '.mui', '.rll'}
# Linked ARM64EC images commonly use AMD64's machine ID; this checks the
# container, not the hybrid-code metadata. Compiler targets are set by the recipe.
MACHINES = {'aarch64': {0xaa64, 0xa64e}, 'arm64ec': {0x8664, 0xa641, 0xa64e}}


def pe_architectures(path):
    data = path.read_bytes()
    def unpack(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise ValueError(f'Truncated PE module: {path.name}')
        return struct.unpack_from(fmt, data, offset)

    if data[:2] != b'MZ':
        raise ValueError(f'Not a PE module: {path.name}')
    pe, = unpack('<I', 60)
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError(f'Invalid PE header: {path.name}')
    machine, sections = unpack('<HH', pe + 4)
    if machine == 0xa64e:
        return {'aarch64', 'arm64ec'}
    if machine in MACHINES['arm64ec']:
        return {'arm64ec'}
    if machine != 0xaa64:
        raise ValueError(f'Unsupported PE machine: {path.name} (0x{machine:04x})')
    architectures = {'aarch64'}
    optional_size, = unpack('<H', pe + 20)
    optional = pe + 24
    # ARM64X uses the ARM64 machine ID. Its load config contains a CHPE
    # metadata pointer, identifying the additional ARM64EC code view.
    if optional_size >= 200 and unpack('<H', optional)[0] == 0x20b:
        count, = unpack('<I', optional + 108)
        if count > 10:
            rva, size = unpack('<II', optional + 192)
            if rva and size >= 208:
                for i in range(sections):
                    section = optional + optional_size + i * 40
                    va, raw_size, raw = unpack('<III', section + 12)
                    if va <= rva and rva - va + 208 <= raw_size:
                        config = raw + rva - va
                        if unpack('<I', config)[0] >= 208 and unpack('<Q', config + 200)[0]:
                            architectures.add('arm64ec')
                        break
                else:
                    raise ValueError(f'Invalid PE load config: {path.name}')
    return architectures


def check_pe(path, architecture):
    if architecture not in pe_architectures(path):
        raise ValueError(f'Wrong PE architecture: {path.name} ({architecture})')


def stage(build, app, source=None):
    seen = {}
    for architecture in MACHINES:
        (app / f'{architecture}-windows').mkdir(parents=True, exist_ok=True)
    # Wine's combined build stores ARM64X and EC-only modules under
    # aarch64-windows. Route by the image, not that output directory.
    for group in ['dlls', 'programs']:
        for path in sorted((build / group).glob('*/*-windows/*')):
            if path.parent.name not in {f'{a}-windows' for a in MACHINES}:
                continue
            if not path.is_file() or path.suffix.lower() not in SUFFIXES:
                continue
            architectures = MACHINES if path.suffix.lower() == '.tlb' else pe_architectures(path)
            for architecture in architectures:
                key = (architecture, path.name.casefold())
                if key in seen:
                    if path.samefile(seen[key]):
                        continue
                    raise ValueError(f'Duplicate Windows resource: {path.name}')
                seen[key] = path
                shutil.copyfile(path, app / f'{architecture}-windows' / path.name)
    for architecture in MACHINES:
        check_pe(app / f'{architecture}-windows/ntdll.dll', architecture)
    for folder, suffix in [('nls', '*.nls'), ('fonts', '*.ttf')]:
        # Wine ships prebuilt TTFs in source; generated fonts take precedence.
        files = {p.name: p for p in (source / folder).glob(suffix)} if source and folder == 'fonts' else {}
        files.update({p.name: p for p in (build / folder).glob(suffix)})
        if not files:
            raise ValueError(f'Wine build did not produce {folder}')
        (app / folder).mkdir(exist_ok=True)
        for path in files.values():
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
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        check(Path(sys.argv[2]))
    elif len(sys.argv) == 4:
        stage(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise SystemExit('usage: stage-windows-runtime.py BUILD APP SOURCE | --check APP')
