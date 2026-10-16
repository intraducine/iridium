#!/usr/bin/env python3
"""Build the pinned interpreter core, with private symbols, without a frontend."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from sameboy_bootroms import REVISION, read_bootroms

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'vendor/SameBoy'
PREFIX = 'iridium_sb_'
AUDIO_RATE = 48000


def audio_adapter(source):
    # This is a frontend setting through the public Core API, not an APU patch.
    # Never define another platform's macro to select its audio configuration.
    original = 'GB_set_sample_rate(&gameboy[i], GB_get_clock_rate(&gameboy[i]) / 2);'
    if source.count(original) != 1:
        raise ValueError('Pinned Libretro audio adapter changed')
    return source.replace(original, f'GB_set_sample_rate(&gameboy[i], {AUDIO_RATE});')


def run(argv, **kwargs):
    return subprocess.check_output([str(x) for x in argv], text=True, **kwargs)


def verify_source():
    if (ROOT / '.git').exists():
        if run(['git', '-C', CORE, 'rev-parse', 'HEAD']).strip() != REVISION:
            raise ValueError('Unexpected SameBoy revision')
        if run(['git', '-C', CORE, 'status', '--porcelain', '--untracked-files=no']).strip():
            raise ValueError('Preserve modified SameBoy source before building')
    else:
        if json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text()).get('vendor/SameBoy') != REVISION:
            raise ValueError('Missing pinned SameBoy source in source archive')


def defined_symbols(nm, objects, apple):
    symbols = set()
    for obj in objects:
        for line in run([nm, '-g', str(obj)]).splitlines():
            fields = line.split()
            if len(fields) != 3 or fields[-2].upper() == 'U':
                continue
            name = fields[-1]
            if apple:
                if not name.startswith('_'):
                    raise ValueError('Unexpected native symbol: ' + name)
                name = name[1:]
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name):
                raise ValueError('Unsupported core symbol: ' + name)
            symbols.add(name)
    return symbols


def build(output, sdk=None, target=None):
    verify_source()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    apple = sdk is not None or sys.platform == 'darwin'
    if sdk is not None:
        if not target:
            raise ValueError('Apple builds need an explicit target triple')
        cc = run(['xcrun', '--sdk', sdk, '--find', 'clang']).strip()
        nm = run(['xcrun', '--find', 'nm']).strip()
        ar = run(['xcrun', '--find', 'ar']).strip()
        platform = ['-target', target, '-isysroot', run(['xcrun', '--sdk', sdk, '--show-sdk-path']).strip()]
    else:
        cc, nm, ar = os.environ.get('CC', 'cc'), 'nm', 'ar'
        platform = []
    # The official core has its own complete Libretro adapter. No RetroArch or
    # libretro-common implementation is required by this pinned release.
    boots = read_bootroms(CORE)
    recipe = (CORE / 'libretro/Makefile.common').read_text()
    source_names = re.findall(r'\$\(CORE_DIR\)/([^\s\\]+\.c)', recipe)
    sources = []
    for relative in source_names:
        path = CORE / relative
        if re.fullmatch(r'libretro/(dmg|cgb|cgb0|mgb|agb|sgb|sgb2)_boot\.c', relative):
            model = Path(relative).stem
            data = boots[model.removesuffix('_boot')]
            path = output / (model + '.c')
            path.write_text('const unsigned char ' + model + '[] = {' + ','.join(map(str, data)) + '};\n'
                            + 'const unsigned ' + model + '_length = ' + str(len(data)) + ';\n')
        if relative == 'libretro/libretro.c':
            adapted = audio_adapter(path.read_text())
            path = output / 'libretro.c'
            path.write_text(adapted)
        if not path.is_file():
            raise ValueError('Missing core source: ' + str(path))
        sources.append(path)
    if len(sources) != 21:
        raise ValueError('Pinned core source list changed')
    version = re.fullmatch(r'VERSION := ([0-9.]+)\s*', (CORE / 'version.mk').read_text()).group(1)
    flags = platform + ['-std=gnu11', '-O2', '-fPIC', '-fvisibility=hidden', '-D_GNU_SOURCE',
        '-D_USE_MATH_DEFINES', '-D__LIBRETRO__', '-DGB_INTERNAL', '-DGB_VERSION="' + version + '"',
        '-DGB_DISABLE_TIMEKEEPING', '-DGB_DISABLE_REWIND', '-DGB_DISABLE_DEBUGGER', '-DGB_DISABLE_CHEATS',
        '-I' + str(CORE), '-I' + str(CORE / 'libretro')]

    def compile_pass(folder, extra):
        folder.mkdir(exist_ok=True)
        objects = [folder / (str(i) + '.o') for i in range(len(sources))]
        def compile_one(item):
            source, obj = item
            subprocess.run([cc, *flags, *extra, '-c', str(source), '-o', str(obj)], check=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(os.cpu_count() or 2, 8)) as pool:
            list(pool.map(compile_one, zip(sources, objects)))
        return objects

    # Visibility alone does not avoid duplicate definitions in a static link.
    # Discover every defined C symbol, then rebuild with a private namespace.
    probe = compile_pass(output / 'probe', [])
    public = defined_symbols(nm, probe, apple)
    if 'retro_run' not in public:
        raise ValueError('Core entry points missing')
    namespace = output / 'SameBoyNamespace.h'
    namespace.write_text('/* Generated from the pinned core; do not edit. */\n#pragma once\n' +
                         ''.join('#define ' + name + ' ' + PREFIX + name + '\n' for name in sorted(public)))
    objects = compile_pass(output / 'objects', ['-include', str(namespace)])
    actual = defined_symbols(nm, objects, apple)
    if actual != {PREFIX + name for name in public}:
        raise ValueError('Core has unisolated native symbols')
    temporary = output / 'libIridiumSameBoy.new.a'
    if temporary.exists():
        temporary.unlink()
    subprocess.run([ar, 'rcs', str(temporary), *map(str, objects)], check=True)
    archive = output / 'libIridiumSameBoy.a'
    temporary.replace(archive)
    (output / 'source-manifest.json').write_text(json.dumps({
        'revision': REVISION, 'version': version, 'sourceCount': len(sources),
        'definedSymbols': len(actual), 'jit': False, 'sdk': sdk, 'target': target,
        'audioRate': AUDIO_RATE,
        'adapterSHA256': hashlib.sha256((output / 'libretro.c').read_bytes()).hexdigest(),
        'bootROMs': {name: hashlib.sha256(data).hexdigest() for name, data in boots.items()},
        'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest()}, indent=2) + '\n')
    print(archive)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default=str(ROOT / '.build/sameboy'))
    parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator', 'macosx'])
    parser.add_argument('--target')
    args = parser.parse_args()
    build(args.output, args.sdk, args.target)
