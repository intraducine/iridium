"""Build pinned Madeira runtime modules with receipts, without duplicate binary caches."""
import hashlib
import importlib.util
import inspect
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import struct
import subprocess
import tempfile

EXTRA = ('windows', 'moltenvk', 'zink', 'mesa-d3d12', 'vulkan-pe', 'kosmickrisp')


def strip_pe_symbols(data, objcopy):
    if len(data) < 64 or data[:2] != b'MZ':
        return data
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe < 64 or pe + 26 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        return data
    sections = struct.unpack_from('<H', data, pe + 6)[0]
    fields = pe + 12
    symbols, count = struct.unpack_from('<II', data, fields)
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    directories = {0x10b: 96, 0x20b: 112}.get(struct.unpack_from('<H', data, pe + 24)[0])
    if directories is None or optional_size < directories + 5 * 8:
        return data
    optional_end = pe + 24 + optional_size
    certificate = pe + 24 + directories + 4 * 8
    strings = symbols + count * 18
    section_end = optional_end + sections * 40
    if not sections or not count or symbols < section_end or strings + 4 > len(data):
        return data
    # Keep Authenticode and images whose loader can require a nonzero PE checksum.
    checksum = pe + 24 + 64
    if any(data[certificate:certificate + 8]) or any(data[checksum:checksum + 4]):
        return data
    for section in range(optional_end, section_end, 40):
        raw_size, raw_offset, _, _, relocations, lines = struct.unpack_from('<IIIIHH', data, section + 16)
        # Long section names use the COFF string table.
        if (data[section:section + 1] == b'/' or raw_offset + raw_size > symbols
                or relocations or lines):
            return data
    length = struct.unpack_from('<I', data, strings)[0]
    if length < 4 or strings + length > len(data) or any(data[strings + length:]):
        return data

    result = subprocess.run([objcopy, '--strip-all', '-', '-'], input=data, capture_output=True)
    stripped = result.stdout
    # Keep every original byte before the tables except the two COFF symbol fields.
    if (result.returncode or not symbols <= len(stripped) < len(data)
            or stripped[:fields] != data[:fields] or stripped[fields:fields + 8] != bytes(8)
            or stripped[fields + 8:symbols] != data[fields + 8:symbols] or any(stripped[symbols:])):
        return data
    return stripped


def trim_windows_symbols(upstream, paths):
    objcopy = upstream / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-objcopy'
    saved = 0
    for path in paths:
        if path.is_symlink() or path.suffix.lower() not in ('.dll', '.exe', '.drv'):
            continue
        original = path.read_bytes()
        stripped = strip_pe_symbols(original, objcopy)
        if stripped is original:
            continue
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
        try:
            temporary.write_bytes(stripped)
            shutil.copymode(path, temporary)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        saved += len(original) - len(stripped)
    print(f'Removed {saved:,} bytes of Windows symbol tables.')


def windows_symbol_recipe():
    return ''.join(inspect.getsource(fn) for fn in (strip_pe_symbols, trim_windows_symbols)).encode()


