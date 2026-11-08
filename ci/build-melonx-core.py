#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build and inspect the MeloNX iOS core for local Iridium integration."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build/melonx'
SOURCE = WORK / 'source'
REVISION = '13700519f3abc4e6d7ed8a065b118b2cc59bcd67'
SDK_VERSION = '10.0.403'
PROJECT = 'src/Ryujinx.Library'
BINARY = SOURCE / PROJECT / 'bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib'
PATCH = ROOT / 'ci/engine-integrations/melonx-storage.patch'
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
ADAPTER = WORK / 'libIridiumMeloNX.dylib'
RECEIPT = WORK / 'component.json'
DEPENDENCIES = SOURCE / 'src/MeloNX/MeloNX/Dependencies'


def packaged_files():
    yield BINARY, BINARY.name
    yield ADAPTER, ADAPTER.name
    yield DEPENDENCIES / 'libMoltenVK.dylib', 'libMoltenVK.dylib'
    for name in ('SDL3', 'libavcodec', 'libavutil', 'libswresample'):
        framework = name + '.framework'
        path = DEPENDENCIES / (name + '.xcframework') / 'ios-arm64' / framework
        yield path / name, framework + '/' + name


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def adapter_inputs():
    paths = [PATCH] + [BRIDGE / name for name in (
        'IRMeloNX.mm', 'IRPhase3.h', 'IRJITMemory.h',
        'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h')]
    return {path.name: digest(path) for path in paths}


def build_adapter():
    target = ['-target', 'arm64-apple-ios18.0', '-isysroot',
              output('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')]
    with tempfile.TemporaryDirectory(dir=WORK) as scratch:
        probe = Path(scratch) / 'probe.o'
        result = Path(scratch) / ADAPTER.name
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', *target, '-c',
                        BRIDGE / 'IRJITExecutionProbe.c', '-o', probe], check=True)
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang++', *target, '-dynamiclib',
                        '-std=c++17', '-fobjc-arc', '-O2', BRIDGE / 'IRMeloNX.mm', probe, BINARY,
                        '-framework', 'UIKit', '-framework', 'QuartzCore', '-framework', 'Metal', '-framework', 'CoreGraphics',
                        '-install_name', '@rpath/' + ADAPTER.name, '-o', result], check=True)
        result.replace(ADAPTER)


def component_record():
    files = {}
    names = {'@rpath/' + name for _, name in packaged_files()}
    for binary, name in packaged_files():
        build = output('xcrun', 'vtool', '-show-build', binary)
        platforms = re.findall(r'platform\s+(\w+)', build)
        legacy_ios = name == 'SDL3.framework/SDL3' and not platforms and 'LC_VERSION_MIN_IPHONEOS' in build
        if (binary.is_symlink() or output('xcrun', 'lipo', '-archs', binary) != 'arm64'
                or (platforms != ['IOS'] and not legacy_ios)):
            raise ValueError('MeloNX needs an ARM64 iOS device slice: ' + name)
        libraries = [line.strip().split(' (', 1)[0]
                     for line in output('xcrun', 'otool', '-L', binary).splitlines()[1:]]
        if libraries[0] != '@rpath/' + name or any(
                library not in names and not library.startswith(('/usr/lib/', '/System/Library/Frameworks/'))
                for library in libraries):
            raise ValueError('Unexpected MeloNX install name or dependency: ' + name)
        files[name] = digest(binary)
    symbols = set(output('xcrun', 'nm', '-gUj', ADAPTER).splitlines())
    required = {'_ir_native_engine_' + name for name in ('abi', 'create', 'pause', 'stop', 'frames', 'set_volume')}
    if not required | {'_ir_phase3_core_prepare_memory', '_ir_melonx_install_firmware'} <= symbols:
        raise ValueError('The MeloNX adapter does not export the complete console player interface')
    return {'revision': REVISION, 'sdk': SDK_VERSION, 'inputs': adapter_inputs(), 'files': files,
            'core': inspect(BINARY)}



def output(*args):
    return subprocess.check_output(args, text=True).strip()


