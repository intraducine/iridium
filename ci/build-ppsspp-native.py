#!/usr/bin/env python3
"""Build the release-pinned native PPSSPP iOS player and complete resources."""
import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import ppsspp_native_overlay as overlay

ROOT = Path(__file__).resolve().parents[1]
REVISION = overlay.REVISION
RELEASE = 'v1.20.4'
EXTRA_DEPENDENCIES = ('ffmpeg', 'ios/MoltenVK', 'ext/naett', 'ext/discord-rpc', 'ext/freetype', 'assets/debugger')
import ppsspp_sources as support
NATIVE = ROOT / 'iridium/apps/ios/RuntimeBridge'
EXPORTS = {'_ir_native_psp_' + n for n in ('abi', 'create', 'pause', 'resume', 'menu', 'stop', 'restart', 'frames')}


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(binary, sdk):
    symbols = set(output('xcrun', 'nm', '-gUj', binary).splitlines())
    if symbols != EXPORTS:
        raise ValueError('Native component export boundary differs: ' + str(symbols ^ EXPORTS))
    platform = output('xcrun', 'vtool', '-show-build', binary)
    expected = 'IOSSIMULATOR' if sdk == 'iphonesimulator' else 'IOS'
    if re.findall(r'platform\s+(\w+)', platform) != [expected]:
        raise ValueError('Native PSP platform differs from its SDK')
    if output('xcrun', 'lipo', '-archs', binary) != 'arm64':
        raise ValueError('Unexpected native PSP architecture')
    identity = '@rpath/libIridiumPPSSPPNative.dylib'
    if output('xcrun', 'otool', '-D', binary).splitlines()[1:] != [identity]:
        raise ValueError('Native PSP install name differs')
    libraries = [line.strip().split(' (', 1)[0] for line in output('xcrun', 'otool', '-L', binary).splitlines()[1:]]
    if any(lib != identity and not lib.startswith(('/System/Library/Frameworks/', '/usr/lib/')) for lib in libraries):
        raise ValueError('Native PSP has an unreviewed dynamic dependency')
    return {'exports': sorted(symbols), 'platform': expected, 'dynamicLibraries': libraries,
            'minimumOS': re.findall(r'minos\s+(\S+)', platform)[0]}


def compiled_inputs(source, destination):
    records = json.loads((destination / 'build/compile_commands.json').read_text())
    hashes = {}
    for record in records:
        command = record.get('arguments') or shlex.split(record['command'])
        if '-o' not in command: raise ValueError('Compiler inventory has no object output')
        obj = Path(record['directory']) / command[command.index('-o') + 1]
        if not obj.is_file(): continue
        path = Path(record['file']).resolve(strict=True)
        if path.is_relative_to(source):
            name = 'PPSSPP/' + path.relative_to(source).as_posix()
        elif path.is_relative_to(destination / 'source'):
            relative = path.relative_to(destination / 'source').as_posix()
            if relative not in overlay.PATCHED: raise ValueError('Undeclared native source hook')
            name = 'embedding/' + relative
        elif path in (NATIVE / 'IRPPSSPPNative.mm', NATIVE / 'IRPPSSPPCodecCheck.c'):
            name = 'Iridium/' + path.name
        elif path.is_relative_to(destination / 'build'):
            name = 'generated/' + path.relative_to(destination / 'build').as_posix()
        else: raise ValueError('Compiler input is outside the reviewed native player')
        hashes[name] = digest(path)
    if not all('Iridium/' + n in hashes for n in ('IRPPSSPPNative.mm', 'IRPPSSPPCodecCheck.c')):
        raise ValueError('The native player and media check were not both compiled')
    return hashes


def initialize(source):
    if output('git', '-C', source, 'rev-parse', 'HEAD') != REVISION:
        raise ValueError('Native PSP source must match the reviewed published release')
    run('git', '-C', source, 'submodule', 'update', '--init', '--depth', '1',
        *support.DEPENDENCIES, *EXTRA_DEPENDENCIES)
    run('git', '-C', source / 'ext/armips', 'submodule', 'update', '--init', '--depth', '1', 'ext/filesystem')


