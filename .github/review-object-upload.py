#!/usr/bin/env python3
"""Temporary source transport: register an exact reviewed Git tree; never move refs."""
import argparse
import base64
import bz2
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

REPO = 'intraducine/iridium'
BASE = '976ed8ab9b2e0b0131aa1b20553d23514dd7517f'
EXPECTED_TREE = '1358f639b5f8c46dc77b3fb10a97136d3b3525e2'
EXPECTED_PAYLOAD = '015f0b4063f970d17ec0729cb581536a659464aa343baf4c802dc2fcf3083f79'
EXPECTED_PATCH = '4cb82b239772e68938eb7b0d3d6047bdc69213364cadb430bccbf8d717739817'

def git(root, *args, data=None):
    return subprocess.check_output(['git', '-C', str(root), *args], input=data)

def prepare(root, payload_file, work):
    chunks = [(payload_file / ('review-transfer-' + str(i) + '.txt')).read_bytes() for i in range(3)]
    # Correct the identified two-byte transport duplication, then check the full payload.
    # Accept only that exact immutable blob; any other corruption fails the checksum.
    duplicated = chunks[1]
    if hashlib.sha1(b'blob ' + str(len(duplicated)).encode() + b'\0' + duplicated).hexdigest() == '0a610bb647cbc2e64bb32460e12a6dbfdfae4260':
        chunks[1] = duplicated[:91] + duplicated[93:]
    raw = b''.join(chunks)
    if hashlib.sha256(raw).hexdigest() != EXPECTED_PAYLOAD:
        raise ValueError('Unexpected transfer payload')
    base_tree = git(root, 'rev-parse', BASE + '^{tree}').decode().strip()
    if base_tree != '32bd8f698b5f074e50ba9a26802a988c8976f40c':
        raise ValueError('Baseline tree mismatch')
    patch = bz2.decompress(base64.b64decode(raw, validate=True))
    if len(patch) > 1_000_000 or hashlib.sha256(patch).hexdigest() != EXPECTED_PATCH:
        raise ValueError('Patch checksum mismatch')
    payload = {'base_tree': base_tree}
    git(root, 'worktree', 'add', '--detach', str(work), BASE)
    git(work, 'apply', '--index', '--whitespace=error-all', '-', data=patch)
    actual_paths = git(work, 'diff', '--cached', '--name-only', BASE).decode().splitlines()
    paths = actual_paths
    if len(paths) != 32 or git(work, 'write-tree').decode().strip() != EXPECTED_TREE:
        raise ValueError('Reconstructed tree differs from locally tested tree')
    for path in paths:
        p = Path(path)
        if p.is_absolute() or '..' in p.parts or '.git' in p.parts or path.startswith('.github/'):
            raise ValueError('Unsafe changed path')
    git(work, 'diff', '--cached', '--check')
    elements = []
    for path in paths:
        record = git(work, 'ls-tree', EXPECTED_TREE, '--', path).decode().strip()
        metadata, name = record.split('\t', 1)
        mode, kind, sha = metadata.split()
        if name != path or kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('Unexpected tree element')
        data = git(work, 'cat-file', 'blob', sha)
        elements.append(({'path': path, 'mode': mode, 'type': 'blob', 'sha': sha}, data))
    return payload, elements

def post(endpoint, record):
    # Only immutable blob/tree endpoints. No branch, commit, PR, or merge writes.
    if endpoint not in ('blobs', 'trees'):
        raise ValueError('Unsupported write endpoint')
    request = urllib.request.Request(
        'https://api.github.com/repos/' + REPO + '/git/' + endpoint,
        data=json.dumps(record).encode(), method='POST',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    root = Path.cwd().resolve()
    with tempfile.TemporaryDirectory(prefix='iridium-object-transfer-') as temporary:
        work = Path(temporary) / 'source'
        try:
            payload, elements = prepare(root, args.payload.resolve(), work)
            if args.prepare_only:
                print('PASS exact reviewed tree reconstruction:', EXPECTED_TREE)
                return
            for element, data in elements:
                result = post('blobs', {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
                if result['sha'] != element['sha']:
                    raise ValueError('Uploaded blob differs from tested source')
            result = post('trees', {'base_tree': payload['base_tree'], 'tree': [x[0] for x in elements]})
            if result['sha'] != EXPECTED_TREE:
                raise ValueError('Uploaded tree differs from tested source')
            proof = {'tree': EXPECTED_TREE, 'base': BASE, 'files': len(elements),
                     'payload_sha256': EXPECTED_PAYLOAD, 'refs_changed': False}
            out = Path(os.environ['RUNNER_TEMP']) / 'review-objects'
            out.mkdir(exist_ok=True)
            (out / 'tree.json').write_text(json.dumps(proof, indent=2) + '\n')
            print('Registered exact locally tested tree:', EXPECTED_TREE, '(no refs changed)')
        finally:
            if work.exists():
                subprocess.run(['git', '-C', str(root), 'worktree', 'remove', '--force', str(work)], check=True)
if __name__ == '__main__':
    main()
