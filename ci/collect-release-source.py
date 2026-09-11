#!/usr/bin/env python3
"""Collect source inputs independently of binaries. Never archive a worktree wholesale."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import shutil
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/corresponding-source'


def git_snapshot(repo, output):
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar.gz', '-o', str(output), revision], check=True)
    patch = subprocess.check_output(['git', '-C', str(repo), 'diff', '--binary', '--ignore-submodules=all', 'HEAD', '--'])
    if patch:
        output.with_suffix('.patch').write_bytes(patch)
    return revision


def source_tree(source, output):
    # These trees are captured before compilation. Exclude upstream prebuilt
    # FFI archives and repository metadata; reject signing material outright.
    if not source.is_dir():
        raise ValueError('Missing source directory')
    with tarfile.open(output, 'w:gz') as archive:
        for directory, dirs, names in os.walk(source, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in {'.git', 'target', '.build'})
            for name in sorted(names + [d for d in dirs if (Path(directory) / d).is_symlink()]):
                path = Path(directory) / name
                if path.suffix.lower() in {'.p12', '.pfx', '.mobileprovision', '.key'}:
                    raise ValueError('Signing material in source input')
                if path.suffix.lower() in {'.a', '.dylib', '.dll', '.exe'}:
                    continue
                if path.is_symlink():
                    if not path.resolve().is_relative_to(source.resolve()):
                        raise ValueError('Source symlink escapes its root')
                archive.add(path, arcname=str(path.relative_to(source)), recursive=False)


def collect(kind):
    OUT.mkdir(parents=True, exist_ok=True)
    if kind == 'repository':
        revisions = {'repository': git_snapshot(ROOT, OUT / 'iridium.tar.gz')}
        records = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=ROOT).decode().split('\0')
        for record in records:
            if not record.startswith('160000 '):
                continue
            meta, name = record.split('\t', 1)
            source = ROOT / name
            if not (source / '.git').exists():
                continue  # Unused optional test dependencies are not build inputs.
            expected = meta.split()[1]
            actual = git_snapshot(source, OUT / (name.replace('/', '_') + '.tar.gz'))
            if expected != actual:
                raise ValueError('Submodule revision differs from the lock: ' + name)
            revisions[name] = actual
        (OUT / 'repository-revisions.json').write_text(json.dumps(revisions, indent=2) + '\n')
        for item in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()):
            if item['name'] in {'stikjit-source', 'idevice-source', 'cerbero-source'} or 'llvm-mingw' in item['name']:
                continue
            archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
            with archive.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if digest != item['sha256']:
                raise ValueError('Source archive checksum mismatch')
            shutil.copyfile(archive, OUT / (item['name'] + '.source-archive'))
    elif kind == 'jit':
        for name in ('StikJIT', 'idevice'):
            source_tree(ROOT / '.build/runtime-sources' / name, OUT / (name + '.tar.gz'))
    elif kind == 'angle':
        source = ROOT / '.build/runtime-sources/angle'
        revisions = {}
        for directory, dirs, files in os.walk(source):
            dirs[:] = [d for d in dirs if d not in {'out', '.git'}]
            if '.git' in files or (Path(directory) / '.git').is_dir():
                relative = str(Path(directory).relative_to(source))
                name = 'angle' if relative == '.' else 'angle_' + relative.replace('/', '_')
                revisions[relative] = git_snapshot(Path(directory), OUT / (name + '.tar.gz'))
        if '.' not in revisions:
            raise ValueError('ANGLE source checkout missing')
        (OUT / 'angle-revisions.json').write_text(json.dumps(revisions, indent=2) + '\n')
    elif kind == 'package':
        required = ['iridium.tar.gz', 'repository-revisions.json', 'angle-revisions.json',
                    'StikJIT.tar.gz', 'idevice.tar.gz', 'cerbero-1.28.6.tar.xz']
        for name in required:
            if not (OUT / name).is_file() or not (OUT / name).stat().st_size:
                raise ValueError('Missing corresponding source: ' + name)
        debian = ROOT / '.build/linux-transfer/sources'
        if not debian.is_dir():
            raise ValueError('Missing Linux dependency sources')
        shutil.copytree(debian, OUT / 'linux')
        destination = ROOT / '.build/ipa-output'
        destination.mkdir(parents=True, exist_ok=True)
        output = destination / 'Iridium-corresponding-source.tar.gz'
        with tarfile.open(output, 'w:gz') as archive:
            archive.add(OUT, arcname='corresponding-source')
        with output.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        (destination / 'SOURCE-SHA256SUMS').write_text(digest + '  ' + output.name + '\n')
    else:
        raise ValueError('Unknown source collection stage')


if __name__ == '__main__':
    collect(sys.argv[1])
