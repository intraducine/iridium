#!/usr/bin/env python3
"""Apply Iridium's presentation overlay to the pinned Madeira app, out of tree."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import shlex
import hashlib
import importlib.util
import inspect
import json
import os
import time
import sys
import madeira_presentation

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/Madeira'
FRONTEND = ROOT / 'iridium/apps/ios/MadeiraFrontend'
RUNTIME_SUPPORT = ROOT / 'iridium/apps/ios/RuntimeSupport'
RUNTIME_BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
OUTPUT = ROOT / '.build/madeira-frontend'
REVISION = '48f976429c189f8396e23d251d8a82f43c705922'
# Presentation hooks and explicit exclusive-runtime guards. Madeira's launch
# sequence, native driver, network implementation and allocator remain intact.
HOOKS = {
    'ContentView.swift': [
        ('LibraryView(play: launchLibraryEntry, enableJIT: enableJIT,',
         'IridiumLibraryView(play: launchLibraryEntry, enableJIT: enableJIT,'),
        ('.navigationTitle("Madeira")', '.navigationTitle("Iridium")'),
        ('private func launchLibraryEntry(_ entry: LibraryEntry) {',
         'private func launchLibraryEntry(_ entry: LibraryEntry) {\n'
         '        guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }'),
        ('private func startLibraryEntry(_ entry: LibraryEntry) {',
         'private func startLibraryEntry(_ entry: LibraryEntry) {\n'
         '        guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }'),
        ('private func runWineFullSequence(profile: LibraryEntry? = nil) {',
         'private func runWineFullSequence(profile: LibraryEntry? = nil) {\n'
         '        guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }'),
        ('private func startDock(_ game: DockGame, compactPool: Bool, profile: LibraryEntry? = nil) {',
         'private func startDock(_ game: DockGame, compactPool: Bool, profile: LibraryEntry? = nil) {\n'
         '        guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }'),
    ],
    'Library.swift': [
        ('@State private var tab = 0', '@State var tab = 0'),
        ('(0x10, "menu"), (0x100, "tab")', '(0x10, "menu"), (0x4000, "play"), (0x100, "tab")'),
    ],
    'MadeiraApp.swift': [
        ('_ = ResolutionChoices.screen',
         '_ = ResolutionChoices.screen\n        UserDefaults.standard.set("new", forKey: FrontendChoice.key)'),
    ],
}


def overlay(name, text):
    for old, new in HOOKS.get(name, []):
        if text.count(old) != 1:
            raise ValueError(f'Madeira presentation hook changed: {name}: {old}')
        text = text.replace(old, new)
    return madeira_presentation.apply(name, text)


def verify_pin():
    if not (ROOT / '.git').exists():
        revisions = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())
        if revisions.get('vendor/Madeira') != REVISION:
            raise ValueError('Unexpected Madeira source package revision')
        expected = json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']['dependencies']
        for name, revision in expected.items():
            if revisions.get('vendor/Madeira/' + name) != revision or not (UPSTREAM / name).is_dir():
                raise ValueError('Incomplete source package: ' + name)
        return  # Supplied source can be modified for LGPL replacement.
    actual = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION:
        raise ValueError(f'Expected Madeira {REVISION}; found {actual}. Review the overlay before updating.')
    repos = [UPSTREAM]
    for line in subprocess.check_output(['git', '-C', str(UPSTREAM), 'submodule', 'status', '--recursive'], text=True).splitlines():
        if line.startswith('-'): continue  # Large test-only submodules stay uninitialized.
        if not line.startswith(' '): raise ValueError('Unexpected dependency revision: ' + line.split()[1])
        repos.append(UPSTREAM / line.split()[1])
    for repo in repos:
        changes = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
        if any(Path(name).suffix in {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.cc', '.pbxproj',
                                     '.sh', '.rs', '.metal', '.S', '.inc', '.in', '.cmake'}
               or Path(name).name == 'CMakeLists.txt' for name in changes):
            raise ValueError(f'Pinned source has changes: {repo}. Preserve them before preparing the overlay.')
        if repo.parent == UPSTREAM:
            expected = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD:' + repo.name], text=True).strip()
            actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            if expected != actual: raise ValueError(f'Unexpected dependency revision: {repo.name}')


def project(source, names):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(source)]))
    objects = data['objects']
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Madeira')
    target['name'] = target['productName'] = 'Iridium'
    objects[target['productReference']]['path'] = 'Iridium.app'
    group = next(v for v in objects.values() if v.get('isa') == 'PBXGroup' and v.get('path') == 'Madeira')
    sources = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
    for index, name in enumerate(names):
        reference, build = f'F000000000000000{index:08X}', f'F100000000000000{index:08X}'
        kind = 'sourcecode.c.c' if name.endswith('.c') else 'sourcecode.swift'
        objects[reference] = dict(isa='PBXFileReference', lastKnownFileType=kind, path=name, sourceTree='<group>')
        objects[build] = dict(isa='PBXBuildFile', fileRef=reference)
        group['children'].append(reference); sources['files'].append(build)
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[config]['buildSettings']
        settings['PRODUCT_NAME'] = 'Iridium'
        settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
        settings['MARKETING_VERSION'] = '0.2.1'
        settings['CURRENT_PROJECT_VERSION'] = '1'
        def append(key, additions, unique=True):
            existing = settings.get(key, ['$(inherited)'])
            if isinstance(existing, str): existing = shlex.split(existing)
            settings[key] = existing + [item for item in additions if not unique or item not in existing]
        append('HEADER_SEARCH_PATHS', ['$(SRCROOT)/../../sameboy/$(PLATFORM_NAME)',
                                      '$(SRCROOT)/../../../vendor/SameBoy/libretro'])
        append('LIBRARY_SEARCH_PATHS', ['$(SRCROOT)/../../sameboy/$(PLATFORM_NAME)'])
        append('OTHER_LDFLAGS', ['-lIridiumSameBoy', '-framework', 'CoreFoundation'], unique=False)
    for value in objects.values():
        if value.get('isa') == 'XCBuildConfiguration':
            value['buildSettings']['DEVELOPMENT_TEAM'] = ''
            value['buildSettings']['MADEIRA_BUNDLE_IDENTIFIER'] = 'software.iridium'
    return data


def prepare():
    verify_pin()
    app = OUTPUT / 'app'
    # Only generated presentation files are replaced. Native build outputs are
    # retained at their upstream locations, with the same project link paths.
    app.mkdir(parents=True, exist_ok=True)
    shutil.copytree(UPSTREAM / 'app', app, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('xcuserdata', '.DS_Store'))
    for name in ('FEX', 'wine', 'dxmt', 'madeira-dock', 'madeira-d3d12', 'build', 'LICENSES', 'toolchains'):
        link = OUTPUT / name
        if not link.is_symlink() and link.exists():
            raise ValueError('Refusing to replace an existing build directory: ' + str(link))
        if not link.is_symlink(): link.symlink_to((UPSTREAM / name).resolve(), target_is_directory=True)
    for name in ('COPYING', 'LICENSE', 'LICENSE-EXCEPTION.md', 'THIRD-PARTY-NOTICES.md'):
        shutil.copy2(UPSTREAM / name, OUTPUT / name)
    for source, name in [('COPYING', 'LICENSE-MADEIRA-GPL-3.0.txt'), ('LICENSE-EXCEPTION.md', 'LICENSE-MADEIRA-EXCEPTION.txt')]:
        shutil.copy2(UPSTREAM / source, app / 'Madeira/licenses' / name)
    shutil.copy2(ROOT / 'LICENSE', app / 'Madeira/licenses/LICENSE-IRIDIUM.txt')
    # Native Wine substitutes remain bundled. Optional Microsoft redistributables
    # must be supplied by the user, rather than copied from a maintainer's games.
    (app / 'Madeira/x86_64-vcruntime').mkdir(exist_ok=True)
    for source in (UPSTREAM / 'app/Madeira').rglob('*.swift'):
        target = app / 'Madeira' / source.relative_to(UPSTREAM / 'app/Madeira')
        target.write_text(overlay(source.name, source.read_text()))
    sources = sorted([*FRONTEND.glob('*.swift'), *RUNTIME_SUPPORT.glob('*.swift'), *RUNTIME_BRIDGE.glob('*.c')])
    names = [path.name for path in sources]
    if len(set(names)) != len(names): raise ValueError('Duplicate runtime source filenames')
    for source in sources: shutil.copy2(source, app / 'Madeira' / source.name)
    shutil.copy2(RUNTIME_BRIDGE / 'IridiumCoreBridge.h', app / 'Madeira/IridiumCoreBridge.h')
    header = app / 'Madeira/Madeira-Bridging-Header.h'
    header.write_text(header.read_text() + '\n#import "IridiumCoreBridge.h"\n')
    shutil.copy2(ROOT / 'vendor/SameBoy/LICENSE', app / 'Madeira/licenses/LICENSE-SAMEBOY.txt')
    api = (ROOT / 'vendor/SameBoy/libretro/libretro.h').read_text()
    if not api.startswith('/* Copyright') or '*/' not in api:
        raise ValueError('Missing Libretro API license notice')
    (app / 'Madeira/licenses/LICENSE-SAMEBOY-SUPPORT.txt').write_text(api[:api.index('*/') + 2] + '\n')
    generated = app / 'Madeira.xcodeproj/project.pbxproj'
    generated.write_bytes(plistlib.dumps(project(UPSTREAM / 'app/Madeira.xcodeproj/project.pbxproj', names)))
    info = app / 'Madeira/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['CFBundleDisplayName'] = 'Iridium'
    data['IridiumMadeiraRevision'] = REVISION
    info.write_bytes(plistlib.dumps(data))
    icon = ROOT / 'iridium/apps/ios/Iridium/Assets.xcassets/AppIcon.appiconset'
    shutil.copytree(icon, app / 'Madeira/Assets.xcassets/AppIcon.appiconset', dirs_exist_ok=True)
    verify()
    print(generated.parent)


def verify():
    verify_pin()
    for path in (UPSTREAM / 'app/Madeira').rglob('*'):
        if not path.is_file() or path.suffix not in {'.swift', '.h', '.c', '.m', '.mm', '.cpp'}: continue
        generated = OUTPUT / 'app/Madeira' / path.relative_to(UPSTREAM / 'app/Madeira')
        expected = overlay(path.name, path.read_text()).encode() if path.suffix == '.swift' else path.read_bytes()
        if path.name == 'Madeira-Bridging-Header.h': expected += b'\n#import "IridiumCoreBridge.h"\n'
        if not generated.is_file() or generated.read_bytes() != expected:
            raise ValueError('Generated app differs from Madeira outside its presentation hooks: ' + str(path))
    print('Madeira app code matches the pin outside declared presentation and runtime ownership hooks.')


def check_bundle(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('IridiumMadeiraRevision') != REVISION:
        raise ValueError('Unexpected Madeira source pin in the app')
    for name in ('arm64ec-windows', 'aarch64-windows', 'i386-windows'):
        source = UPSTREAM / 'app/Madeira' / name
        expected = {path.name for path in source.glob('*') if path.is_file() and not path.name.startswith('.')}
        actual = {path.name for path in (app / name).glob('*') if path.is_file() and not path.name.startswith('.')}
        if not expected or expected - actual:
            raise ValueError(f'Madeira runtime files are missing from {name}: {sorted(expected - actual)}')
    if not (app / 'arm64ec-windows/xtajit64.dll').is_file(): raise ValueError('The FEX translator is missing')
    if not (app / 'd3d12/libmetalirconverter.dylib').is_file(): raise ValueError('The D3D12 converter is missing')
    for name in ('aarch64-windows/xtajit.dll', 'aarch64-windows/wow64.dll',
                 'aarch64-windows/wow64win.dll', 'i386-windows/ntdll.dll',
                 'i386-windows/d3d9.dll', 'i386-windows/winemetal.dll'):
        if not (app / name).is_file() or not (app / name).stat().st_size:
            raise ValueError('The WoW64 runtime is missing: ' + name)


def compiler_identity():
    tools = (['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'],
             ['xcrun', '--sdk', 'iphoneos', 'metal', '--version'],
             ['xcrun', '--sdk', 'iphoneos', 'clang', '--version'], ['rustc', '-vV'],
             ['cmake', '--version'], ['meson', '--version'], ['clang', '--version'])
    record = [subprocess.check_output(tool, text=True).strip() for tool in tools]
    # Metal's mount changes after a restart; its version and target are inputs.
    record[2] = '\n'.join(line for line in record[2].splitlines() if not line.startswith('InstalledDir:'))
    return hashlib.sha256('\n'.join(record).encode()).hexdigest()


def windows():
    """Build the untracked i386 farm using Madeira's original recipe."""
    verify_pin()
    recipe = UPSTREAM / 'build/wine-i386/build.sh'
    stamp = UPSTREAM / '.build/iridium-i386.json'
    key = hashlib.sha256(REVISION.encode() + inspect.getsource(windows).encode() + recipe.read_bytes()
                         + compiler_identity().encode()
                         + subprocess.check_output([str(UPSTREAM / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/i686-w64-mingw32-clang'), '--version'])).hexdigest()
    def digest(path):
        with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
    try:
        saved = json.loads(stamp.read_text())
        if saved['key'] == key and 0 <= time.time() - saved['completed'] < 14 * 86400 and saved['outputs'] and all(
            (UPSTREAM / name).is_file() and digest(UPSTREAM / name) == value for name, value in saved['outputs'].items()
        ):
            print('Reusing the completed Madeira i386 build; inputs and files match, within 14 days.')
            return
    except (OSError, ValueError, KeyError): pass
    # Xcode's macOS metal wrapper can be a stub even when the downloaded
    # toolchain is installed. Select the real tool without changing the recipe.
    metal = Path(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', 'metal'], text=True).strip())
    env = dict(os.environ, TOOLCHAINS=str(metal.parents[2]))
    subprocess.run(['bash', str(recipe)], env=env, cwd=UPSTREAM, check=True)
    outputs = sorted(path for path in (UPSTREAM / 'app/Madeira/i386-windows').glob('*')
                     if path.is_file() and not path.name.startswith('.'))
    if not outputs: raise ValueError('Madeira built no i386 runtime files')
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(dict(key=key, completed=time.time(),
                                    outputs={str(path.relative_to(UPSTREAM)): digest(path) for path in outputs}), indent=2) + '\n')
    print('Saved the completed i386 build before app compilation and packaging.')


def toolchains():
    """Fetch the locked tools even when compiler outputs are restored."""
    spec = importlib.util.spec_from_file_location('fetch_inputs', ROOT / 'ci/fetch-runtime-inputs.py')
    fetcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fetcher)
    for entry in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()):
        if entry['name'] not in ('llvm', 'llvm-mingw'): continue
        entry = dict(entry, destination=entry['destination'].replace('testrepos/Madeira/', 'vendor/Madeira/', 1))
        if not (ROOT / entry['destination']).exists(): fetcher.fetch(ROOT, entry)


def bootstrap():
    toolchains()
    llvm = UPSTREAM / 'toolchains/llvm-project/llvm'
    module = llvm / 'cmake/modules/AddLLVM.cmake'
    text = module.read_text()
    if text.count('MATCHES "Darwin"') == 2:
        module.write_text(text.replace('MATCHES "Darwin"', 'MATCHES "Darwin|iOS"'))
    elif text.count('MATCHES "Darwin|iOS"') != 2: raise ValueError('Unexpected LLVM linker configuration')
    ios = UPSTREAM / 'toolchains/llvm-ios-build'
    if not (ios / 'lib/libLLVMPasses.a').is_file():
        host = UPSTREAM / 'toolchains/llvm-host-build'
        options = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
                   '-DLLVM_TARGETS_TO_BUILD=', '-DLLVM_ENABLE_PROJECTS=']
        options += ['-DLLVM_' + name + '=OFF' for name in (
            'ENABLE_ASSERTIONS', 'INCLUDE_TESTS', 'INCLUDE_EXAMPLES', 'INCLUDE_BENCHMARKS', 'INCLUDE_DOCS',
            'ENABLE_ZLIB', 'ENABLE_ZSTD', 'ENABLE_TERMINFO', 'ENABLE_LIBXML2', 'ENABLE_CURL', 'ENABLE_FFI', 'ENABLE_EH', 'ENABLE_RTTI')]
        subprocess.run(['cmake', '-S', str(llvm), '-B', str(host), *options], check=True)
        subprocess.run(['cmake', '--build', str(host), '--target', 'llvm-tblgen', '-j6'], check=True)
        subprocess.run(['cmake', '-S', str(llvm), '-B', str(ios), *options, '-DCMAKE_SYSTEM_NAME=iOS',
                        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
                        '-DLLVM_TABLEGEN=' + str(host / 'bin/llvm-tblgen'), '-DLLVM_BUILD_UTILS=OFF',
                        '-DLLVM_INCLUDE_TOOLS=OFF', '-DLLVM_INCLUDE_UTILS=OFF'], check=True)
        subprocess.run(['cmake', '--build', str(ios), '--target', 'LLVMPasses', 'LLVMBitWriter', '-j6'], check=True)
    if not (UPSTREAM / 'toolchains/gnutls-ios/include/gnutls/gnutls.h').is_file():
        subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=UPSTREAM / 'build/gnutls-ios/src', check=True)
        subprocess.run(['bash', 'build/gnutls-ios/build.sh'], cwd=UPSTREAM, check=True)


