#!/usr/bin/env python3
"""Build pinned Madeira components and route app commands to the packager."""
import engine_pins
import argparse
from pathlib import Path
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
import tempfile
import madeira_audio_volume
import madeira_threads
import madeira_managed_patches
import madeira_components

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/Madeira'
RUNTIME_BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
OUTPUT = ROOT / '.build/madeira-frontend'
REVISION = engine_pins.get('madeira')['revision']
FREETYPE_REVISION = engine_pins.get('madeira')['buildDependencies']['freetype']['revision']
CRYPTO_LIBRARIES = ('gnutls', 'hogweed', 'nettle', 'gmp')
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
        patched = madeira_managed_patches.expected(UPSTREAM, repo.name) if repo in (UPSTREAM / 'FEX', UPSTREAM / 'dxmt', UPSTREAM / 'madeira-dock') else {}
        for name, payload in patched.items():
            if name in changes and (repo / name).read_bytes() == payload: changes.remove(name)
        if repo == UPSTREAM / 'FEX':
            for managed, adapt in [('FEXCore/Source/Utils/AllocWatch.cpp', madeira_threads.apply_fex),
                                   ('Source/Windows/ARM64EC/Module.cpp', madeira_threads.apply_fex_arm64ec)]:
                if managed not in changes: continue
                original = patched.get(managed)
                if original is None: original = subprocess.check_output(['git', '-C', str(repo), 'show', 'HEAD:' + managed])
                original = original.decode()
                if (repo / managed).read_text() == adapt(original): changes.remove(managed)
        if any(Path(name).suffix in {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.cc', '.js', '.pbxproj', '.y', '.l',
                                     '.sh', '.rs', '.metal', '.S', '.inc', '.in', '.cmake'}
               or Path(name).name == 'CMakeLists.txt' for name in changes):
            raise ValueError(f'Pinned source has changes: {repo}. Preserve them before preparing the overlay.')
        if repo.parent == UPSTREAM:
            expected = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD:' + repo.name], text=True).strip()
            actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            if expected != actual: raise ValueError(f'Unexpected dependency revision: {repo.name}')


def check_psp_jit_interface(record):
    if ('_ir_native_psp_check_jit' not in record.get('exports', [])
        or '_ir_native_psp_check_jit_diagnostic' not in record.get('exports', [])
        or not {'_ir_native_psp_exec_version', '_ir_native_psp_exec_prepare_shared', '_ir_native_psp_exec_prepare', '_ir_native_psp_exec_prepare_diagnostic', '_ir_native_psp_exec_detach',
                '_ir_native_psp_exec_accept_shutdown', '_ir_native_psp_exec_restored', '_ir_native_psp_exec_restored_diagnostic', '_ir_native_psp_exec_advance',
                '_ir_native_psp_exec_cancel', '_ir_native_psp_exec_end'}.issubset(record.get('exports', []))
        or record.get('diagnosticHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITDiagnostic.h').read_bytes()).hexdigest()
        or record.get('sharedMemoryHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITMemory.h').read_bytes()).hexdigest()
        or record.get('executableMemoryHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPSPExecutableMemory.h').read_bytes()).hexdigest()
        or '_ir_native_psp_set_volume' not in record.get('exports', [])
        or record.get('audioVolumeHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRAudioVolume.h').read_bytes()).hexdigest()
        or record.get('optionsHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPPSSPPOptions.h').read_bytes()).hexdigest()
        or record.get('cheatsHeaderSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRCheats.h').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRAudioVolume.c') != hashlib.sha256((RUNTIME_BRIDGE / 'IRAudioVolume.c').read_bytes()).hexdigest()
        or record.get('adapterSHA256') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPPSSPPNative.mm').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRPSPExecutableMemory.cpp') != hashlib.sha256((RUNTIME_BRIDGE / 'IRPSPExecutableMemory.cpp').read_bytes()).hexdigest()
        or record.get('compiledInputSHA256', {}).get('Iridium/IRJITExecutionProbe.c') != hashlib.sha256((RUNTIME_BRIDGE / 'IRJITExecutionProbe.c').read_bytes()).hexdigest()):
        raise ValueError('Rebuild the PSP component with the matching JIT validation interface')


