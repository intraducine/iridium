#!/usr/bin/env python3
"""Record the app's native binaries without distributing executable payloads."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-unsigned-ipa.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def inventory(app):
    packager.check_payload(app)
    records = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
            if magic in packager.MACHO:
                kind = 'Mach-O'
            elif magic == b'\x7fELF':
                kind = 'ELF'
            elif magic[:2] == b'MZ':
                stream.seek(60)
                offset = stream.read(4)
                kind = 'DOS'
                if len(offset) == 4:
                    stream.seek(int.from_bytes(offset, 'little'))
                    if stream.read(4) == b'PE\0\0':
                        kind = 'PE'
            else:
                continue
            stream.seek(0)
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        linked = subprocess.check_output(['xcrun', 'otool', '-L', str(path)], text=True) if kind == 'Mach-O' else None
        records.append({'path': str(path.relative_to(app)), 'sha256': digest,
                        'bytes': path.stat().st_size, 'format': kind,
                        'linked_libraries': linked.replace(str(app), 'Iridium.app').splitlines()[1:] if linked is not None else None})
    return records


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: collect-app-link-audit.py Iridium.app output.json')
    app, output = map(Path, sys.argv[1:])
    records = inventory(app.resolve())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + '\n')
    print(f'Recorded {len(records)} native binaries. Static dependencies require link-map review.')
