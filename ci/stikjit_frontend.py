# SPDX-License-Identifier: AGPL-3.0-only
"""Source-built checked JIT transport, separate from runtime compiler inputs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / '.build/stikjit-frontend'
FRAMEWORK = OUTPUT / 'StikJIT.framework'
RUNNER = ROOT / 'iridium/apps/ios/JITSupport/ScriptRunner.swift'
FEATURES = 'full,ring'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inputs():
    entries = json.loads((ROOT / 'ci/runtime-inputs.json').read_text())
    return [next(x for x in entries if x['name'] == name)
            for name in ('frontend-stikjit-source', 'idevice-source')]


def verify_source(entry):
    source = ROOT / entry['destination']
    archive = ROOT / '.build/runtime-downloads' / (entry['sha256'] + '.tar')
    if digest(archive) != entry['sha256']: raise ValueError('JIT source archive changed')
    with tarfile.open(archive) as stream:
        for member in stream:
            relative = Path(member.name).relative_to(entry['archive_root'])
            if not member.isfile() or relative.suffix not in {'.swift', '.rs', '.toml', '.lock', '.h', '.modulemap', '.js'}:
                continue
            target = source / relative
            if target.is_symlink() or not target.is_file() or target.read_bytes() != stream.extractfile(member).read():
                raise ValueError('Pinned JIT source changed: ' + str(relative))


def identity():
    return {'schema': 1, 'sources': {x['name']: x['sha256'] for x in inputs()},
            'runner': digest(RUNNER), 'recipe': digest(__file__), 'features': FEATURES,
            'tools': {tool: subprocess.check_output(command, text=True).strip()
                      for tool, command in [('swift', ['xcrun', 'swiftc', '--version']),
                          ('sdk', ['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version']),
                          ('rust', ['rustc', '-vV'])]}}


def verify(framework=FRAMEWORK):
    record = json.loads((OUTPUT / 'component.json').read_text())
    for entry in inputs(): verify_source(entry)
    if record['inputs'] != identity():
        raise ValueError('The checked JIT helper inputs changed; rebuild it')
    if json.loads((framework / 'IridiumJITTransport.json').read_text()) != record:
        raise ValueError('The packaged JIT transport receipt differs')
    for name, expected in record['files'].items():
        path = framework / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError('The checked JIT helper differs: ' + name)
    return record


def cargo_command():
    command = ['cargo']
    if (OUTPUT / '.cargo/config.toml').is_file():
        command += ['--offline', '--config', str(OUTPUT / '.cargo/config.toml')]
    return command


def write_notices(ffi, destination):
    metadata = json.loads(subprocess.check_output([*cargo_command(), 'metadata', '--manifest-path', str(ffi / 'ffi/Cargo.toml'),
        '--locked', '--format-version', '1', '--filter-platform', 'aarch64-apple-ios',
        '--no-default-features', '--features', FEATURES], text=True))
    out = ['Source-built idevice FFI and Cargo dependency notices.', '']; seen = set()
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        folder = Path(package['manifest_path']).parent
        files = sorted(p for p in folder.iterdir() if p.is_file()
                       and p.name.upper().startswith(('LICENSE', 'LICENCE', 'NOTICE', 'COPYING')))
        if not files and folder.is_relative_to(ffi): files = [ffi / 'LICENSE.txt']
        out.append(package['name'] + ' ' + package['version'] + ' (' + (package.get('license') or 'see files') + ')')
        for path in files:
            text = path.read_text(errors='replace')
            if text not in seen: out.extend([path.name, text]); seen.add(text)
        out.append('')
    destination.write_text('\n'.join(out))


def collect_source(stage):
    """Include the new FFI dependency graph with the existing locked source inputs."""
    ffi = ROOT / inputs()[1]['destination']
    target = stage / '.build/stikjit-frontend'
    vendor = target / 'vendor'; target.mkdir(parents=True, exist_ok=True)
    command = ['cargo', 'vendor', '--locked', '--manifest-path', str(ffi / 'ffi/Cargo.toml')]
    config = subprocess.check_output([*command, str(vendor)], text=True)
    # cbindgen also resolves the published plist_ffi crate's own lockfile.
    config = subprocess.check_output([*command, '--sync', str(vendor / 'plist_ffi/Cargo.toml'), str(vendor)], text=True)
    (target / '.cargo').mkdir(exist_ok=True)
    (target / '.cargo/config.toml').write_text(config.replace(str(vendor), 'vendor'))
    shutil.copy2(OUTPUT / 'component.json', stage / 'STIKJIT-BUILD-RECEIPT.json')


def build():
    expected = identity()
    try:
        verify()
        print('Reusing input-matched checked StikJIT transport.', flush=True)
        return
    except (OSError, KeyError, ValueError):
        pass
    spec = importlib.util.spec_from_file_location('jit_fetch', ROOT / 'ci/fetch-runtime-inputs.py')
    fetch = importlib.util.module_from_spec(spec); spec.loader.exec_module(fetch)
    source, ffi = inputs()
    for entry in (source, ffi):
        target = ROOT / entry['destination']
        if not target.exists(): fetch.fetch(ROOT, entry)
        verify_source(entry)
    source, ffi = ROOT / source['destination'], ROOT / ffi['destination']
    # Pinned archives stay immutable. Build outputs never overwrite an upstream checkout.
    OUTPUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CARGO_TARGET_DIR=str(OUTPUT / 'cargo-target'),
               CARGO_BUILD_JOBS=os.environ.get('IRIDIUM_BUILD_JOBS', '2'),
               IPHONEOS_DEPLOYMENT_TARGET='17.4')
    subprocess.run(['rustup', 'target', 'add', 'aarch64-apple-ios'], check=True, env=env)
    subprocess.run([*cargo_command(), 'build', '--manifest-path', str(ffi / 'ffi/Cargo.toml'),
                    '--release', '--locked', '--target', 'aarch64-apple-ios',
                    '--no-default-features', '--features', FEATURES], check=True, env=env)
    headers = OUTPUT / 'idevice'; headers.mkdir(exist_ok=True)
    shutil.copy2(ffi / 'ffi/idevice.h', headers / 'idevice.h')
    (headers / 'module.modulemap').write_text('module idevice { header "idevice.h" export * }\n')
    library = headers / 'libidevice_ffi.a'
    target = OUTPUT / 'cargo-target/aarch64-apple-ios/release/libidevice_ffi.a'
    if library.is_symlink() and library.resolve() != target.resolve():
        raise ValueError('Unexpected JIT static archive link')
    if not library.exists(): library.symlink_to(target)
    module = FRAMEWORK / 'Modules/StikJIT.swiftmodule'; module.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    sources = [str(p) for p in sorted((source / 'Sources').glob('*.swift')) if p.name != 'ScriptRunner.swift']
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
               '-emit-library', '-emit-module', '-enable-library-evolution', '-module-name', 'StikJIT',
               '-target', 'arm64-apple-ios26.0', '-sdk', sdk,
               '-module-cache-path', str(OUTPUT / 'module-cache'),
               '-I', str(headers), '-I', str(source / 'iokit'),
               '-L', str(headers), '-Xlinker', '-hidden-lidevice_ffi',
               '-Xlinker', '-dead_strip',
               '-Xlinker', '-no_adhoc_codesign', '-Xlinker', '-install_name',
               '-Xlinker', '@rpath/StikJIT.framework/StikJIT',
               '-Xlinker', '-current_version', '-Xlinker', '1.0.0',
               '-Xlinker', '-compatibility_version', '-Xlinker', '1.0.0',
               '-emit-module-path', str(module / 'arm64-apple-ios.swiftmodule'),
               '-emit-module-interface-path', str(module / 'arm64-apple-ios.swiftinterface'),
               '-o', str(FRAMEWORK / 'StikJIT'), *sources, str(RUNNER)]
    for name in ('JavaScriptCore', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit'):
        command += ['-framework', name]
    subprocess.run(command, check=True)
    libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(FRAMEWORK / 'StikJIT')], text=True)
    if 'libidevice_ffi' in libraries: raise ValueError('JIT FFI must be linked statically')
    for resource in (source / 'Resources').glob('*.js'): shutil.copy2(resource, FRAMEWORK / resource.name)
    (FRAMEWORK / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'software.iridium.vendor.StikJIT', 'CFBundleName': 'StikJIT',
        'CFBundleExecutable': 'StikJIT', 'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '1.9.0', 'CFBundleVersion': '10',
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '26.0'}))
    write_notices(ffi, FRAMEWORK / 'LICENSES-idevice.txt')
    record = {'inputs': expected, 'files': {name: digest(FRAMEWORK / name)
               for name in ('StikJIT', 'universal.js', 'legacy.js', 'LICENSES-idevice.txt')}}
    if identity() != expected: raise ValueError('JIT helper inputs changed during compilation')
    for path in (OUTPUT / 'component.json', FRAMEWORK / 'IridiumJITTransport.json'):
        path.write_text(json.dumps(record, indent=2) + '\n')
    verify()
    print('Built checked StikJIT from pinned Swift and idevice source.', flush=True)


def stage(app):
    verify()
    destination = app / 'Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework'
    if destination.is_symlink(): raise ValueError('Unexpected JIT staging link')
    shutil.copytree(FRAMEWORK, destination, dirs_exist_ok=True)


if __name__ == '__main__':
    build()
