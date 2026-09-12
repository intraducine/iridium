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
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/corresponding-source'


def collect_media_rust():
    # Cerbero's Rust plugins use a different standard library from idevice.
    cerbero = next(x for x in json.loads((ROOT / 'ci/runtime-inputs.json').read_text())
                   if x['name'] == 'cerbero-source')
    if cerbero['sha256'] != '1874c5ed8b67612ca0370e5a8c7b25420ed98f0176425aa427eb1461293a82d3':
        raise ValueError('Review the media Rust source pin for the new Cerbero revision')
    output = OUT / 'media-rust-src-1.96.0.tar.xz'
    expected = '7875f9f4b91455ac25e2ea0e0f1cb3d7d16c309ef0720778538d20ed0e9b818b'
    if output.exists():
        data = output.read_bytes()
    else:
        with urllib.request.urlopen('https://static.rust-lang.org/dist/2026-05-28/rust-src-1.96.0.tar.xz',
                                    timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('Media Rust source checksum mismatch')
    output.write_bytes(data)


def collect_rust_dependencies(source_archive, output_directory):
    # rust-src carries the library lockfile, but not its registry crate sources.
    with tarfile.open(OUT / source_archive) as archive:
        locks = [m for m in archive if m.name == 'library/Cargo.lock'
                 or m.name.endswith('/rust/library/Cargo.lock')]
        if len(locks) != 1:
            raise ValueError('Expected one Rust standard-library lockfile')
        lock = locks[0]
        packages = tomllib.loads(archive.extractfile(lock).read().decode())['package']
    destination = OUT / output_directory
    destination.mkdir(exist_ok=True)
    for package in packages:
        if not package.get('source'):
            continue
        if package['source'] != 'registry+https://github.com/rust-lang/crates.io-index':
            raise ValueError('Unexpected Rust registry')
        name, version = package['name'], package['version']
        filename = name + '-' + version + '.crate'
        if Path(filename).name != filename:
            raise ValueError('Invalid Rust crate path')
        output = destination / filename
        if output.exists():
            data = output.read_bytes()
        else:
            with urllib.request.urlopen('https://static.crates.io/crates/' + name + '/' + filename,
                                        timeout=60) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != package['checksum']:
            raise ValueError('Rust crate checksum mismatch: ' + name)
        output.write_bytes(data)


def check_restored_sources():
    hashes, checksums = {}, {}
    with tarfile.open(OUT / 'idevice.tar.gz', 'r|gz') as archive:
        for member in archive:
            if not member.isfile() or not member.name.startswith('vendor/'):
                continue
            if member.name in hashes:
                raise ValueError('Duplicate vendor source member')
            stream = archive.extractfile(member)
            if member.name.endswith('/.cargo-checksum.json'):
                data = stream.read()
                checksums[str(Path(member.name).parent)] = json.loads(data)['files']
                hashes[member.name] = hashlib.sha256(data).hexdigest()
            else:
                hashes[member.name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    if not checksums:
        raise ValueError('Restored idevice source has no vendor checksum records')
    for parent, files in checksums.items():
        for name, expected in files.items():
            full_name = parent + '/' + name
            if full_name not in hashes:
                raise ValueError('Restored idevice source is incomplete: ' + full_name)
            if hashes[full_name] != expected:
                raise ValueError('Restored idevice source checksum mismatch: ' + full_name)
    with tarfile.open(OUT / 'cerbero-1.28.6.tar.xz') as archive:
        names = {m.name.split('/', 1)[1] for m in archive if m.isfile() and '/' in m.name}
        required = {'cerbero-uninstalled', 'config/cross-ios-arm64.cbc',
                    'recipes/build-tools/gperf.recipe', 'packages/gstreamer-1.0-core.package'}
        missing = required - names
        if missing:
            raise ValueError('Restored Cerbero source lacks build inputs: ' + ', '.join(sorted(missing)))


def collect_moltenvk():
    # These match the SDK object and its embedded VERSIONS.txt, not a moving tag.
    for item in json.loads((ROOT / 'ci/moltenvk-source-inputs.json').read_text()):
        output = OUT / ('media-' + item['name'] + '.tar.gz')
        if output.exists():
            data = output.read_bytes()
        else:
            with urllib.request.urlopen(item['url'], timeout=60) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('MoltenVK source checksum mismatch: ' + item['name'])
        output.write_bytes(data)

# Public fixtures from openssl 0.10.76, tokio-rustls 0.26.4 and untrusted 0.9.0.
# Every crate archive was verified against the pinned Cargo.lock checksum.
# Exact byte hashes permit upstream test data, never maintainer signing material.
PUBLIC_TEST_FIXTURES = {'vendor/openssl/test/cms.p12': 'd33fc5edd6b9caa672e7570b869135235bb2583580a273f6e88c6a6c68fd5a8a',
 'vendor/openssl/test/identity.p12': 'aceeb3e5516471bd5af9a44bbeffc9559c4f228f67c677d29f36a4b368e2779f',
 'vendor/openssl/test/intermediate-ca.key': 'a5f3d331af87c1305843e235841e494a0669a95d3824a6c766d09371f62c3bab',
 'vendor/openssl/test/keystore-empty-chain.p12': 'bbea280f6fe10556d7470df7072ef0e4ee3997e2c0b3666197f423430c0e6b61',
 'vendor/openssl/test/root-ca.key': 'b37cf88614980c38e43c4329cdf7162bae48cc8af1fafd54db2fe0d17e458e1d',
 'vendor/tokio-rustls/tests/certs/end.key': '5137467345dd24a91915c17cac20e66f6ac83cd8e0a0ca7aece5eb26e20ad739',
 'vendor/untrusted/mk/llvm-snapshot.gpg.key': '88c1936349db1b7798b92cb62fe7d69e0b676b7900f4cb120c1c8ad5ac6b93d6'}


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
            # Only the root target is Cargo output. cc/src/target is source.
            dirs[:] = sorted(d for d in dirs if d != '.git' and
                             not (Path(directory) == source and d in {'target', '.build'}))
            for name in sorted(names + [d for d in dirs if (Path(directory) / d).is_symlink()]):
                path = Path(directory) / name
                if path.suffix.lower() in {'.p12', '.pfx', '.mobileprovision', '.key'}:
                    expected = PUBLIC_TEST_FIXTURES.get(str(path.relative_to(source)))
                    if path.is_symlink() or expected != hashlib.sha256(path.read_bytes()).hexdigest():
                        raise ValueError('Signing material in source input')
                if path.suffix.lower() in {'.a', '.dylib', '.dll', '.exe'}:
                    relative = path.relative_to(source)
                    if relative.parts[0] != 'vendor' or len(relative.parts) < 3:
                        continue
                    # Cargo verifies these upstream fixtures/import libraries too.
                    crate = source.joinpath(*relative.parts[:2])
                    checksums = json.loads((crate / '.cargo-checksum.json').read_text())
                    expected = checksums['files'].get(str(path.relative_to(crate)))
                    if path.is_symlink() or expected != hashlib.sha256(path.read_bytes()).hexdigest():
                        raise ValueError('Unverified binary in vendored source')
                if path.is_symlink():
                    if not path.resolve().is_relative_to(source.resolve()):
                        raise ValueError('Source symlink escapes its root')
                archive.add(path, arcname=str(path.relative_to(source)), recursive=False)


def collect(kind):
    OUT.mkdir(parents=True, exist_ok=True)
    if kind in {'repository', 'checkout'}:
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
        if kind == 'checkout':
            return  # Dependency sources came from the verified native producer.
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
        rust = Path(os.environ['IRIDIUM_RUST_SYSROOT'])
        source_tree(rust / 'lib/rustlib/src/rust', OUT / 'rust-standard-library.tar.gz')
        source_tree(rust / 'share/doc/rust/licenses', OUT / 'rust-license-texts.tar.gz')
        shutil.copyfile(rust / 'share/doc/rust/COPYRIGHT-library.html',
                        OUT / 'rust-standard-library-COPYRIGHT.html')
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
        revisions['bootstrap_depot_tools'] = git_snapshot(
            ROOT / '.build/depot_tools', OUT / 'depot_tools.tar.gz')
        (OUT / 'angle-revisions.json').write_text(json.dumps(revisions, indent=2) + '\n')
    elif kind == 'package':
        subprocess.run([sys.executable, str(ROOT / 'ci/repair-release-source.py')], check=True)
        check_restored_sources()
        collect_media_rust()
        collect_rust_dependencies('media-rust-src-1.96.0.tar.xz', 'media-rust-dependencies')
        collect_rust_dependencies('rust-standard-library.tar.gz', 'jit-rust-dependencies')
        collect_moltenvk()
        required = ['iridium.tar.gz', 'repository-revisions.json', 'angle-revisions.json',
                    'StikJIT.tar.gz', 'idevice.tar.gz', 'cerbero-1.28.6.tar.xz',
                    'idevice-dependencies.json', 'idevice-ios-dependencies.txt',
                    'rust-standard-library.tar.gz', 'rust-license-texts.tar.gz',
                    'rust-standard-library-COPYRIGHT.html', 'rust-toolchain.txt']
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
