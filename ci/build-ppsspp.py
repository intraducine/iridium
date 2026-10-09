#!/usr/bin/env python3
"""Build an isolated pinned PSP component using the upstream Apple recipe."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REVISION = '35e27933ff28bffcf1eadce0574569958d14c9b9'
DEPENDENCIES = (
    'libretro/libretro-common', 'ext/SPIRV-Cross', 'ext/armips', 'ext/glslang',
    'ext/cpu_features', 'ext/libchdr', 'ext/lua', 'ext/nanosvg', 'ext/rapidjson',
    'ext/rcheevos', 'ext/zstd', 'ext/aemu_postoffice', 'ext/OpenXR-SDK', 'ext/miniupnp',
)
NESTED = ('ext/armips', 'ext/filesystem')
EXPORTS = {'_ir_ppsspp_boot_pending', *('_retro_' + name for name in (
    'set_environment', 'set_video_refresh', 'set_audio_sample', 'set_audio_sample_batch',
    'set_input_poll', 'set_input_state', 'init', 'deinit', 'api_version', 'get_system_info',
    'get_system_av_info', 'set_controller_port_device', 'reset', 'run', 'serialize_size',
    'serialize', 'unserialize', 'cheat_reset', 'cheat_set', 'load_game', 'load_game_special',
    'unload_game', 'get_region', 'get_memory_data', 'get_memory_size'))}
SYSTEM_LIBRARIES = {
    '/usr/lib/libobjc.A.dylib', '/usr/lib/libz.1.dylib', '/usr/lib/libc++.1.dylib',
    '/usr/lib/libSystem.B.dylib', '/System/Library/Frameworks/OpenGLES.framework/OpenGLES',
}
ASSETS = ('compat.ini', 'ppge_atlas.meta', 'ppge_atlas.zim', 'langregion.ini',
          'flash0/font/jpn0.pgf', 'flash0/font/kr0.pgf',
          *(f'flash0/font/ltn{i}.pgf' for i in range(16)),
          *(f'lang/{locale}.ini' for locale in ('en_US', 'ja_JP', 'fr_FR', 'de_DE', 'es_ES',
                                              'it_IT', 'pt_PT', 'ru_RU', 'nl_NL', 'ko_KR', 'zh_TW', 'zh_CN')))


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def revisions(source):
    """Validate selected pins without recursively fetching unused SDKs."""
    if not (source / '.git').exists():
        saved = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())
        prefix = source.relative_to(ROOT).as_posix()
        if saved.get(prefix) != REVISION:
            raise ValueError('Source package has a different PPSSPP revision')
        required = [*DEPENDENCIES, '/'.join(NESTED)]
        if any(not (source / name).is_dir() or not saved.get(prefix + '/' + name) for name in required):
            raise ValueError('Source package is missing a selected PPSSPP dependency')
        return {'.': REVISION, **{name: saved[prefix + '/' + name] for name in required}}
    actual = output('git', '-C', source, 'rev-parse', 'HEAD')
    if actual != REVISION:
        raise ValueError('Review the component before changing its source pin')
    result = {'.': actual}
    for relative in DEPENDENCIES:
        expected = output('git', '-C', source, 'rev-parse', 'HEAD:' + relative)
        child = source / relative
        if not (child / '.git').exists() or output('git', '-C', child, 'rev-parse', 'HEAD') != expected:
            raise ValueError('Missing or wrong PPSSPP dependency: ' + relative)
        result[relative] = expected
    parent, relative = NESTED
    expected = output('git', '-C', source / parent, 'rev-parse', 'HEAD:' + relative)
    child = source / parent / relative
    if not (child / '.git').exists() or output('git', '-C', child, 'rev-parse', 'HEAD') != expected:
        raise ValueError('Missing or wrong armips filesystem dependency')
    result[parent + '/' + relative] = expected
    for name in result:
        # Compiler outputs are out-of-tree. Every tracked dependency source stays unchanged.
        if output('git', '-C', source / name, 'diff', '--name-only', '--ignore-submodules=all', 'HEAD'):
            raise ValueError('Pinned component source has edits: ' + name)
    return result


def initialize(source):
    if output('git', '-C', source, 'rev-parse', 'HEAD') != REVISION or output(
            'git', '-C', source, 'diff', '--name-only', 'HEAD', '--', '.gitmodules'):
        raise ValueError('Initialize only the reviewed, unmodified dependency recipe')
    subprocess.run(['git', '-C', str(source), 'submodule', 'update', '--init', *DEPENDENCIES], check=True)
    subprocess.run(['git', '-C', str(source / NESTED[0]), 'submodule', 'update', '--init', NESTED[1]], check=True)


def configure(source, destination, sdk, cmake='cmake'):
    if sdk not in ('iphoneos', 'iphonesimulator'):
        raise ValueError('Choose an explicit Apple mobile SDK')
    return [cmake, '-S', str(source), '-B', str(destination / 'build'), '-G', 'Ninja',
            '-DCMAKE_TOOLCHAIN_FILE=' + str(source / 'cmake/Toolchains/ios.cmake'),
            '-DIOS_PLATFORM=' + ('OS' if sdk == 'iphoneos' else 'SIMULATOR'),
            '-DCMAKE_OSX_ARCHITECTURES=arm64',
            '-DCMAKE_OSX_SYSROOT=' + output('xcrun', '--sdk', sdk, '--show-sdk-path'),
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
            '-DLIBRETRO=ON', '-DHEADLESS=OFF', '-DUNITTEST=OFF', '-DATLAS_TOOL=OFF',
            '-DUSE_DISCORD=OFF', '-DUSE_MINIUPNPC=OFF', '-DUSE_FFMPEG=OFF',
            '-DBUILD_BUNDLED_FFMPEG=OFF', '-DUSE_WAYLAND_WSI=OFF', '-DUSING_X11_VULKAN=OFF',
            '-DUSE_SYSTEM_LIBPNG=OFF', '-DUSE_SYSTEM_ZSTD=OFF',
            '-DCMAKE_PROJECT_PPSSPP_INCLUDE=' + str(ROOT / 'ci/ppsspp-adapter.cmake'),
            '-DIRIDIUM_PSP_ADAPTER=' + str(ROOT / 'iridium/apps/ios/RuntimeBridge/IridiumPPSSPPAdapter.cpp'),
            '-DIRIDIUM_PSP_EXPORTS=' + str(ROOT / 'ci/ppsspp-exports.apple')]


def audit(binary, sdk):
    if output('xcrun', 'lipo', '-archs', binary).split() != ['arm64']:
        raise ValueError('The PSP component must contain exactly the selected arm64 slice')
    symbols = set(output('xcrun', 'nm', '-gjU', binary).splitlines())
    if symbols != EXPORTS:
        raise ValueError('Unexpected PSP exports; native C++ internals must remain isolated')
    ids = output('xcrun', 'otool', '-D', binary).splitlines()[1:]
    if ids != ['@rpath/ppsspp_libretro.dylib']:
        raise ValueError('Unexpected PSP component install name')
    dependencies = {line.strip().split(' (', 1)[0]
                    for line in output('xcrun', 'otool', '-L', binary).splitlines()[1:]}
    dependencies.discard('@rpath/ppsspp_libretro.dylib')
    if not dependencies or not dependencies <= SYSTEM_LIBRARIES:
        raise ValueError('PSP component links an unreviewed non-system dependency')
    build = output('xcrun', 'vtool', '-show-build', binary)
    expected = 'IOS' if sdk == 'iphoneos' else 'IOSSIMULATOR'
    platform = re.findall(r'^\s*platform\s+(\S+)', build, re.M)
    if platform != [expected]:
        raise ValueError('The component platform differs from its requested SDK')
    minimum = re.findall(r'^\s*minos\s+(\S+)', build, re.M)
    return {'exports': sorted(symbols), 'dependencies': sorted(dependencies),
            'platform': expected, 'minimumOS': minimum[0] if len(minimum) == 1 else None,
            'installName': ids[0], 'sha256': digest(binary), 'sizeBytes': binary.stat().st_size}


def assets(source, destination):
    if destination.is_symlink():
        raise ValueError('Generated assets cannot use a symbolic-link directory')
    expected = set(ASSETS)
    existing = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file()}
    if existing - expected:
        raise ValueError('Unexpected files in generated PSP assets; use a fresh output directory')
    hashes = {}
    for name in ASSETS:
        origin = source / 'assets' / name
        target = destination / name
        if any(parent.is_symlink() for parent in target.parents if parent != destination.parent):
            raise ValueError('Generated asset parent is a symbolic link')
        if origin.is_symlink() or not origin.is_file() or not origin.stat().st_size:
            raise ValueError('Missing or unsafe pinned PSP asset: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise ValueError('Generated asset cannot overwrite a symbolic link')
        shutil.copy2(origin, target)
        hashes[name] = digest(target)
    return hashes


def notices(source, destination):
    """Retain upstream terms and embedded source notices; source delivery is separate."""
    destination.mkdir(parents=True, exist_ok=True)
    terms = {
        'PPSSPP-LICENSE.TXT': source / 'LICENSE.TXT',
        'GPL-3.0.txt': ROOT / 'vendor/Madeira/COPYING',
        'LGPL-2.1.txt': ROOT / 'iridium/apps/ios/MadeiraSupport/Notices/Media/ffmpeg-7.1/COPYING.LGPLv2.1',
    }
    for name, path in terms.items():
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing required license text: ' + name)
        shutil.copy2(path, destination / name)
    chunks = ['PPSSPP source attribution at ' + REVISION + '\n'
              'This inventory retains source notices, including some unused implementation files.\n'
              'The component manifest identifies the selected dependencies and actual compiled inputs.\n']
    roots = [source / name for name in ('Common', 'Core', 'GPU', 'libretro', 'ext')]
    for base in roots:
        for path in sorted(base.rglob('*')):
            if '.git' in path.parts or path.is_symlink() or not path.is_file():
                continue
            name = path.name.lower()
            if name.startswith(('license', 'copying', 'notice')) and path.stat().st_size <= 256 * 1024:
                content = path.read_text(errors='replace')
            elif path.suffix in ('.c', '.cpp', '.cc', '.h', '.hpp'):
                # Leading comment blocks contain the original per-file grants;
                # never rewrite them into a guessed common SPDX identifier.
                with path.open(errors='replace') as stream:
                    prefix = stream.read(16384).lstrip('\ufeff\r\n ')
                match = re.match(r'(?:(?:/\*.*?\*/|//[^\n]*(?:\n|$))\s*)+', prefix, re.S)
                content = match.group(0) if match else ''
                if not re.search(r'copyright|licen[sc]e|permission', content, re.I):
                    continue
            else:
                continue
            chunks.append('\n--- ' + path.relative_to(source).as_posix() + ' ---\n' + content)
    (destination / 'SOURCE-NOTICES.txt').write_text('\n'.join(chunks))


def compiled_inputs(source, destination):
    records = json.loads((destination / 'build/compile_commands.json').read_text())
    hashes = {}
    companion = (ROOT / 'iridium/apps/ios/RuntimeBridge/IridiumPPSSPPAdapter.cpp').resolve()
    for record in records:
        command = record.get('arguments') or shlex.split(record['command'])
        if '-o' not in command:
            raise ValueError('Compiler inventory has no object output')
        obj = Path(record['directory']) / command[command.index('-o') + 1]
        if not obj.is_file():
            continue  # Configured but unused targets are not actual build inputs.
        path = Path(record['file']).resolve(strict=True)
        if path == companion:
            name = 'Iridium/IridiumPPSSPPAdapter.cpp'
        elif path.is_relative_to(source):
            name = 'PPSSPP/' + path.relative_to(source).as_posix()
        elif path.is_relative_to(destination / 'build'):
            name = 'generated/' + path.relative_to(destination / 'build').as_posix()
        else:
            raise ValueError('Compiler input is outside the reviewed component and adapter')
        hashes[name] = digest(path)
    if not hashes or 'Iridium/IridiumPPSSPPAdapter.cpp' not in hashes:
        raise ValueError('The component compile inventory is incomplete')
    return hashes


def build(source, destination, sdk, jobs=4, cmake='cmake'):
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('Build outputs must stay outside the upstream checkout')
    before = revisions(source)
    destination.mkdir(parents=True, exist_ok=True)
    command = configure(source, destination, sdk, cmake)
    subprocess.run(command, check=True)
    subprocess.run([cmake, '--build', str(destination / 'build'), '--target', 'ppsspp_libretro',
                    '--parallel', str(jobs)], check=True)
    binary = destination / 'build/lib/ppsspp_libretro.dylib'
    record = audit(binary, sdk)
    if revisions(source) != before:
        raise ValueError('The upstream source changed during compilation')
    header = source / 'libretro/libretro-common/include/libretro.h'
    include = destination / 'include'
    include.mkdir(exist_ok=True)
    shutil.copy2(header, include / 'IridiumPSPAPI.h')
    shutil.copy2(binary, destination / binary.name)
    asset_hashes = assets(source, destination / 'assets')
    notices(source, destination / 'licenses')
    def portable(arg):
        for path, label in ((source, '$PPSSPP_SOURCE'), (destination, '$COMPONENT_OUTPUT'), (ROOT, '$IRIDIUM_SOURCE')):
            arg = arg.replace(str(path), label)
        return arg
    record.update(revision=REVISION, sourceRevisions=before, sdk=sdk,
                  sdkVersion=output('xcrun', '--sdk', sdk, '--show-sdk-version'),
                  apiHeaderSHA256=digest(header),
                  adapterSHA256=digest(ROOT / 'iridium/apps/ios/RuntimeBridge/IridiumPPSSPPAdapter.cpp'),
                  compiler=output('xcrun', '--sdk', sdk, 'clang', '--version'),
                  cmakeVersion=output(cmake, '--version').splitlines()[0],
                  configureArguments=[portable(arg) for arg in command[1:]],
                  sourceModified=False if (source / '.git').exists() else None,
                  compiledInputSHA256=compiled_inputs(source, destination), assetSHA256=asset_hashes,
                  mode='software renderer; IR interpreter; native JIT not advertised')
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print('Built and audited the isolated PSP component:', destination / binary.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'vendor/PPSSPP')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), default='iphoneos')
    parser.add_argument('--initialize', action='store_true')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error('Use between 1 and 16 compiler workers')
    if args.initialize:
        initialize(args.source)
    else:
        if args.output is None:
            parser.error('--output is required for compilation')
        if sys.platform != 'darwin':
            parser.error('Apple component compilation requires existing Xcode tools')
        build(args.source, args.output, args.sdk, args.jobs)
