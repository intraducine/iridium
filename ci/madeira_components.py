"""Build pinned Madeira runtime modules with receipts, without duplicate binary caches."""
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile

EXTRA = ('windows', 'moltenvk', 'zink', 'mesa-d3d12', 'vulkan-pe', 'kosmickrisp')


def contract(upstream):
    spec = importlib.util.spec_from_file_location('madeira_component_contract', upstream / 'tools/build/runtime-components.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if 'windows' in module.CONTRACT:
        module.CONTRACT['windows']['inputs'].append('build/gog-galaxy-service/**')
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
        files = {p.relative_to(bundle).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in bundle.rglob('*') if p.is_file() and module.owns(name, p.relative_to(bundle).as_posix())}
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
