#!/usr/bin/env python3
"""Run inside the Wine builder: collect source for each staged Debian library."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def collect(install, output, system=Path("/")):
    subprocess.run(["apt-get", "update"], check=True)
    output.mkdir(parents=True, exist_ok=True)
    records = []
    sources = set()
    for relative in sorted(path.relative_to(install) for path in install.rglob('*') if path.is_file()):
        # Wine's own binaries, registry and data have source in this monorepo.
        if relative.parts[0] not in {'lib', 'lib64', 'usr'} or 'wine' in relative.parts:
            continue
        guest = system / relative
        if not guest.is_file() or digest(guest) != digest(install / relative):
            raise ValueError(f'Staged system library does not match builder: {relative}')
        result = None
        for candidate in dict.fromkeys([str(guest), str(guest.resolve())]):
            found = subprocess.run(['dpkg-query', '-S', candidate], text=True, capture_output=True)
            if found.returncode == 0:
                result = found.stdout.splitlines()[0].split(': ', 1)[0]
                break
        if not result or ',' in result:
            raise ValueError(f'Cannot establish Debian owner: {relative}')
        source, version = subprocess.check_output(
            ['dpkg-query', '-W', '-f=${source:Package}\t${source:Version}', result], text=True).split('\t')
        sources.add(f'{source}={version}')
        copyright_path = Path('/usr/share/doc') / result.split(':')[0] / 'copyright'
        if not copyright_path.is_file():
            raise ValueError(f'Missing Debian copyright file: {result}')
        notices = output / 'notices'
        notices.mkdir(exist_ok=True)
        shutil.copyfile(copyright_path, notices / (result.replace(':', '_') + '.copyright'))
        records.append({'path': str(relative), 'sha256': digest(guest), 'binary_package': result,
                        'source_package': source, 'source_version': version})
    if not records:
        raise ValueError('No system dependency records found')
    downloads = output / 'debian'
    downloads.mkdir(exist_ok=True)
    for source in sorted(sources):
        subprocess.run(['apt-get', 'source', '--download-only', '--yes', source], cwd=downloads, check=True)
    (output / 'debian-runtime.json').write_text(json.dumps(records, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(
        f'{digest(path)}  {path.relative_to(output)}\n'
        for path in sorted(output.rglob('*')) if path.is_file() and path.name != 'SHA256SUMS'))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: collect-debian-sources.py INSTALL_ROOT OUTPUT')
    collect(Path(sys.argv[1]), Path(sys.argv[2]))