def contract(upstream):
    spec = importlib.util.spec_from_file_location('madeira_component_contract', upstream / 'tools/build/runtime-components.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if 'windows' in module.CONTRACT:
        module.CONTRACT['windows']['inputs'].append('build/gog-galaxy-service/**')
        upstream_key = module.input_key

        def input_key(name, sdk):
            key = upstream_key(name, sdk)
            if name == 'windows':
                return hashlib.sha256(key.encode() + windows_symbol_recipe()).hexdigest()
            return key

        module.input_key = input_key
    if not (upstream / '.git').exists():
        inventory = json.loads((upstream / 'iridium-runtime-sources.json').read_text())
        if inventory.get('schema') != 1 or not isinstance(inventory.get('files'), list) or not isinstance(inventory.get('pins'), dict):
            raise ValueError('Invalid runtime source inventory')
        for path in inventory['files']: module.safe_path(path)
        def source_git(*args):
            if args == ('ls-files', '--cached', '--others', '--exclude-standard') or args == ('ls-files',):
                return '\n'.join(inventory['files'])
            if args == ('ls-files', 'app/Madeira'):
                return '\n'.join(p for p in inventory['files'] if p.startswith('app/Madeira/'))
            if len(args) == 2 and args[0] == 'rev-parse' and args[1].startswith('HEAD:'):
                return inventory['pins'][args[1][5:]]
            raise ValueError('Unsupported source inventory request: ' + repr(args))
        module.git = source_git
    return module


def source_inventory(upstream):
    module = contract(upstream)
    pins = {p for item in module.CONTRACT.values() for p in item['pins']}
    return {'schema': 1, 'files': module.git('ls-files', '--cached', '--others', '--exclude-standard').splitlines(),
            'pins': {p: module.git('rev-parse', 'HEAD:' + p) for p in sorted(pins)}}


def unsigned_digest(path):
    # Compare actual code after removing only signatures from disposable copies.
    with tempfile.TemporaryDirectory(prefix='iridium-module-signature-') as folder:
        copy = Path(folder) / path.name
        shutil.copyfile(path, copy)
        result = subprocess.run(['/usr/bin/codesign', '--remove-signature', str(copy)], capture_output=True, text=True)
        if result.returncode and 'code object is not signed at all' not in result.stderr:
            raise ValueError('Could not normalize module signature: ' + result.stderr)
        return hashlib.sha256(copy.read_bytes()).hexdigest()


def prepare_source_metadata(upstream):
    """Restore recipe Git metadata after source archive extraction, without checking out files."""
    root = upstream.parents[1]
    if (root / '.git').exists(): return
    revisions = json.loads((root / 'SOURCE-REVISIONS.json').read_text())
    pins = json.loads((root / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']
    sources = [(upstream, pins['upstream'], pins['revision'])]
    inventory = json.loads((upstream / 'iridium-runtime-sources.json').read_text())
    for item in inventory.get('gitSources', []):
        name = item['path']
        path = root / name
        if not path.resolve().is_relative_to(upstream.resolve()) or revisions.get(name) != item['revision']:
            raise ValueError('Invalid graphics source metadata: ' + name)
        sources.append((path, item['url'], item['revision']))
    def metadata(repo, url, revision):
        if (repo / '.git').exists(): return
        if not repo.is_dir() or not re.fullmatch('[0-9a-f]{40}', revision) or not url.startswith('https://'):
            raise ValueError('Invalid runtime source checkout: ' + str(repo))
        subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(repo), 'fetch', '--depth', '1', url, revision], check=True)
        # Mixed reset changes only the index and HEAD. Replacement source files stay intact.
        subprocess.run(['git', '-C', str(repo), 'reset', '--mixed', revision], check=True, stdout=subprocess.DEVNULL)
    while sources:
        repo, url, revision = sources.pop(0)
        metadata(repo, url, revision)
        config = repo / '.gitmodules'
        if not config.is_file(): continue
        rows = subprocess.check_output(['git', 'config', '-f', str(config), '--get-regexp', r'^submodule\..*\.path$'], text=True)
        for row in rows.splitlines():
            key, path = row.split(' ', 1)
            child = repo / path
            name = child.relative_to(root).as_posix()
            if name not in revisions: continue
            url = subprocess.check_output(['git', 'config', '-f', str(config), '--get', key.removesuffix('.path') + '.url'], text=True).strip()
            sources.append((child, url, revisions[name]))


def build_recipe(upstream, name, env):
    script = (upstream / 'tools/build/build-runtime-component.sh').read_text()
    replacements = {
        'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"': 'ROOT=' + shlex.quote(str(upstream)),
        '[ ${#deps[@]} -eq 0 ] || brew install "${deps[@]}"':
            'for dep in "${deps[@]}"; do brew list --versions "$dep" >/dev/null 2>&1 || brew install "$dep"; done',
        'git -C "$ROOT" submodule update --init --recursive wine dxmt FEX':
            'git -C "$ROOT" submodule update --init wine dxmt FEX\n'
            '    git -C "$ROOT/FEX" submodule update --init External/fmt External/range-v3 External/rpmalloc '
            'External/unordered_dense External/vixl External/xxhash Source/Common/cpp-optparse\n'
            '    git -C "$ROOT/dxmt" submodule update --init --recursive',
        'xcodebuild -downloadComponent MetalToolchain':
            'xcrun --sdk iphoneos --find metal >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain',
    }
    for old, new in replacements.items():
        if script.count(old) != 1: raise ValueError('Madeira component bootstrap changed: ' + old)
        script = script.replace(old, new)
    if name == 'windows':
        script += '\nGOG_CC="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-clang" bash "$ROOT/build/gog-galaxy-service/build.sh"\n'
    # Installers may read stdin; keep it separate from the remaining shell program.
    subprocess.run(['bash', '-c', script, '--', name], stdin=subprocess.DEVNULL, text=True,
                   cwd=upstream, env=env, check=True)


def build(upstream, sdk):
    prepare_source_metadata(upstream)
    module = contract(upstream)
    for name in EXTRA:
        receipt = upstream / '.build' / ('iridium-' + name + '.json')
        try:
            saved = json.loads(receipt.read_text())
            module.validate_manifest(name, saved, lambda p: module.read_regular(upstream / 'app/Madeira', p), sdk)
            print('Reusing checked Madeira module: ' + name, flush=True)
            continue
        except (OSError, ValueError, KeyError):
            pass
        # Check the reserve before downloads, extraction and compiler output.
        free = shutil.disk_usage(upstream).free
        if free < 40 * 1024**3:
            raise ValueError('Madeira modules need 20 GiB reserve plus 20 GiB working space')
        env = dict(os.environ, JOBS=os.environ.get('JOBS', '6'), MADEIRA_RUNTIME_SDK=sdk)
        build_recipe(upstream, name, env)
        bundle = upstream / 'app/Madeira'
        owned = [p for p in bundle.rglob('*') if p.is_file() and module.owns(name, p.relative_to(bundle).as_posix())]
        if name == 'windows':
            # The ARM64EC translator also belongs to the native build checkpoint.
            unchanged = set(module.CONTRACT[name]['prebuilt']) | {'arm64ec-windows/xtajit64.dll'}
            trim_windows_symbols(upstream, (p for p in owned if p.relative_to(bundle).as_posix() not in unchanged))
        files = {p.relative_to(bundle).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in owned}
        saved = {'schema': 1, 'key': module.input_key(name, sdk), 'files': files}
        module.validate_manifest(name, saved, lambda p: module.read_regular(bundle, p), sdk)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(saved, sort_keys=True, indent=2) + '\n')


def verify(upstream, bundle, sdk):
    module = contract(upstream)
    receipts = {}
    for name in EXTRA:
        receipt = json.loads((upstream / '.build' / ('iridium-' + name + '.json')).read_text())
        # The source files must still match before Xcode re-signs staged dylibs.
        module.validate_manifest(name, receipt, lambda p: module.read_regular(upstream / 'app/Madeira', p), sdk)
        for path, sha in receipt['files'].items():
            data = module.read_regular(bundle, path)
            module.check_binary(path, data)
            if path.endswith('.dylib'):
                matches = unsigned_digest(upstream / 'app/Madeira' / path) == unsigned_digest(bundle / path)
            else:
                matches = hashlib.sha256(data).hexdigest() == sha
            if not matches: raise ValueError('Staged Madeira module differs: ' + path)
        receipts[name] = dict(receipt, files={p: hashlib.sha256(module.read_regular(bundle, p)).hexdigest() for p in receipt['files']})
    return receipts