def compiler_tools():
    tools = (['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'],
             ['xcrun', '--sdk', 'iphoneos', 'metal', '--version'],
             ['xcrun', '--sdk', 'iphoneos', 'clang', '--version'], ['rustc', '-vV'],
             ['cmake', '--version'], ['meson', '--version'], ['clang', '--version'],
             ['bison', '--version'], ['flex', '--version'])
    record = {}
    for tool in tools:
        executable = shutil.which(tool[0])
        if executable is None: raise ValueError('Missing native build tool: ' + tool[0])
        version = subprocess.check_output(tool, text=True).strip()
        # Metal's mount changes after a restart; its version and target are inputs.
        if 'metal' in tool:
            version = '\n'.join(line for line in version.splitlines() if not line.startswith('InstalledDir:'))
        record[' '.join(tool)] = {'executable': str(Path(executable).resolve()), 'version': version}
        if tool[0] in ('bison', 'flex'):
            record[' '.join(tool)]['sha256'] = file_digest(Path(executable))
    return record


def compiler_identity():
    return hashlib.sha256(json.dumps(compiler_tools(), sort_keys=True).encode()).hexdigest()


def windows():
    """Build the untracked i386 farm using Madeira's original recipe."""
    verify_pin()
    madeira_components.build(UPSTREAM, compiler_identity())
    recipe = UPSTREAM / 'build/wine-i386/build.sh'
    stamp = UPSTREAM / '.build/iridium-i386.json'
    key = hashlib.sha256(REVISION.encode() + inspect.getsource(windows).encode()
                         + inspect.getsource(run_checked_recipe).encode() + recipe.read_bytes()
                         + compiler_identity().encode()
                         + madeira_components.windows_symbol_recipe()
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
    run_checked_recipe('wine-i386', env=env)
    outputs = sorted(path for path in (UPSTREAM / 'app/Madeira/i386-windows').glob('*')
                     if path.is_file() and not path.name.startswith('.'))
    if not outputs: raise ValueError('Madeira built no i386 runtime files')
    madeira_components.trim_windows_symbols(UPSTREAM, outputs)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(dict(key=key, completed=time.time(),
                                    outputs={str(path.relative_to(UPSTREAM)): digest(path) for path in outputs}), indent=2) + '\n')
    print('Saved the completed i386 build before app compilation and packaging.')


def toolchains():
    """Prepare locked tools and FreeType source even when outputs are restored."""
    spec = importlib.util.spec_from_file_location('fetch_inputs', ROOT / 'ci/fetch-runtime-inputs.py')
    fetcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fetcher)
    for entry in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()):
        if entry['name'] not in ('llvm', 'llvm-mingw'): continue
        entry = dict(entry, destination=entry['destination'].replace('testrepos/Madeira/', 'vendor/Madeira/', 1))
        if not (ROOT / entry['destination']).exists(): fetcher.fetch(ROOT, entry)
    prepare_freetype()


def prepare_freetype():
    """Prepare the pinned source before fingerprinting or restoring native outputs."""
    source = UPSTREAM / 'research/freetype'
    if not source.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', 'VER-2-13-3',
                        'https://github.com/freetype/freetype.git', str(source)], check=True)
    if (source / '.git').exists():
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    else:
        revision = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())['vendor/Madeira/research/freetype']
    if revision != FREETYPE_REVISION: raise ValueError('Unexpected FreeType revision')


def stage_crypto_libraries():
    archives = [UPSTREAM / 'toolchains/gnutls-ios/lib' / f'lib{name}.a' for name in CRYPTO_LIBRARIES]
    if any(not path.is_file() or not path.stat().st_size for path in archives):
        raise ValueError('The rebuilt crypto libraries are missing or empty')
    for path in archives: shutil.copy2(path, UPSTREAM / 'app/Madeira' / path.name)
    return archives


