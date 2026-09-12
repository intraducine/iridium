#!/usr/bin/env python3
"""Exercise Cerbero's real sdist command before compiling the media SDK."""
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

source = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='iridium-source-check-') as temp:
    work = Path(temp)
    fixture = work / 'source-check'
    fixture.mkdir()
    marker = fixture / 'source.txt'
    marker.write_text('source packaging check\n')
    with (work / 'packaging.log').open('w+') as log:
        result = subprocess.run([
            sys.executable, str(source / 'setup.py'), 'sdist',
            '--package=gstreamer-1.0-core', '--recipe=gperf',
            '--source-dirs=' + str(fixture), '--formats=tar',
            '--dist-dir=' + str(work / 'dist'),
        ], cwd=source, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            log.seek(0)
            print(log.read())
            raise SystemExit(result.returncode)
    archives = list((work / 'dist').glob('cerbero-*.tar'))
    if len(archives) != 1:
        raise SystemExit('Expected one Cerbero source archive')
    with tarfile.open(archives[0]) as archive:
        names = {m.name.split('/', 1)[1] for m in archive if '/' in m.name}
        required = {'cerbero-uninstalled', 'config/cross-ios-arm64.cbc',
                    'recipes/build-tools/gperf.recipe', 'packages/gstreamer-1.0-core.package'}
        # Compare the complete recipe/config inputs, including nested patches.
        for directory in ('recipes', 'packages', 'config', 'tools'):
            required.update(str(p.relative_to(source)) for p in (source / directory).rglob('*')
                            if p.is_file() and '__pycache__' not in p.parts)
        missing = required - names
        if missing:
            raise SystemExit('Source archive omitted build inputs: ' + ', '.join(sorted(missing)))
        matches = [m for m in archive if m.name.endswith('/sources/source-check/source.txt')]
        if len(matches) != 1 or archive.extractfile(matches[0]).read() != marker.read_bytes():
            raise SystemExit('Source archive did not preserve supplied source')
    print('PASS Cerbero source packaging and source inclusion')