def build_native():
    """Build the upstream archives, including the absent cold-build server base."""
    verify_pin()
    def run(*args): subprocess.run(args, cwd=UPSTREAM, check=True)
    for name in ('llvm-project/llvm', 'llvm-ios-build/lib', 'gnutls-ios/include'):
        if not (UPSTREAM / 'toolchains' / name).is_dir():
            raise ValueError('Prepare the upstream toolchain first: toolchains/' + name)
    run('rustup', 'target', 'add', 'aarch64-apple-ios')
    run('bash', 'build/rppairing-ios/build.sh')
    run('bash', 'build/ffmpeg/build.sh')
    if not (UPSTREAM / 'research/freetype').exists():
        run('git', 'clone', '--depth', '1', '--branch', 'VER-2-13-3',
            'https://github.com/freetype/freetype.git', 'research/freetype')
    if (UPSTREAM / 'research/freetype/.git').exists():
        freetype = subprocess.check_output(['git', '-C', str(UPSTREAM / 'research/freetype'), 'rev-parse', 'HEAD'], text=True).strip()
    else:
        freetype = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())['vendor/Madeira/research/freetype']
    if freetype != '42608f77f20749dd6ddc9e0536788eaad70ea4b5': raise ValueError('Unexpected FreeType revision')
    run('bash', 'build/freetype-ios/build.sh')
    run('cmake', '-S', 'FEX', '-B', 'FEX/build-ios', '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_SYSTEM_PROCESSOR=arm64', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
        '-DCMAKE_BUILD_TYPE=Release', '-DTUNE_CPU=generic', '-DBUILD_TESTING=OFF',
        '-DBUILD_THUNKS=OFF', '-DBUILD_FEXCONFIG=OFF', '-DBUILD_FEX_LINUX_TESTS=OFF',
        '-DBUILD_STEAM_SUPPORT=OFF', '-DENABLE_FEX_ALLOCATOR=OFF', '-DENABLE_ASSERTIONS=OFF',
        '-DENABLE_CLANG_THUNKS=ON', '-DENABLE_CCACHE=ON', '-DENABLE_WERROR=OFF',
        '-DENABLE_STRICT_WERROR=OFF', '-DENABLE_LTO=OFF', '-DENABLE_VIXL_DISASSEMBLER=OFF',
        '-DENABLE_VIXL_SIMULATOR=OFF', '-DENABLE_ZYDIS=OFF')
    run('cmake', '--build', 'FEX/build-ios', '--target', 'FEXCore', 'FEXCore_Base',
        'JemallocLibs', 'fmt', 'xxhash', 'cephes_128bit', 'softfloat_3e', '-j6')
    wine = UPSTREAM / 'wine/build-macos'
    wine.mkdir(exist_ok=True)
    subprocess.run(['../configure', '--enable-win64', '--enable-archs=aarch64,arm64ec',
                    '--without-x', '--without-freetype', '--disable-tests'], cwd=wine, check=True)
    subprocess.run(['make', '-j6', 'include/all', 'tools/winebuild/winebuild', 'tools/widl/widl'], cwd=wine, check=True)
    server = UPSTREAM / 'build/wineserver'
    if not (server / 'obj/libwineserver.a').exists():
        text = (server / 'build.sh').read_text().split('# Patched files:')[0]
        begin, end = text.index('# Copy the base library'), text.index('CC_FLAGS=')
        text = text[:begin] + text[end:]
        text = text.replace('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"', 'BUILD_DIR=' + shlex.quote(str(server)))
        # Compile the untouched members with the original compiler flags; the
        # upstream script then supplies all its iOS-specific replacement members.
        text += '''
for src in "$WINE_SRC"/server/*.c; do
    name=$(basename "$src" .c)
    case "$name" in request|main|mach|unicode|fd|process|window|mapping|queue) continue ;; esac
    compile_one "$src" "$name"
done
ar rcs "$OBJ_DIR/libwineserver.a" "$OBJ_DIR"/*.o
'''
        subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, check=True)
    for component in ('wineserver', 'ntdll-unix', 'win32u-unix'):
        run('bash', f'build/{component}/build.sh')
    headers = UPSTREAM / 'build/dxmt-ios/shader-headers'
    headers.mkdir(parents=True, exist_ok=True)
    for name in ('air_msad', 'air_samplepos', 'air_tessellation'):
        source = UPSTREAM / f'dxmt/src/airconv/shaders/{name}.metal'
        if name == 'air_tessellation':
            # New Metal SDKs changed the private intrinsic's argument count.
            # The public operation has the same relaxed threadgroup semantics.
            text = source.read_text().replace(
                '__metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__)',
                'atomic_fetch_add_explicit(reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed)')
            source = headers / f'{name}.metal'
            source.write_text(text)
        air = headers / f'{name}.air'
        run('xcrun', '--sdk', 'iphoneos', 'metal', '-std=metal3.1', '--target=air64-apple-ios18.0', '-c', str(source), '-o', str(air))
        run('xxd', '-n', name, '-i', str(air), str(headers / f'{name}.h'))
    text = (UPSTREAM / 'build/dxmt-ios/build.sh').read_text()
    text = text.replace('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
                        'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/dxmt-ios')))
    # Select the installed Metal tool. The AIR target and language remain the
    # original macOS 14 / Metal 3.1 values from Madeira's script.
    if subprocess.run(['xcrun', '--sdk', 'macosx', '--find', 'metal'], capture_output=True).returncode:
        text = text.replace('xcrun -sdk macosx metal', 'xcrun -sdk iphoneos metal')
    subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, check=True)
    run('xcrun', '--sdk', 'iphoneos', 'libtool', '-static', '-o', 'app/Madeira/libdxmt_combined.a',
        *map(str, sorted((UPSTREAM / 'build/dxmt-ios/obj').glob('*.o'))),
        *map(str, sorted((UPSTREAM / 'toolchains/llvm-ios-build/lib').glob('*.a'))))
    run('bash', 'build/madeira-dock/build.sh', '--check')


