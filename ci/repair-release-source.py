#!/usr/bin/env python3
"""Repair source-only omissions in retained archives; never change compiler outputs."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request


def append_files(path, additions):
    if not additions:
        return
    with tempfile.TemporaryDirectory(dir=path.parent) as directory:
        output = Path(directory) / path.name
        mode = 'w:xz' if path.name.endswith('.xz') else 'w:gz'
        options = {'preset': 0} if mode == 'w:xz' else {'compresslevel': 1}
        with tarfile.open(path, 'r|*') as source, tarfile.open(output, mode, **options) as target:
            for member in source:
                target.addfile(member, source.extractfile(member) if member.isfile() else None)
            for name, content in sorted(additions.items()):
                data, mode = content if isinstance(content, tuple) else (content, 0o644)
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = mode
                target.addfile(member, io.BytesIO(data))
        os.replace(output, path)


def repair_cargo(path):
    records, manifests, names = {}, {}, set()
    with tarfile.open(path, 'r|gz') as archive:
        for member in archive:
            names.add(member.name)
            if member.isfile() and member.name.startswith('vendor/'):
                if member.name.endswith('/.cargo-checksum.json'):
                    records[str(Path(member.name).parent)] = json.load(archive.extractfile(member))
                elif member.name.count('/') == 2 and member.name.endswith('/Cargo.toml'):
                    manifests[str(Path(member.name).parent)] = tomllib.loads(archive.extractfile(member).read().decode())
    additions = {}
    for parent, record in records.items():
        missing = {name: digest for name, digest in record['files'].items() if parent + '/' + name not in names}
        if not missing:
            continue
        package = manifests[parent]['package']
        name, version = package['name'], package['version']
        url = f'https://static.crates.io/crates/{name}/{name}-{version}.crate'
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != record['package']:
            raise ValueError('Upstream crate checksum mismatch: ' + name)
        with tarfile.open(fileobj=io.BytesIO(data)) as crate:
            for relative, digest in missing.items():
                member = crate.getmember(name + '-' + version + '/' + relative)
                if not member.isfile():
                    raise ValueError('Expected regular Cargo source file')
                content = crate.extractfile(member).read()
                if hashlib.sha256(content).hexdigest() != digest:
                    raise ValueError('Restored Cargo file checksum mismatch')
                additions[parent + '/' + relative] = (content, member.mode & 0o777)
    append_files(path, additions)
    return len(additions)


def repair_cerbero(path, source, patches):
    with tempfile.TemporaryDirectory() as directory:
        clean = Path(directory)
        for name in ('recipes', 'packages', 'config', 'tools'):
            shutil.copytree(source / name, clean / name, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy2(source / 'cerbero-uninstalled', clean / 'cerbero-uninstalled')
        for patch in patches:
            command = ['git', 'apply']
            if subprocess.run(command + ['--check', str(patch)], cwd=clean, capture_output=True).returncode == 0:
                subprocess.run(command + [str(patch)], cwd=clean, check=True, capture_output=True)
            else:
                subprocess.run(command + ['--reverse', '--check', str(patch)], cwd=clean, check=True, capture_output=True)
        with tarfile.open(path, 'r|xz') as archive:
            names = {m.name for m in archive}
        additions = {'cerbero-1.28.6/' + str(p.relative_to(clean)): (p.read_bytes(), p.stat().st_mode & 0o777)
                     for p in clean.rglob('*') if p.is_file()
                     and 'cerbero-1.28.6/' + str(p.relative_to(clean)) not in names}
        append_files(path, additions)
        return len(additions)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    output = root / '.build/corresponding-source'
    print('Restored Cargo source files:', repair_cargo(output / 'idevice.tar.gz'))
    print('Restored Cerbero build files:', repair_cerbero(
        output / 'cerbero-1.28.6.tar.xz', root / '.build/runtime-sources/cerbero',
        [root / 'ci/patches' / name for name in ('cerbero-gperf-cxx14.patch', 'cerbero-assets-library.patch', 'cerbero-source-manifest.patch')]))
