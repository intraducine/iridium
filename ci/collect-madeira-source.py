#!/usr/bin/env python3
"""Collect the frontend's build inputs, notices and final component inventory."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('frontend_source_build', 'madeira-frontend.py')
audit = load('frontend_source_audit', 'collect-app-link-audit.py')
fetch = load('frontend_source_fetch', 'fetch-runtime-inputs.py')


def binary_component(name):
    p = Path(name)
    if name in {'Iridium', 'Iridium.debug.dylib', '__preview.dylib'}:
        return 'Iridium, Madeira and SameBoy native libraries'
    if name.startswith('PlugIns/MadeiraJITHelper.appex/') and p.name in {
            'MadeiraJITHelper', 'MadeiraJITHelper.debug.dylib', '__preview.dylib'}:
        return 'Madeira JIT helper'
    if name == 'Frameworks/StikJIT.framework/StikJIT': return 'StikJIT and idevice'
    if name == 'd3d12/libmetalirconverter.dylib': return 'Apple Metal Shader Converter'
    if name == 'Frameworks/ppsspp_libretro.dylib': return 'PPSSPP and its selected native dependencies'
    if p.parent.as_posix() in {'arm64ec-windows', 'aarch64-windows', 'i386-windows'}:
        if p.name in {'xtajit.dll', 'xtajit64.dll'}: return 'FEX'
        if p.name == 'dockhost.exe': return 'Madeira Dock and LLVM-MinGW runtime'
        if p.name in {'d3d12.dll', 'madeira_d3d12.dll'}: return 'Madeira D3D12'
        if p.name in {'d3d9.dll', 'd3d9-emulated.dll', 'd3d10core.dll', 'd3d11.dll', 'dxgi.dll',
                      'winemetal.dll', 'nvapi64.dll'}: return 'DXMT'
        if p.suffix.lower() in {'.dll', '.exe', '.drv', '.cpl', '.acm', '.ax', '.ocx', '.sys', '.com', '.tlb'}:
            return 'Wine and its bundled libraries'
    raise ValueError('Unmapped packaged binary: ' + name)


def snapshot(repo, destination, revisions):
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    if subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', '--ignore-submodules=all', 'HEAD'], text=True).strip():
        # Generated crate notices are copied separately; source edits need a commit.
        changed = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', '--ignore-submodules=all', 'HEAD'], text=True).splitlines()
        if any(Path(name).suffix != '.a' and name != 'app/Madeira/legal/LICENSES-rppairing-crates.txt' for name in changed):
            raise ValueError('Commit source changes before collection: ' + str(repo.relative_to(ROOT)))
    with tempfile.TemporaryFile() as stream:
        subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar', revision], stdout=stream, check=True)
        stream.seek(0)
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=stream) as archive:
            archive.extractall(destination, filter='data')
    revisions[repo.relative_to(ROOT).as_posix()] = revision
    records = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--stage', '-z'], text=True).split('\0')
    for record in records:
        if not record.startswith('160000 '): continue
        meta, name = record.split('\t', 1)
        child = repo / name
        if not (child / '.git').exists(): continue
        if subprocess.check_output(['git', '-C', str(child), 'rev-parse', 'HEAD'], text=True).strip() != meta.split()[1]:
            raise ValueError('Submodule differs from its pin: ' + name)
        snapshot(child, destination / name, revisions)


def exclude_signing_fixtures(stage):
    """Omit exact reviewed upstream fixtures and reject all other signing files."""
    fixtures = json.loads((ROOT / 'ci/public-signing-fixtures.json').read_text())
    exclusions = []
    for path in sorted(stage.rglob('*')):
        if path.suffix.lower() not in {'.p12', '.pfx', '.mobileprovision', '.provisionprofile'}:
            continue
        if path.is_dir() and not path.is_symlink(): continue
        name = path.relative_to(stage).as_posix()
        fixture = fixtures.get(name, {})
        if (path.is_symlink() or not path.is_file()
                or fixture.get('sha256') != hashlib.sha256(path.read_bytes()).hexdigest()):
            raise ValueError('Unexpected signing material in corresponding source: ' + name)
        path.unlink()
        exclusions.append({'path': name, **fixture})
    return exclusions


def collect(app, output, maps):
    build.verify_pin()
    build.check_bundle(app)
    output.mkdir(parents=True, exist_ok=True)
    records = audit.inventory(app)
    if not records: raise ValueError('Empty native inventory')
    for record in records: record['component'] = binary_component(record['path'])
    link_maps = list(maps.rglob('*LinkMap*.txt'))
    if not link_maps: raise ValueError('Final app link maps are missing')
    static = audit.static_inputs(link_maps, ROOT.resolve())
    if not any(r['archive'].endswith('libntdll_unix.a') for r in static):
        raise ValueError('The maps do not contain the game runtime link; disable ENABLE_DEBUG_DYLIB')
    if not any(r['archive'].endswith('libIridiumSameBoy.a') for r in static):
        raise ValueError('The maps do not contain the selected console runtime')
    with tempfile.TemporaryDirectory(dir=ROOT / '.build', prefix='madeira-source-') as folder:
        stage = Path(folder) / 'iridium'
        revisions = {}
        snapshot(ROOT, stage, revisions)
        freetype = build.UPSTREAM / 'research/freetype'
        snapshot(freetype, stage / freetype.relative_to(ROOT), revisions)
        # Locked published inputs are shared with local builds, not local signing files.
        inputs = [item for item in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()) if item['name'] in {
            'llvm', 'frontend-stikjit-source', 'idevice-source', 'llvm-target-runtime-source', 'mingw-runtime-source', 'mingw-build-source'}]
        for item in inputs:
            archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
            if not archive.exists():
                target = ROOT / item['destination']
                if target.exists():
                    # Fetch to a separate verified source destination without overwriting an existing tree.
                    item = dict(item, destination='.build/madeira-source-inputs/' + item['name'])
                fetch.fetch(ROOT, item)
            if fetch.digest(archive) != item['sha256']: raise ValueError('Source checksum mismatch: ' + item['name'])
            dest = stage / '.build/runtime-downloads' / archive.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(archive, dest)
        pairing = build.UPSTREAM / 'build/rppairing-ios'
        vendor = stage / 'vendor/Madeira/build/rppairing-ios/vendor'
        config = subprocess.check_output(['cargo', 'vendor', '--locked', '--manifest-path', str(pairing / 'Cargo.toml'), str(vendor)], text=True)
        # Relative paths make the supplied Cargo tree usable after extraction.
        config = config.replace(str(vendor), 'vendor')
        (vendor.parent / '.cargo').mkdir(exist_ok=True)
        (vendor.parent / '.cargo/config.toml').write_text(config)
        notices = stage / 'release-notices'
        shutil.copytree(app / 'licenses', notices / 'licenses')
        shutil.copytree(app / 'legal', notices / 'legal')
        shutil.copytree(app / 'd3d12', notices / 'd3d12', ignore=shutil.ignore_patterns('*.dylib', '*.dxil'))
        psp_receipt = json.loads((build.PSP_OUTPUT / 'component.json').read_text())
        (stage / 'PPSSPP-BUILD-RECEIPT.json').write_text(json.dumps(psp_receipt, indent=2) + '\n')
        manifest = {'psp_build_receipt': 'PPSSPP-BUILD-RECEIPT.json (before final package signature removal)',
                    'source_exclusions': exclude_signing_fixtures(stage),
                    'revisions': revisions, 'inputs': inputs, 'binaries': records, 'static_archives': static,
                    'licenses': 'LICENSING.md and vendor/Madeira/THIRD-PARTY-NOTICES.md',
                    'build_and_replacement': 'docs/actions-ipa.md',
                    'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()}
        (stage / 'SOURCE-REVISIONS.json').write_text(json.dumps(revisions, indent=2) + '\n')
        (stage / 'COMPONENT-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
        archive = output / 'Iridium-corresponding-source.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar: tar.add(stage, arcname='iridium')
        checksum = fetch.digest(archive)
        (output / 'SOURCE-SHA256SUMS').write_text(checksum + '  ' + archive.name + '\n')
        (output / 'COMPONENT-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Source package complete: {len(records)} mapped binaries, {len(static)} linked static archives.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--link-maps', type=Path, required=True)
    args = parser.parse_args()
    collect(args.app, args.output, args.link_maps)
