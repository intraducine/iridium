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
            if stream.read(4) not in packager.MACHO:
                continue
            stream.seek(0)
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        linked = subprocess.check_output(['xcrun', 'otool', '-L', str(path)], text=True)
        records.append({'path': str(path.relative_to(app)), 'sha256': digest,
                        'bytes': path.stat().st_size,
                        'linked_libraries': linked.replace(str(app), 'Iridium.app').splitlines()[1:]})
    return records


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: collect-app-link-audit.py Iridium.app output.json')
    app, output = map(Path, sys.argv[1:])
    records = inventory(app.resolve())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + '\n')
    print(f'Recorded {len(records)} native binaries. Static dependencies require link-map review.')
