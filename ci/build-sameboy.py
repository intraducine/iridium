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

def build_input_hashes():
    paths = [CORE / 'version.mk', CORE / 'LICENSE', CORE / 'Makefile', CORE / 'libretro/Makefile', CORE / 'libretro/Makefile.common',
             ROOT / 'ci/build-sameboy.py', ROOT / 'ci/sameboy_bootroms.py',
             ROOT / 'ci/sameboy-bootroms.json']
    paths += [p for directory in ('Core', 'libretro', 'BootROMs')
              for p in sorted((CORE / directory).rglob('*')) if p.is_file()
              and (p.suffix in {'.c', '.h', '.inc', '.asm', '.png'} or p.name == 'Makefile')]
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def verify_component(folder):
    folder = Path(folder)
    record = json.loads((folder / 'source-manifest.json').read_text())
    if (record.get('revision') != REVISION or record.get('buildInputSHA256') != build_input_hashes()
            or record.get('archiveSHA256') != hashlib.sha256((folder / 'libIridiumSameBoy.a').read_bytes()).hexdigest()
            or record.get('namespaceSHA256') != hashlib.sha256((folder / 'SameBoyNamespace.h').read_bytes()).hexdigest()):
        raise ValueError('Rebuild SameBoy from the matching pinned source and recipe')
    return record


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
    compiler = run([cc, '--version']).strip()
    sdk_build = run(['xcrun', '--sdk', sdk, '--show-sdk-build-version']).strip() if sdk else None
    try:
        previous = verify_component(output)
        if (previous.get('sdk') == sdk and previous.get('target') == target
                and previous.get('compiler') == compiler and previous.get('platformFlags') == platform
                and previous.get('sdkBuildVersion') == sdk_build):
            print('Reusing verified SameBoy:', output / 'libIridiumSameBoy.a')
            return output / 'libIridiumSameBoy.a'
    except (OSError, ValueError, KeyError):
        pass
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
        if not path.is_file():
            raise ValueError('Missing core source: ' + str(path))
        sources.append(path)
    if len(sources) != 21:
        raise ValueError('Pinned core source list changed')
    version = re.fullmatch(r'VERSION := ([0-9.]+)\s*', (CORE / 'version.mk').read_text()).group(1)
    copyright_year = re.search(r'20[2-9][0-9]', (CORE / 'LICENSE').read_text()).group(0)
    flags = platform + ['-std=gnu11', '-O2', '-fPIC', '-fvisibility=hidden', '-D_GNU_SOURCE',
        '-D_USE_MATH_DEFINES', '-D__LIBRETRO__', '-DGB_INTERNAL', '-DNDEBUG', '-DGB_VERSION="' + version + '"',
        '-DGB_COPYRIGHT_YEAR="' + copyright_year + '"',
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
        'compiler': compiler, 'platformFlags': platform, 'sdkBuildVersion': sdk_build,
        'audioRate': 'frontend RETRO_ENVIRONMENT_GET_TARGET_SAMPLE_RATE',
        'compilerFlags': [flag.replace(str(ROOT), '$IRIDIUM_SOURCE') for flag in flags],
        'adapterSHA256': hashlib.sha256((CORE / 'libretro/libretro.c').read_bytes()).hexdigest(),
        'buildInputSHA256': build_input_hashes(),
        'namespaceSHA256': hashlib.sha256(namespace.read_bytes()).hexdigest(),
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