def run_checked_recipe(name, env=None):
    """Keep upstream retries, but never install outputs after failed compilation."""
    text = (UPSTREAM / 'build' / name / 'build.sh').read_text()
    if name == 'ntdll-unix':
        generated_audio = OUTPUT / 'embedding/audio_null_ios.c'
        generated_audio.parent.mkdir(parents=True, exist_ok=True)
        original_audio = UPSTREAM / 'build/ntdll-unix/audio_null_ios.c'
        generated_audio.write_text(madeira_audio_volume.apply(original_audio.read_text()))
        patches = [
            ('compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"',
             'compile_one ' + shlex.quote(str(generated_audio)) + ' "audio_null_ios"'),
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/ntdll-unix'))),
            ('echo "Results: $SUCCEEDED succeeded, $FAILED failed"',
             'echo "Results: $SUCCEEDED succeeded, $FAILED failed"\n[ "$FAILED" -eq 0 ] || exit 1')]
        for source, object_name in [('process_ios.c', 'process'), ('thread_ios.c', 'thread')]:
            generated = OUTPUT / 'embedding' / source
            original = UPSTREAM / 'build/ntdll-unix' / source
            generated.write_text(madeira_threads.apply(original.read_text(), source, RUNTIME_BRIDGE / 'IRWindowsThreads.h'))
            patches.append(('compile_one "$BUILD_DIR/' + source + '" "' + object_name + '"',
                            'compile_one ' + shlex.quote(str(generated)) + ' "' + object_name + '" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/server_ios.c'
        generated.write_text(madeira_threads.apply_process_server((UPSTREAM / 'build/ntdll-unix/server_ios.c').read_text()))
        patches.append(('compile_one "$BUILD_DIR/server_ios.c" "server"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "server" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/file_ios.c'
        generated.write_text(madeira_threads.apply_file((UPSTREAM / 'wine/dlls/ntdll/unix/file.c').read_text()))
        patches.append(('    case "$name" in\n        loader)',
                        '    case "$name" in\n        file)\n            compile_one ' + shlex.quote(str(generated)) + ' "file"\n            ;;\n        loader)'))
        generated = OUTPUT / 'embedding/loader_ios.c'
        generated.write_text(madeira_threads.apply_loader((UPSTREAM / 'build/ntdll-unix/loader_ios.c').read_text()))
        patches.append(('compile_one "$BUILD_DIR/loader_ios.c" "loader"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "loader" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/signal_arm64_ios.c'
        generated.write_text(madeira_threads.apply_signal((UPSTREAM / 'build/ntdll-unix/signal_arm64_ios.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsThreads.h'))
        patches.append(('compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "signal_arm64" -I"$BUILD_DIR"'))
        generated = OUTPUT / 'embedding/virtual_ios.c'
        madeira_threads.verify_futex_layout((UPSTREAM / 'wine/dlls/ntdll/unix/sync.c').read_text(),
                                           (UPSTREAM / 'wine/dlls/ntdll/sync.c').read_text())
        generated.write_text(madeira_threads.apply_virtual((UPSTREAM / 'build/ntdll-unix/virtual_ios.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsJITPool.h'))
        patches.append(('compile_one "$BUILD_DIR/virtual_ios.c" "virtual"',
                        'compile_one ' + shlex.quote(str(generated)) + ' "virtual" -I"$BUILD_DIR"'))
    elif name == 'wineserver':
        generated = OUTPUT / 'embedding/mach_ios.c'
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text(madeira_threads.apply_server((UPSTREAM / 'build/wineserver/mach_ios.c').read_text()))
        patches = [
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/wineserver'))),
            ('"mach_ios:mach_ios.c:mach.o"', '"mach_ios:' + str(generated) + ':mach.o"')]
    elif name == 'win32u-unix':
        generated = OUTPUT / 'embedding/window_ios.c'
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text(madeira_threads.apply_window((UPSTREAM / 'wine/dlls/win32u/window.c').read_text()))
        classes = OUTPUT / 'embedding/class_ios.c'
        classes.write_text(madeira_threads.apply_class((UPSTREAM / 'build/win32u-unix/class_ios.c').read_text()))
        for unit, adapt in [('dc', madeira_threads.apply_dc), ('gdiobj', madeira_threads.apply_gdi)]:
            (OUTPUT / ('embedding/' + unit + '_ios.c')).write_text(adapt((UPSTREAM / 'wine/dlls/win32u' / (unit + '.c')).read_text()))
        patches = [
            ('BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"',
             'BUILD_DIR=' + shlex.quote(str(UPSTREAM / 'build/win32u-unix'))),
            ('    case "$name" in', '    case "$name" in\n        window)\n            compile_one '
             + shlex.quote(str(generated)) + ' "window"\n            continue\n            ;;')]
        for unit in ('dc', 'gdiobj'):
            patches.append(('    case "$name" in', '    case "$name" in\n        ' + unit + ')\n            compile_one '
                            + shlex.quote(str(OUTPUT / ('embedding/' + unit + '_ios.c'))) + ' "' + unit + '"\n            continue\n            ;;'))
        patches.append(('compile_one "$BUILD_DIR/class_ios.c" "class"',
                        'compile_one ' + shlex.quote(str(classes)) + ' "class"'))
        patches.append(('ar rcs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR"/*.o',
                        'rm -f "$OBJ_DIR/libwin32u_unix.a"\nar rcs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR"/*.o'))
    elif name == 'fex-arm64ec':
        for relative, adapt in [('FEXCore/Source/Utils/AllocWatch.cpp', madeira_threads.apply_fex),
                                ('Source/Windows/ARM64EC/Module.cpp', madeira_threads.apply_fex_arm64ec)]:
            source = UPSTREAM / 'FEX' / relative
            original = source.read_text()
            patched = adapt(original)
            if original != patched: source.write_text(patched)
        patches = [('R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"',
                    'R=' + shlex.quote(str(UPSTREAM)))]
    elif name == 'wine-i386':
        patches = [
            ('R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"', 'R=' + shlex.quote(str(UPSTREAM))),
            ('make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1\nset -e',
             'make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1\nBUILD_STATUS=$?\nset -e'),
            ('    [ -f "$t" ] && continue', '    [ "$BUILD_STATUS" -eq 0 ] && [ -f "$t" ] && continue')]
    else: raise ValueError('Unsupported checked native recipe: ' + name)
    for old, new in patches:
        if text.count(old) != 1: raise ValueError('Upstream build recipe changed: ' + name)
        text = text.replace(old, new)
    subprocess.run(['bash'], input=text, text=True, cwd=UPSTREAM, env=env, check=True)


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
    crypto = UPSTREAM / 'toolchains/gnutls-ios'
    if (not (crypto / 'include/gnutls/gnutls.h').is_file() or any(
            not (crypto / 'lib' / f'lib{name}.a').is_file()
            or not (crypto / 'lib' / f'lib{name}.a').stat().st_size for name in CRYPTO_LIBRARIES)):
        subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=UPSTREAM / 'build/gnutls-ios/src', check=True)
        subprocess.run(['bash', 'build/gnutls-ios/build.sh'], cwd=UPSTREAM, check=True)


def build_native():
    """Build the upstream archives, including the absent cold-build server base."""
    verify_pin()
    subprocess.run(['bash', str(UPSTREAM / 'build/fex-patches/apply.sh')], check=True)
    subprocess.run(['bash', str(UPSTREAM / 'build/dxmt-patches/apply.sh')], check=True)
    run_checked_recipe('fex-arm64ec')
    def run(*args): subprocess.run(args, cwd=UPSTREAM, check=True)
    for name in ('llvm-project/llvm', 'llvm-ios-build/lib', 'gnutls-ios/include'):
        if not (UPSTREAM / 'toolchains' / name).is_dir():
            raise ValueError('Prepare the upstream toolchain first: toolchains/' + name)
    run('rustup', 'target', 'add', 'aarch64-apple-ios')
    run('bash', 'build/rppairing-ios/build.sh')
    run('bash', 'build/ffmpeg/build.sh')
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
    for component in ('wineserver', 'ntdll-unix', 'win32u-unix'):
        run_checked_recipe(component)
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
    metal = OUTPUT / 'embedding/winemetal_ios.c'
    metal.parent.mkdir(parents=True, exist_ok=True)
    metal.write_text(madeira_threads.apply_metal(
        (UPSTREAM / 'dxmt/src/winemetal/unix/winemetal_unix.c').read_text(), RUNTIME_BRIDGE / 'IRWindowsMetal.h'))
    signature = OUTPUT / 'embedding/dxbc_signature.cpp'
    signature.write_text(madeira_threads.apply_vertex_outputs(
        (UPSTREAM / 'dxmt/src/airconv/dxbc_signature.cpp').read_text()))
    marker = '    compile_cxx "$DXMT_SRC/airconv/$cpp" "$name"'
    if text.count(marker) != 1: raise ValueError('Madeira shader signature build recipe changed')
    text = text.replace(marker, '    if [ "$cpp" = dxbc_signature.cpp ]; then\n'
                        '        compile_cxx ' + shlex.quote(str(signature)) + ' "$name"\n'
                        '    else\n' + marker + '\n    fi')
    text = text.replace('INCLUDES="', 'INCLUDES="-iquote' + str(UPSTREAM / 'dxmt/src/airconv') + ' ', 1)
    marker = 'compile_objc "$DXMT_SRC/winemetal/unix/winemetal_unix.c" winemetal_unix'
    if text.count(marker) != 1: raise ValueError('Madeira Metal build recipe changed')
    text = text.replace(marker, 'INCLUDES="$INCLUDES -iquote' + str(UPSTREAM / 'dxmt/src/winemetal/unix')
                        + '"\ncompile_objc ' + shlex.quote(str(metal)) + ' winemetal_unix')
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
    # New upstream units must be present in the archives that the app links.
    for name, required in {'libwineserver.a': 'storage_device_ios.o',
                           'libdxmt_combined.a': 'madeira_sc_pack.o'}.items():
        members = subprocess.check_output(['xcrun', 'ar', '-t', str(UPSTREAM / 'app/Madeira' / name)], text=True).splitlines()
        if required not in members:
            raise ValueError('Missing required native archive member: ' + name + '/' + required)
    run('bash', 'build/madeira-dock/build.sh', '--check')


def file_digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_source_inventory():
    """List tracked source inputs, including initialized dependencies, without changing them."""
    if not (ROOT / '.git').exists():
        inventory = json.loads((ROOT / 'MADEIRA-NATIVE-SOURCES.json').read_text())
        expected = {'vendor/Madeira': REVISION, 'vendor/Madeira/research/freetype': FREETYPE_REVISION}
        expected.update({'vendor/Madeira/' + name: revision for name, revision in
                         json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']['dependencies'].items()})
        if (inventory.get('schema') != 1 or not isinstance(inventory.get('files'), dict) or not inventory['files']
                or any(inventory.get('revisions', {}).get(name) != revision for name, revision in expected.items())):
            raise ValueError('Missing or invalid native source inventory')
        return inventory
    files, revisions = {}, {}
    modules = madeira_components.contract(UPSTREAM)
    def visit(repo, revision, required=False):
        label = repo.relative_to(ROOT).as_posix()
        revisions[label] = revision
        if not (repo / '.git').exists():
            if required: raise ValueError('Native source is not initialized: ' + label)
            return
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revision: raise ValueError('Unexpected native source revision: ' + label)
        rows = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-r', '-z', 'HEAD'])
        for row in filter(None, rows.split(b'\0')):
            meta, name = row.split(b'\t', 1)
            mode, kind, blob = meta.decode().split()
            name = name.decode()
            if kind == 'commit':
                child = (repo / name).relative_to(UPSTREAM).as_posix()
                required_child = child in ('FEX', 'wine', 'dxmt', 'madeira-dock',
                    'FEX/External/fmt', 'FEX/External/range-v3', 'FEX/External/rpmalloc',
                    'FEX/External/unordered_dense', 'FEX/External/vixl', 'FEX/External/xxhash',
                    'FEX/Source/Common/cpp-optparse') or child.startswith('dxmt/')
                visit(repo / name, blob, required_child)
            elif kind == 'blob':
                relative = (repo / name).relative_to(UPSTREAM).as_posix()
                if relative not in native_required_outputs() and not (relative.startswith('app/Madeira/') and any(
                        modules.owns(component, relative.removeprefix('app/Madeira/')) for component in modules.CONTRACT)):
                    files[label + '/' + name] = mode
    visit(UPSTREAM, REVISION, True)
    visit(UPSTREAM / 'research/freetype', FREETYPE_REVISION, True)
    return {'schema': 1, 'files': files, 'revisions': revisions}


def native_source_identity():
    inventory = native_source_inventory()
    patches = {str(UPSTREAM.relative_to(ROOT) / component / name): payload for component in ('FEX', 'dxmt', 'madeira-dock')
               for name, payload in madeira_managed_patches.expected(UPSTREAM, component).items()} if (ROOT / '.git').exists() else {}
    digest = hashlib.sha256()
    for name, mode in sorted(inventory['files'].items()):
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not relative.is_relative_to('vendor/Madeira'):
            raise ValueError('Invalid native source path: ' + name)
        path = ROOT / relative
        if not path.resolve().is_relative_to(UPSTREAM.resolve()): raise ValueError('Native source escapes its tree: ' + name)
        if path.is_symlink():
            payload = os.readlink(path).encode()
            value = hashlib.sha256(payload).hexdigest()
            if path.is_file(): value += ':' + file_digest(path)
            observed_mode = '120000'
        elif path.is_file():
            if name == 'vendor/Madeira/FEX/FEXCore/Source/Utils/AllocWatch.cpp':
                value = hashlib.sha256(madeira_threads.apply_fex(patches.get(name, path.read_bytes()).decode()).encode()).hexdigest()
            elif name == 'vendor/Madeira/FEX/Source/Windows/ARM64EC/Module.cpp':
                value = hashlib.sha256(madeira_threads.apply_fex_arm64ec(patches.get(name, path.read_bytes()).decode()).encode()).hexdigest()
            else: value = hashlib.sha256(patches.get(name, path.read_bytes())).hexdigest()
            observed_mode = '100755' if path.stat().st_mode & 0o111 else '100644'
        else:
            raise ValueError('Missing native source file: ' + name)
        if mode not in ('100644', '100755', '120000'): raise ValueError('Invalid native source mode: ' + name)
        digest.update(json.dumps([name, observed_mode, value]).encode() + b'\n')
    return {'revisions': inventory['revisions'], 'trackedFiles': len(inventory['files']), 'sha256': digest.hexdigest()}


def native_inputs():
    tools = compiler_tools()
    bison = tools['bison --version']
    words = bison['version'].splitlines()[0].split() if bison['version'] else []
    major = words[-1].split('.')[0] if words else ''
    if not major.isdigit() or int(major) < 3:
        raise ValueError('Native build requires Bison >= 3.0 before bootstrap: ' + repr(bison))
    return {'revision': REVISION,
            'enginePin': engine_pins.selected('madeira-native', json.loads((ROOT / engine_pins.MANIFEST).read_text())),
            'recipes': {name: hashlib.sha256(inspect.getsource(fn).encode()).hexdigest() for name, fn in (
                ('build_native', build_native), ('bootstrap', bootstrap), ('toolchains', toolchains),
                ('prepare_freetype', prepare_freetype), ('verify_pin', verify_pin),
                ('native_source_inventory', native_source_inventory), ('native_source_identity', native_source_identity),
                ('run_checked_recipe', run_checked_recipe), ('stage_crypto_libraries', stage_crypto_libraries))},
            'files': {name: file_digest(ROOT / name) for name in (
                'ci/madeira_managed_patches.py', 'ci/madeira_components.py', 'ci/runtime-inputs.json', 'ci/local_build_tools.py', 'ci/fetch-runtime-inputs.py', 'ci/engine_pins.py', 'ci/madeira_audio_volume.py', 'ci/madeira_threads.py',
                'iridium/apps/ios/RuntimeBridge/IRAudioVolume.c', 'iridium/apps/ios/RuntimeBridge/IRAudioVolume.h',
                'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.c', 'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.h',
                'iridium/apps/ios/RuntimeBridge/IRWindowsMetal.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetalEvents.h')},
            'cryptoLibraries': list(CRYPTO_LIBRARIES), 'tools': tools, 'upstreamSources': native_source_identity()}


def native_key(inputs):
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def native_required_outputs():
    app = ['app/Madeira/lib' + name + '.a' for name in (
        'avcodec', 'avformat', 'avutil', 'swresample', 'dxmt_combined', 'madeira_rppairing',
        'ntdll_unix', 'win32u_unix', 'wineserver', *CRYPTO_LIBRARIES)]
    fex = ['FEX/build-ios/' + name for name in (
        'External/SoftFloat-3e/libsoftfloat_3e.a', 'External/cephes/libcephes_128bit.a',
        'External/fmt/libfmt.a', 'External/xxhash/cmake_unofficial/libxxhash.a',
        'FEXCore/Source/libFEXCore.a', 'FEXCore/Source/libFEXCore_Base.a', 'FEXCore/Source/libJemallocLibs.a')]
    return app + fex + ['toolchains/gnutls-ios/lib/lib' + name + '.a' for name in CRYPTO_LIBRARIES] + [
        'app/Madeira/arm64ec-windows/dockhost.exe', 'app/Madeira/arm64ec-windows/dock-notices.txt',
        'app/Madeira/arm64ec-windows/xtajit64.dll',
        'app/Madeira/legal/LICENSES-rppairing-crates.txt']


def native_record_issues(saved, inputs, upstream):
    """Validate portable relative outputs without touching the stamp or compiler trees."""
    issues = []
    if not isinstance(saved, dict): return ['invalid_record: expected an object']
    if saved.get('schema') != 2 or isinstance(saved.get('schema'), bool) or saved.get('state') != 'complete':
        issues.append('incomplete_record: schema=' + repr(saved.get('schema')) + ' state=' + repr(saved.get('state')))
    if saved.get('key') != native_key(inputs):
        issues.append('key_mismatch saved=' + repr(saved.get('key')) + ' current=' + native_key(inputs))
    def compare(old, new, label):
        if isinstance(old, dict) and isinstance(new, dict):
            for name in sorted(old.keys() | new.keys()):
                compare(old.get(name), new.get(name), label + '.' + name)
        elif old != new:
            issues.append('input_mismatch:' + label + ' saved=' + repr(old) + ' current=' + repr(new))
    compare(saved.get('inputs'), inputs, 'inputs')
    completed = saved.get('completed')
    now = time.time()
    if (isinstance(completed, bool) or not isinstance(completed, (int, float))
            or not 0 <= now - completed < 14 * 86400):
        issues.append('completion_expired_or_invalid completed=' + repr(completed)
                      + ' now=' + repr(now) + ' retentionSeconds=' + str(14 * 86400))
    outputs = saved.get('outputs')
    if not isinstance(outputs, dict) or not outputs: return issues + ['missing_outputs']
    present = {str(path.relative_to(upstream)) for path in (upstream / 'app/Madeira').glob('*.a')}
    present.update(str(path.relative_to(upstream)) for path in (upstream / 'FEX/build-ios').rglob('*.a'))
    for name in sorted((set(native_required_outputs()) | present) - outputs.keys()):
        issues.append('unrecorded_output:' + name)
    for name, expected in sorted(outputs.items()):
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or path.as_posix() != name:
            issues.append('invalid_output_path:' + name)
            continue
        path = upstream / path
        try:
            if path.is_symlink() or not path.resolve().is_relative_to(upstream.resolve()):
                issues.append('invalid_output_path:' + name)
            elif not path.is_file() or not path.stat().st_size:
                issues.append('missing_output:' + name)
            else:
                observed = file_digest(path)
                if observed != expected:
                    issues.append('changed_output:' + name + ' saved=' + str(expected) + ' current=' + observed)
        except OSError as error:
            issues.append('unreadable_output:' + name + ' ' + str(error))
    return issues


def validate_native_reuse(upstream=None, inputs=None):
    upstream = UPSTREAM if upstream is None else upstream
    inputs = native_inputs() if inputs is None else inputs
    stamp = upstream / '.build/iridium-native.json'
    try:
        if stamp.is_symlink(): raise ValueError('Completion record must not be a symlink')
        issues = native_record_issues(json.loads(stamp.read_text()), inputs, upstream)
    except (OSError, ValueError) as error:
        issues = ['unreadable_record:' + str(error)]
    print(json.dumps({'component': 'madeira-native', 'reuse': not issues, 'key': native_key(inputs),
                      'issues': issues}, sort_keys=True), flush=True)
    if issues: raise ValueError('Madeira native reuse rejected: ' + '; '.join(issues))


def native_substages():
    return ('toolchains/llvm-host-build', 'toolchains/llvm-ios-build', 'toolchains/gnutls-ios',
             'toolchains/ffmpeg-ios', 'build/ffmpeg/obj', 'build/gnutls-ios/obj', 'build/wineserver/obj',
             'build/ntdll-unix/obj', 'build/win32u-unix/obj', 'build/dxmt-ios/obj',
             'build/dxmt-ios/shader-headers', 'build/dxmt-ios/libdxmt_combined.a',
             'build/dxmt-ios/libdxmt_unix.a', 'FEX/build-ios', 'FEX/build-arm64ec', 'build/freetype-ios/build',
             'wine/build-macos', 'build/rppairing-ios/target')


def native_partial_outputs():
    outputs = {}
    bases = [UPSTREAM / name for name in native_substages()]
    bases += list((UPSTREAM / 'app/Madeira').glob('*.a'))
    bases += [UPSTREAM / name for name in native_required_outputs()]
    for base in bases:
        for path in base.rglob('*') if base.is_dir() else (base,):
            if path.is_file():
                if not path.resolve().is_relative_to(UPSTREAM.resolve()): raise ValueError('Native partial output escapes its tree')
                outputs[str(path.relative_to(UPSTREAM))] = file_digest(path)
    return outputs


def require_fresh_native_substages():
    existing = [name for name in native_substages() if (UPSTREAM / name).exists() or (UPSTREAM / name).is_symlink()]
    if existing:
        raise ValueError('Unverified native substages exist: ' + ', '.join(existing))


def validate_incremental_native(inputs, upstream=UPSTREAM):
    """Allow compiler work directories only from a checked, compatible prior build."""
    saved = json.loads((upstream / '.build/iridium-native.json').read_text())
    previous = saved.get('inputs', {})
    issues = native_record_issues(saved, previous, upstream)
    if issues: raise ValueError('Incremental native base rejected: ' + '; '.join(issues))
    for name in ('tools', 'recipes', 'cryptoLibraries'):
        if previous.get(name) != inputs.get(name):
            raise ValueError('Incremental native configuration changed: ' + name)
    def configuration(value):
        return {key: item for key, item in value.get('enginePin', {}).items() if key != 'revision'}
    if not configuration(previous) or configuration(previous) != configuration(inputs):
        raise ValueError('Incremental native engine configuration changed')
    subprocess.run(['git', '-C', str(upstream), 'merge-base', '--is-ancestor',
                    previous['revision'], inputs['revision']], check=True)
    print('Checked prior native outputs and compiler configuration; rebuilding every native recipe incrementally.', flush=True)


def native(reuse_only=False, incremental=False):
    verify_pin()
    inputs = native_inputs()
    try:
        validate_native_reuse(inputs=inputs)
        return
    except ValueError:
        if reuse_only: raise
    progress = UPSTREAM / '.build/iridium-native-in-progress.json'
    try:
        if progress.is_symlink(): raise ValueError('Native progress record is a link')
        saved_progress = json.loads(progress.read_text())
    except (OSError, ValueError): saved_progress = {}
    expected_progress = {'schema': 1, 'state': 'failed', 'key': native_key(inputs), 'workspace': str(ROOT.resolve())}
    valid = all(saved_progress.get(key) == value for key, value in expected_progress.items())
    if not valid or not saved_progress.get('outputs') or saved_progress['outputs'] != native_partial_outputs():
        if incremental: validate_incremental_native(inputs)
        else: require_fresh_native_substages()
    progress.parent.mkdir(parents=True, exist_ok=True)
    progress.write_text(json.dumps(dict(expected_progress, state='building')) + '\n')
    try:
        bootstrap()
        build_native()
    except BaseException:
        progress.write_text(json.dumps(dict(expected_progress, outputs=native_partial_outputs()), sort_keys=True) + '\n')
        raise
    crypto = stage_crypto_libraries()
    outputs = sorted((UPSTREAM / 'app/Madeira').glob('*.a')) + sorted((UPSTREAM / 'FEX/build-ios').rglob('*.a'))
    outputs += crypto
    outputs += [UPSTREAM / 'app/Madeira' / name for name in (
        'arm64ec-windows/dockhost.exe', 'arm64ec-windows/dock-notices.txt',
        'arm64ec-windows/xtajit64.dll',
        'legal/LICENSES-rppairing-crates.txt')]
    if native_inputs() != inputs:
        raise ValueError('Native inputs changed during compilation; completion record not written')
    saved = dict(schema=2, state='complete', key=native_key(inputs), inputs=inputs, completed=time.time(),
                 outputs={str(path.relative_to(UPSTREAM)): file_digest(path) for path in outputs})
    issues = native_record_issues(saved, inputs, UPSTREAM)
    if issues: raise ValueError('Native build is incomplete: ' + '; '.join(issues))
    stamp = UPSTREAM / '.build/iridium-native.json'
    stamp.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=stamp.parent, prefix='iridium-native-', delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(json.dumps(saved, indent=2) + '\n')
    try:
        temporary.replace(stamp)
    finally:
        temporary.unlink(missing_ok=True)
    progress.unlink(missing_ok=True)
    print('Saved the completed native build before app compilation and packaging.')


if __name__ == '__main__':
    compiler_actions = ('native', 'windows', 'toolchains')
    action = next((arg for arg in sys.argv[1:] if not arg.startswith('-')), None)
    if action is not None and action not in compiler_actions:
        # Keep the public app commands while letting their parser evolve separately.
        import madeira_app
        madeira_app.main()
        raise SystemExit(0)
    parser = argparse.ArgumentParser(description=__doc__, epilog='App commands: app, prepare, verify, check-bundle.')
    parser.add_argument('action', choices=compiler_actions)
    parser.add_argument('--reuse-only', action='store_true', help='Validate completed native outputs without building or writing')
    parser.add_argument('--incremental-native', action='store_true', help='Rebuild native recipes from a verified compatible prior build')
    args = parser.parse_args()
    if args.reuse_only and args.action != 'native': parser.error('--reuse-only requires native')
    if args.incremental_native and (args.action != 'native' or args.reuse_only): parser.error('--incremental-native requires native without --reuse-only')
    {'native': lambda: native(reuse_only=args.reuse_only, incremental=args.incremental_native),
     'windows': windows, 'toolchains': toolchains}[args.action]()
