#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Explicit host-only PSP integration check; never downloads or builds PPSSPP."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent / 'psp'
ASSETS = ['compat.ini', 'langregion.ini', 'ppge_atlas.meta', 'ppge_atlas.zim'] + [
    'flash0/font/' + name + '.pgf' for name in
    ['jpn0', 'kr0'] + ['ltn' + str(i) for i in range(16)]
] + ['lang/' + name + '.ini' for name in [
    'en_US', 'ja_JP', 'fr_FR', 'de_DE', 'es_ES', 'it_IT', 'pt_PT', 'ru_RU',
    'nl_NL', 'ko_KR', 'zh_TW', 'zh_CN',
]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', type=Path, required=True,
                        help='Trusted, already-built host PPSSPP component with Iridium adapter exports')
    parser.add_argument('--api-header', type=Path, required=True,
                        help='Matching IridiumPSPAPI.h (or upstream self-contained libretro.h)')
    parser.add_argument('--assets', type=Path, required=True,
                        help='Matching upstream assets directory; copied into isolated temporary storage')
    parser.add_argument('--repo-root', type=Path, default=ROOT)
    parser.add_argument('--cc', default='cc', help='Host C compiler executable (one executable, no shell)')
    parser.add_argument('--timeout', type=float, default=180,
                        help='Maximum seconds for each compile or test process (default: 180)')
    args = parser.parse_args()
    if sys.platform not in ('linux', 'darwin'):
        parser.error('This POSIX host check supports Linux and macOS only')
    if not 0 < args.timeout < float('inf'):
        parser.error('--timeout must be positive and finite')
    component = args.component.resolve(strict=True)
    api_header = args.api_header.resolve(strict=True)
    bridge = args.repo_root.resolve(strict=True) / 'iridium/apps/ios/RuntimeBridge'
    for path in [component, api_header, bridge / 'IRPSPBridge.c', bridge / 'IRPSPBridge.h']:
        if not path.is_file():
            parser.error('Required file missing: ' + str(path))
    sources = args.assets.resolve(strict=True)
    for name in ASSETS:
        if not (sources / name).is_file():
            parser.error('Required matched asset missing: ' + name)
    spec = importlib.util.spec_from_file_location('psp_fixture', TESTS / 'make_fixture.py')
    fixture_module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(fixture_module)
    payload = fixture_module.fixture()
    if payload != fixture_module.fixture():
        raise RuntimeError('Fixture generation is not deterministic')
    print('Original fixture SHA-256:', hashlib.sha256(payload).hexdigest(), flush=True)
    print('Component SHA-256:', hashlib.sha256(component.read_bytes()).hexdigest(), flush=True)
    print('Bridge SHA-256:', hashlib.sha256((bridge / 'IRPSPBridge.c').read_bytes()).hexdigest(), flush=True)
    print('API SHA-256:', hashlib.sha256(api_header.read_bytes()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix='iridium-psp-check-') as folder:
        work = Path(folder)
        include = work / 'include'; include.mkdir()
        shutil.copyfile(api_header, include / 'IridiumPSPAPI.h')
        fixture = work / 'fixture.elf'; fixture.write_bytes(payload)
        invalid = work / 'invalid.elf'; invalid.write_bytes(b'Iridium original intentionally invalid PSP fixture\n')
        system = work / 'system'
        for name in ASSETS:
            target = system / 'PPSSPP' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(sources / name, target)
        def run(command):
            subprocess.run([str(part) for part in command], cwd=work, check=True, timeout=args.timeout)
        executables = {}
        for name in ['check_bridge', 'check_thread_migration', 'check_callbacks']:
            executable = work / name
            command = [args.cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-UNDEBUG',
                       '-I', str(include), '-I', str(bridge), TESTS / (name + '.c')]
            # Callback tests include the *actual* bridge source to reach its internal callbacks.
            if name != 'check_callbacks':
                command.append(bridge / 'IRPSPBridge.c')
            command += ['-pthread', '-lm']
            if sys.platform == 'linux':
                command.append('-ldl')
            command += ['-o', executable]
            run(command)
            executables[name] = executable
        for label, name, altstack in [
            ('callbacks', 'check_callbacks', False),
            ('lifecycle', 'check_bridge', False),
            ('lifecycle-altstack', 'check_bridge', True),
            ('serial-thread-migration', 'check_thread_migration', False),
        ]:
            print('RUN:', label, flush=True)
            command = [executables[name]]
            if name != 'check_callbacks':
                save = work / ('save-' + label); save.mkdir()
                command += [component, fixture]
                if name == 'check_bridge':
                    command.append(invalid)
                command += [system, save]
                if altstack:
                    command.append('--altstack')
            run(command)
    print('PASS: host fixture and bridge checks only; no iOS/device or commercial-game claim')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(1)
