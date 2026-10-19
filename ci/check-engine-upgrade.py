#!/usr/bin/env python3
"""Check native API compatibility of a local Madeira source candidate (no pin update)."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'ci/engine-integrations/madeira-api.json'
PREFIXES = ('jit_', 'jit26_', 'fex_', 'wine', 'winios_', 'madeira_', 'Madeira', 'lzma_', 'zstd_', 'zip_')


def native_api(candidate):
    header = candidate / 'app/Madeira/Madeira-Bridging-Header.h'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    result = subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-fmodules', '-x', 'objective-c',
        '-target', 'arm64-apple-ios18.0', '-isysroot', sdk, '-Xclang', '-ast-dump=json',
        '-fsyntax-only', str(header)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Candidate native headers do not compile:\n' + result.stderr[-4000:])
    return api_from_ast(json.loads(result.stdout))


def api_from_ast(ast):
    declarations = ast.get('inner', [])
    functions = {n['name']: n['type']['qualType'] for n in declarations
        if n.get('kind') in ('FunctionDecl', 'VarDecl') and n.get('name', '').startswith(PREFIXES)
        and not n.get('inline')}
    # Public struct field changes and callback typedef changes matter even when
    # the outer function spelling stays identical. System SDK declarations do not.
    records = {n['name']: [(v.get('name', ''), v['type']['qualType']) for v in n.get('inner', [])
        if v['kind'] == 'FieldDecl'] for n in declarations if n['kind'] == 'RecordDecl'
        and n.get('name', '').startswith(('winios_', 'JITRegion', 'MadeiraRPPairing')) and n.get('completeDefinition')}
    aliases = {n['name']: n['type']['qualType'] for n in declarations
        if n['kind'] == 'TypedefDecl' and n.get('name', '').startswith(PREFIXES + ('JITRegion',))}
    return dict(functions=functions, records=records, aliases=aliases)


def compare(expected, actual):
    failures = []
    for category, declarations in expected.items():
        for name, signature in declarations.items():
            if name not in actual.get(category, {}): failures.append('removed ' + name)
            elif actual[category][name] != signature: failures.append('changed ' + name)
    if failures: raise ValueError('Native adapter compatibility failed: ' + ', '.join(failures))


def check(candidate):
    contract = json.loads(CONTRACT.read_text())
    # JSON normalizes tuples to lists in recorded struct fields.
    actual = json.loads(json.dumps(native_api(candidate)))
    compare(contract['api'], actual)
    return {'candidate': str(candidate.resolve()), 'contractRevision': contract['madeiraRevision'],
        'functions': len(contract['api']['functions']), 'records': len(contract['api']['records']),
        'result': 'compatible', 'scope': 'native header API; run native build, integration tests and app checks before updating a pin'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--madeira-source', type=Path, default=ROOT / 'vendor/Madeira')
    args = parser.parse_args()
    try: print(json.dumps(check(args.madeira_source), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr); sys.exit(1)