def native():
    verify_pin()
    stamp = UPSTREAM / '.build/iridium-native.json'
    key = hashlib.sha256((REVISION + inspect.getsource(build_native) + inspect.getsource(bootstrap)).encode()
                         + (ROOT / 'ci/runtime-inputs.json').read_bytes()
                         + compiler_identity().encode()).hexdigest()
    def digest(path):
        with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
    try:
        saved = json.loads(stamp.read_text())
        if saved['key'] == key and 0 <= time.time() - saved['completed'] < 14 * 86400 and saved['outputs'] and all(
            (UPSTREAM / name).is_file() and digest(UPSTREAM / name) == value for name, value in saved['outputs'].items()
        ):
            print('Reusing the completed Madeira native build. Inputs and archives match; retention is 14 days.')
            return
    except (OSError, ValueError, KeyError): pass
    bootstrap()
    build_native()
    outputs = sorted((UPSTREAM / 'app/Madeira').glob('*.a')) + sorted((UPSTREAM / 'FEX/build-ios').rglob('*.a'))
    outputs += [UPSTREAM / 'app/Madeira' / name for name in (
        'arm64ec-windows/dockhost.exe', 'arm64ec-windows/dock-notices.txt',
        'legal/LICENSES-rppairing-crates.txt')]
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(dict(key=key, completed=time.time(),
                                    outputs={str(path.relative_to(UPSTREAM)): digest(path) for path in outputs}), indent=2) + '\n')
    print('Saved the completed native build before app compilation and packaging.')