def revisions(source):
    # Every initialized dependency must match the selected release's gitlink.
    if not (source / '.git').exists():
        saved = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())
        prefix = source.relative_to(ROOT).as_posix()
        names = ('.', *support.DEPENDENCIES, *EXTRA_DEPENDENCIES, 'ext/armips/ext/filesystem')
        record = {name: saved.get(prefix if name == '.' else prefix + '/' + name) for name in names}
        if record['.'] != REVISION or any(not value for value in record.values()):
            raise ValueError('Corresponding source has missing or different native PSP revisions')
        return record
    record = {'.': output('git', '-C', source, 'rev-parse', 'HEAD')}
    if record['.'] != REVISION:
        raise ValueError('Unexpected native PSP release pin')
    for name in (*support.DEPENDENCIES, *EXTRA_DEPENDENCIES):
        expected = output('git', '-C', source, 'rev-parse', 'HEAD:' + name)
        actual = output('git', '-C', source / name, 'rev-parse', 'HEAD')
        if expected != actual:
            raise ValueError('Release dependency differs: ' + name)
        record[name] = actual
    nested = 'ext/armips/ext/filesystem'
    record[nested] = output('git', '-C', source / nested, 'rev-parse', 'HEAD')
    if record[nested] != output('git', '-C', source / 'ext/armips', 'rev-parse', 'HEAD:ext/filesystem'):
        raise ValueError('Nested filesystem pin differs')
    return record


def ffmpeg(source, destination, sdk, jobs):
    source = source.resolve(strict=True)
    build = destination / 'ffmpeg-build'
    install = destination / 'ffmpeg'
    build.mkdir(parents=True, exist_ok=True)
    options = shlex.split(output('sh', '-c', '. "$1"; printf "%s" "$CONFIGURE_OPTS"',
                                 'ppsspp-codecs', source / 'shared_options.sh'))
    target = 'arm64-apple-ios18.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
    if sdk == 'macosx': target = 'arm64-apple-macos14.0'
    compiler = output('xcrun', '--sdk', sdk, '--find', 'clang')
    sysroot = output('xcrun', '--sdk', sdk, '--show-sdk-path')
    flags = '-target ' + target + ' -isysroot ' + sysroot
    command = [source / 'configure', *options, '--enable-cross-compile', '--arch=aarch64',
               '--target-os=darwin', '--cpu=generic', '--enable-pic', '--cc=' + compiler,
               '--sysroot=' + sysroot, '--extra-cflags=' + flags,
               '--extra-ldflags=' + flags, '--prefix=' + str(install)]
    fingerprint = hashlib.sha256(('\n'.join(map(str, command))).encode()).hexdigest()
    stamp = build / 'iridium-configure.json'
    if not stamp.exists() or json.loads(stamp.read_text())['fingerprint'] != fingerprint:
        run(*command, cwd=build)
        stamp.write_text(json.dumps({'fingerprint': fingerprint, 'arguments': list(map(str, command))}, indent=2))
    run('make', '-j' + str(jobs), cwd=build)
    run('make', 'install', cwd=build)
    required = ('libavcodec.a', 'libavformat.a', 'libavutil.a', 'libswresample.a', 'libswscale.a')
    for name in required:
        if not (install / 'lib' / name).is_file():
            raise ValueError('Required PSP media library missing: ' + name)
    return {'arguments': list(map(str, command)), 'target': target,
            'libraries': {n: digest(install / 'lib' / n) for n in required}}


def assets(source, destination):
    origin = source / 'assets'
    hashes = {}
    sources = []
    for path in sorted(origin.rglob('*')):
        if any(p in ('.git', '.DS_Store') for p in path.relative_to(origin).parts):
            continue
        if path.is_symlink():
            raise ValueError('Review a symbolic runtime asset before packaging: ' + str(path))
        if not path.is_file(): continue
        relative = path.relative_to(origin).as_posix()
        hashes[relative] = digest(path)
        sources.append((relative, path))
    if destination.is_symlink():
        raise ValueError('Generated assets cannot use a symbolic-link directory')
    existing = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file()}
    if existing - set(hashes):
        raise ValueError('Unexpected old runtime assets; use a fresh native component output')
    # Validate the whole copy plan before touching an existing generated resource.
    for relative, path in sources:
        target = destination / relative
        if target.is_symlink() or any(p.is_symlink() for p in target.parents if p != destination.parent):
            raise ValueError('Generated asset path contains a symbolic link')
    for relative, path in sources:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if digest(target) != hashes[relative]:
            raise ValueError('Runtime asset changed while copied: ' + relative)
    if not hashes or not any(n.startswith('shaders/') for n in hashes) or not any(n.startswith('lang/') for n in hashes):
        raise ValueError('The full native runtime resource tree is incomplete')
    return hashes