def inspect(binary):
    if not binary.is_file():
        raise ValueError('Build the MeloNX core before inspecting it')
    if output('xcrun', 'lipo', '-archs', binary) != 'arm64':
        raise ValueError('MeloNX must be built for ARM64')
    build = output('xcrun', 'vtool', '-show-build', binary)
    if re.findall(r'platform\s+(\w+)', build) != ['IOS']:
        raise ValueError('MeloNX must target physical iOS devices')
    symbols = set(output('xcrun', 'nm', '-gUj', binary).splitlines())
    required = {'iridium_melonx_initialize', 'iridium_melonx_run', 'iridium_melonx_set_state',
                'iridium_melonx_reset_session', 'iridium_melonx_session_closed',
                'iridium_melonx_install_firmware', 'main_ryujinx_sdl', 'set_native_window', 'stop_emulation',
                'toggle_pause_emulation', 'attach_gamepad', 'detach_gamepad',
                'set_gamepad_button_state', 'set_gamepad_stick_axis', 'load_keyset',
                'install_firmware', 'installed_firmware_version', 'init_dualmapping'}
    missing = {'_' + name for name in required} - symbols
    if missing:
        raise ValueError('Missing MeloNX exports: ' + ', '.join(sorted(missing)))
    libraries = output('xcrun', 'otool', '-L', binary).splitlines()[1:]
    libraries = [line.strip().split(' (', 1)[0] for line in libraries]
    if not libraries or libraries[0] != '@rpath/Ryujinx.Library.dylib' or any(
            not library.startswith(('/usr/lib/', '/System/Library/Frameworks/')) for library in libraries[1:]):
        raise ValueError('Unexpected MeloNX install name or linked library')
    with binary.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'sha256': digest, 'bytes': binary.stat().st_size, 'platform': 'IOS',
            'architecture': 'arm64', 'checkedExports': sorted(required),
            'dynamicLibraries': libraries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', action='store_true', help='Check an existing core without rebuilding')
    args = parser.parse_args()
    if not (SOURCE / '.git').exists():
        parser.error('Clone tag 2.7 from https://starforgejo.dev/projects/MeloNX.git into .build/melonx/source')
    if output('git', '-C', SOURCE, 'rev-parse', 'HEAD') != REVISION or output(
            'git', '-C', SOURCE, 'status', '--porcelain'):
        parser.error('Use a clean MeloNX 2.7 checkout at ' + REVISION)
    if not args.inspect:
        if shutil.disk_usage(WORK).free < 25 * 1024**3:
            parser.error('Keep 20 GiB free plus 5 GiB for NativeAOT build files')
        sdk = WORK / ('dotnet-' + SDK_VERSION) / 'dotnet'
        dotnet = str(sdk) if sdk.is_file() else shutil.which('dotnet')
        if not dotnet:
            parser.error('Install .NET SDK ' + SDK_VERSION + ' with the mobile-librarybuilder workload')
        env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin:' + os.environ['PATH'],
                   DOTNET_CLI_HOME=str(WORK / 'dotnet-home'), DOTNET_NOLOGO='1',
                   DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
        version = subprocess.check_output([dotnet, '--version'], cwd=SOURCE, env=env, text=True).strip()
        if version != SDK_VERSION:
            parser.error('Use .NET SDK ' + SDK_VERSION)
        config = (SOURCE / 'nuget.config').read_bytes()
        old = b'https://starforgejo.dev/api/packages/Ryulynx/nuget/index.json'
        if config.count(old) != 1:
            parser.error('The upstream LibHac feed changed. Review the replacement before building.')
        # Use the upstream registry that still serves the pinned LibHac version.
        feed = b'https://git.ryujinx.app/api/v4/projects/17/packages/nuget/index.json'
        nuget = WORK / 'nuget.config'
        nuget.write_bytes(config.replace(old, feed))
        subprocess.run(['git', 'apply', '--ignore-space-change', '--whitespace=error', PATCH], cwd=SOURCE, check=True)
        try:
            subprocess.run([dotnet, 'publish', PROJECT, '-c', 'Release', '-r', 'ios-arm64',
                            '--self-contained', 'true', '--configfile', str(nuget),
                            '-p:ExtraDefineConstants=DISABLE_UPDATER', '-p:NativeLib=Shared',
                            '-m:4', '--disable-build-servers'], cwd=SOURCE, env=env, check=True)
        finally:
            subprocess.run(['git', 'apply', '--ignore-space-change', '--reverse', PATCH], cwd=SOURCE, check=True)
        build_adapter()
        RECEIPT.write_text(json.dumps(component_record(), indent=2) + '\n')
    record = component_record()
    if json.loads(RECEIPT.read_text()) != record:
        parser.error('Rebuild MeloNX. Its inputs or outputs differ from the component receipt.')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