def app():
    subprocess.run([sys.executable, str(ROOT / 'ci/build-sameboy.py'),
                    '--output', str(ROOT / '.build/sameboy/iphoneos'),
                    '--sdk', 'iphoneos', '--target', 'arm64-apple-ios18.0'], check=True)
    prepare()
    command = ['xcodebuild', '-project', str(OUTPUT / 'app/Madeira.xcodeproj'),
               '-scheme', 'Iridium', '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
               '-derivedDataPath', str(ROOT / '.build/madeira-frontend-derived'),
               'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'DEVELOPMENT_TEAM=',
               'ENABLE_DEBUG_DYLIB=NO', 'LD_GENERATE_MAP_FILE=YES']
    if os.environ.get('IRIDIUM_BUILD_NUMBER'):
        value = os.environ['IRIDIUM_BUILD_NUMBER']
        if not all(part.isdigit() for part in value.split('.')): raise ValueError('Invalid build number')
        command.append('CURRENT_PROJECT_VERSION=' + value)
    subprocess.run(command + ['build'], cwd=ROOT, check=True)
    verify()
    check_bundle(ROOT / '.build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'verify', 'app', 'native', 'windows', 'toolchains', 'check-bundle'))
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    if args.action == 'check-bundle':
        if args.app is None: parser.error('check-bundle requires the built app path')
        check_bundle(args.app)
        print('The built app contains the pinned Madeira runtime farms, WoW64 and D3D12.')
    else:
        if args.app is not None: parser.error('Only check-bundle accepts an app path')
        {'prepare': prepare, 'verify': verify, 'app': app, 'native': native, 'windows': windows, 'toolchains': toolchains}[args.action]()