def configure(source, destination, sdk):
    return ['cmake', '-S', str(destination / 'source'), '-B', str(destination / 'build'), '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=' + str(source / 'cmake/Toolchains/ios.cmake'),
        '-DIOS_PLATFORM=' + ('OS' if sdk == 'iphoneos' else 'SIMULATOR'),
        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0', '-DCMAKE_OSX_SYSROOT=' + output('xcrun', '--sdk', sdk, '--show-sdk-path'),
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DLIBRETRO=OFF',
        '-DIOS_APP_STORE=ON', '-DUSE_IAP=OFF', '-DHEADLESS=OFF', '-DUNITTEST=OFF', '-DATLAS_TOOL=OFF',
        '-DUSE_FFMPEG=ON', '-DUSE_SYSTEM_FFMPEG=OFF', '-DFFMPEG_DIR=' + str(destination / 'ffmpeg'),
        '-DUSE_WAYLAND_WSI=OFF', '-DUSING_X11_VULKAN=OFF', '-DUSE_SYSTEM_LIBPNG=OFF', '-DUSE_SYSTEM_ZSTD=OFF',
        '-DCMAKE_PROJECT_PPSSPP_INCLUDE=' + str(ROOT / 'ci/ppsspp-native.cmake'),
        '-DIRIDIUM_NATIVE_ADAPTER=' + str(NATIVE / 'IRPPSSPPNative.mm'),
        '-DIRIDIUM_NATIVE_HEADERS=' + str(NATIVE),
        '-DIRIDIUM_NATIVE_EXPORTS=' + str(destination / 'native.exports')]


def build(source, destination, sdk, jobs):
    source = source.resolve(strict=True); destination = destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('Native build outputs must stay outside upstream source')
    before = revisions(source)
    destination.mkdir(parents=True, exist_ok=True)
    codecs = ffmpeg(source / 'ffmpeg', destination, sdk, jobs)
    overlay.stage(source, destination / 'source')
    (destination / 'native.exports').write_text('\n'.join(sorted(EXPORTS)) + '\n')
    command = configure(source, destination, sdk)
    run(*command)
    run('cmake', '--build', destination / 'build', '--target', 'IridiumPPSSPPNative', '--parallel', jobs)
    binary = destination / 'build/lib/libIridiumPPSSPPNative.dylib'
    boundary = audit(binary, sdk)
    delivered = destination / binary.name
    shutil.copy2(binary, delivered)
    hashes = assets(source, destination / 'assets')
    support.notices(source, destination / 'licenses')
    shutil.copy2(source / 'ffmpeg/LICENSE.md', destination / 'licenses/LICENSE-PSP-FFMPEG.md')
    if before != revisions(source):
        raise ValueError('Source pin changed during native compilation')
    def portable(arg):
        text = str(arg)
        for path, label in ((destination, '$COMPONENT_OUTPUT'), (source, '$PPSSPP_SOURCE'), (ROOT, '$IRIDIUM_SOURCE')):
            text = text.replace(str(path), label)
        return text
    codecs['arguments'] = [portable(a) for a in codecs['arguments']]
    record = dict(**boundary, revision=REVISION, release=RELEASE, sourceRevisions=before, sdk=sdk,
        componentType='native-ios-player', binary=delivered.name, sha256=digest(delivered),
        compiledInputSHA256=compiled_inputs(source, destination), assetSHA256=hashes, codecs=codecs,
        configureArguments=[portable(a) for a in command], embeddingHooks={n: digest(destination / 'source' / n) for n in overlay.PATCHED},
        adapterSHA256=digest(NATIVE / 'IRPPSSPPNative.mm'), codecCheckSHA256=digest(NATIVE / 'IRPPSSPPCodecCheck.c'),
        sdkVersion=output('xcrun', '--sdk', sdk, '--show-sdk-version'),
        mode='native iOS; upstream media, graphics, UI and configuration')
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print('Built release-pinned native PSP player:', delivered)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'vendor/PPSSPP')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), default='iphoneos')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--initialize', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16: parser.error('Choose 1 to 16 build workers')
    if args.initialize: initialize(args.source)
    elif args.output is None: parser.error('--output is required')
    else: build(args.source, args.output, args.sdk, args.jobs)
