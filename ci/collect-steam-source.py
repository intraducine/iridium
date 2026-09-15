#!/usr/bin/env python3
"""Retain complete, revision-pinned Steam module dependency sources for release."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def collect():
    output = ROOT / '.build/corresponding-source/steam'
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for item in json.loads((ROOT / 'ci/steam-source-inputs.json').read_text()):
        revision = item['revision']
        if not re.fullmatch(r'[a-f0-9]{40}', revision):
            raise ValueError('Steam source requires a full revision')
        if not re.fullmatch(r'[\w.-]+/[\w.-]+', item['repository']) or any(p in {'.', '..'} for p in item['repository'].split('/')):
            raise ValueError('Invalid source repository')
        if not re.fullmatch(r'[\w.-]+', item['name']):
            raise ValueError('Invalid source name')
        archive = output / (item['name'] + '-' + revision + '.tar.gz')
        receipt = archive.with_suffix('.sha256')
        if not archive.exists() or not receipt.exists():
            url = 'https://codeload.github.com/' + item['repository'] + '/tar.gz/' + revision
            with urllib.request.urlopen(url, timeout=90) as response, archive.with_suffix('.tmp').open('wb') as stream:
                shutil.copyfileobj(response, stream)
            archive.with_suffix('.tmp').replace(archive)
            with archive.open('rb') as stream:
                receipt.write_text(hashlib.file_digest(stream, 'sha256').hexdigest() + '\n')
        with archive.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != receipt.read_text().strip():
            raise ValueError('Cached Steam source checksum mismatch')
        # No extraction: retain upstream source and notices, including public test fixtures.
        with tarfile.open(archive) as source:
            first = source.next()
            if first is None or not first.name.endswith('-' + revision):
                raise ValueError('Source archive root does not match its pinned revision')
        records.append(dict(item, archive=archive.name, sha256=digest))
    (output / 'sources.json').write_text(json.dumps(records, indent=2) + '\n')
    shutil.copy2(ROOT / 'iridium/packages/steam/THIRD-PARTY-NOTICES.md', output)
    shutil.copy2(ROOT / 'iridium/packages/steam/Iridium.Steam/packages.lock.json', output)


if __name__ == '__main__':
    collect()
