#!/usr/bin/env python3
"""Collect the frontend's build inputs, notices and final component inventory."""
import engine_pins
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import ppsspp_atlas_resources as atlas

ROOT = Path(__file__).resolve().parents[1]
FREETYPE_REVISION = engine_pins.get('madeira')['buildDependencies']['freetype']['revision']


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('frontend_source_build', 'madeira-frontend.py')
audit = load('frontend_source_audit', 'collect-app-link-audit.py')
fetch = load('frontend_source_fetch', 'fetch-runtime-inputs.py')
phase3 = load('phase3_source_build', 'build-phase3.py')


def binary_component(name):
    p = Path(name)
    if name in {'Iridium', 'Iridium.debug.dylib', '__preview.dylib'}:
        return 'Iridium, Madeira and SameBoy native libraries'
    if name.startswith('PlugIns/MadeiraJITHelper.appex/') and p.name in {
            'MadeiraJITHelper', 'MadeiraJITHelper.debug.dylib', '__preview.dylib'}:
        return 'Madeira JIT helper'
    if name.startswith('PlugIns/MadeiraMemoryHost.appex/') and p.name in {'MadeiraMemoryHost', 'MadeiraMemoryHost.debug.dylib'}: return 'Madeira memory helper'
    if name == 'Frameworks/StikJIT.framework/StikJIT': return 'StikJIT and idevice'
    if name == 'd3d12/libmetalirconverter.dylib': return 'Apple Metal Shader Converter'
    if name == 'Frameworks/libIridiumPPSSPPNative.dylib': return 'PPSSPP and its selected native dependencies'
    advanced = {'libIridiumRetroPlayer.dylib': 'Iridium shared Libretro player',
                'libIridiumDolphin.dylib': 'DolphiniOS Dolphin and selected dependencies',
                'azahar_libretro.dylib': 'Azahar and selected dependencies',
                'play_libretro_ios.dylib': 'Play! and selected dependencies',
                'flycast_libretro.dylib': 'Flycast and selected dependencies'}
    if p.parent.as_posix() == 'Frameworks' and p.name in advanced: return advanced[p.name]
    graphics = {'gl/libMoltenVK.dylib': 'MoltenVK and its selected dependencies',
                'gl/libOSMesa.dylib': 'Mesa Zink', 'gl/libvulkan_kosmickrisp.dylib': 'Mesa KosmicKrisp',
                'compat/love/lua51.dll': 'LuaJIT', 'x86_64-opengl/dxil.dll': 'Microsoft DirectX Shader Compiler'}
    if name in graphics: return graphics[name]
    if p.parent.as_posix() == 'x86_64-opengl' and p.suffix == '.dll': return 'Mesa D3D12 OpenGL'
    if p.parent.as_posix() == 'vulkan/arm64ec-windows':
        if p.name.startswith('dxvk-'): return 'DXVK'
        if p.name in {'d3d12.dll', 'd3d12core.dll'}: return 'vkd3d-proton'
        if p.name in {'winevulkan.dll', 'vulkan-1.dll'}: return 'Wine Vulkan'
    if name == 'arm64ec-windows/faultrep.dll': return 'Madeira fault-reporting shim'
    if name == 'arm64ec-windows/vulkan-1.dll': return 'Madeira Vulkan stand-in generated from Wine exports'
    if p.parent.as_posix() in {'arm64ec-windows', 'aarch64-windows', 'i386-windows'}:
        if p.name in {'xtajit.dll', 'xtajit64.dll'}: return 'FEX'
        if p.name == 'dockhost.exe': return 'Madeira Dock and LLVM-MinGW runtime'
        if p.name in {'d3d12.dll', 'd3d12core.dll', 'madeira_d3d12.dll'}: return 'Madeira D3D12'
        if p.name in {'d3d9.dll', 'd3d9-emulated.dll', 'd3d10core.dll', 'd3d11.dll', 'dxgi.dll',
                      'winemetal.dll', 'nvapi64.dll'}: return 'DXMT'
        if p.suffix.lower() in {'.dll', '.exe', '.drv', '.cpl', '.acm', '.ax', '.ocx', '.sys', '.com', '.tlb'}:
            return 'Wine and its bundled libraries'
    raise ValueError('Unmapped packaged binary: ' + name)


def verified_madeira_binary(repo, name, outputs):
    if Path(name).suffix not in {'.dll', '.exe', '.drv', '.cpl', '.acm', '.ax', '.ocx'} or name not in outputs:
        return False
    path = repo / name
    return (not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(repo.resolve())
            and build.file_digest(path) == outputs[name])


def snapshot(repo, destination, revisions, *, source_root=None, madeira_outputs=None):
    source_root = destination if source_root is None else source_root
    relative = destination.relative_to(source_root)
    if '..' in relative.parts:
        raise ValueError('Source snapshot destination escapes its staging root')
    prefix = ['--prefix=' + relative.as_posix() + '/'] if relative.parts else []
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    changed = subprocess.check_output(
        ['git', '-C', str(repo), 'diff', '--no-renames', '--name-only', '-z', '--ignore-submodules=all', 'HEAD'],
        text=True).split('\0')[:-1]
    if changed == ['deps/zlib-1.3.1/zconf.h']:
        phase3.source_state(repo) # Verify CMake's byte-identical zconf.h.included rename.
    elif changed and repo in (build.UPSTREAM / 'FEX', build.UPSTREAM / 'dxmt', build.UPSTREAM / 'madeira-dock'):
        build.verify_pin()
    else:
        # The archive uses pinned Git objects. Only checked build outputs may differ in Madeira.
        outputs = (madeira_outputs or {}) if repo == build.UPSTREAM else {}
        unexpected = [name for name in changed if Path(name).suffix != '.a'
                      and name != 'app/Madeira/legal/LICENSES-rppairing-crates.txt'
                      and not verified_madeira_binary(repo, name, outputs)]
        if unexpected:
            raise ValueError(f'Commit source changes before collection: {repo.relative_to(ROOT)}. '
                             f'Unexpected tracked changes: {unexpected[:8]}')
    with tempfile.TemporaryFile() as stream:
        subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar', *prefix, revision], stdout=stream, check=True)
        stream.seek(0)
        source_root.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=stream) as archive:
            # Submodules may link to siblings in the complete source tree.
            # Prefix paths before filtering so the full stage is the boundary.
            archive.extractall(source_root, filter='data')
    if repo in (build.UPSTREAM / 'FEX', build.UPSTREAM / 'dxmt', build.UPSTREAM / 'madeira-dock'):
        changes = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
        for name in changes:
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / name, target)
    revisions[repo.relative_to(ROOT).as_posix()] = revision
    records = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--stage', '-z'], text=True).split('\0')
    for record in records:
        if not record.startswith('160000 '): continue
        meta, name = record.split('\t', 1)
        child = repo / name
        if not (child / '.git').exists(): continue
        if subprocess.check_output(['git', '-C', str(child), 'rev-parse', 'HEAD'], text=True).strip() != meta.split()[1]:
            raise ValueError('Submodule differs from its pin: ' + name)
        snapshot(child, destination / name, revisions, source_root=source_root,
                 madeira_outputs=madeira_outputs)


def snapshot_freetype(destination, revisions, *, source_root=None):
    repo = build.UPSTREAM / 'research/freetype'
    # Restored native archives skip the compiler step that normally clones this source.
    if not repo.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', 'VER-2-13-3',
                        'https://github.com/freetype/freetype.git', str(repo)], check=True)
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != FREETYPE_REVISION: raise ValueError('Unexpected FreeType revision')
    snapshot(repo, destination, revisions, source_root=source_root)


def collect_graphics_sources(stage, revisions):
    toolchains = build.UPSTREAM / 'toolchains'
    repos = [toolchains / name for name in ('MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf',
        'luajit-a4c064539ea931274d407e1249b4bb575424a0f4', 'dxvk-src', 'vkd3d-proton',
        'SPIRV-LLVM-Translator-29758b55816c14abb3e4142d42aca7a95bf46710')]
    repos[0] = toolchains / 'graphics' / repos[0].name
    repos[-1] = toolchains / 'graphics' / repos[-1].name
    git_sources = []
    urls = ['https://github.com/KhronosGroup/MoltenVK.git', 'https://github.com/LuaJIT/LuaJIT.git',
            'https://github.com/doitsujin/dxvk.git', 'https://github.com/HansKristian-Work/vkd3d-proton.git',
            'https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git']
    def variable(recipe, name):
        match = re.search(r'^' + name + r'=["\']?([^\s"\']+)', recipe, re.M)
        if not match: raise ValueError('Missing pinned graphics input: ' + name)
        return match.group(1)
    def checkout(repo, url, revision, *, children=False):
        if not (repo / '.git').exists():
            if repo.exists() and any(repo.iterdir()): raise ValueError('Preserve existing graphics source: ' + str(repo))
            if shutil.disk_usage(ROOT).free < 22 * 1024**3: raise ValueError('Graphics source needs 20 GiB reserve plus 2 GiB temporary space')
            repo.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
            subprocess.run(['git', '-C', str(repo), 'fetch', '--depth', '1', url, revision], check=True)
            subprocess.run(['git', '-C', str(repo), 'checkout', '-q', 'FETCH_HEAD'], check=True)
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revision: raise ValueError('Graphics source revision differs: ' + str(repo))
        if children: subprocess.run(['git', '-C', str(repo), 'submodule', 'update', '--init', '--recursive', '--depth', '1'], check=True)
    dxvk_recipe = (build.UPSTREAM / 'build/dxvk/build.sh').read_text()
    vkd3d_recipe = (build.UPSTREAM / 'build/vkd3d-proton/build.sh').read_text()
    pins = [repos[0].name.rsplit('-', 1)[1], repos[1].name.rsplit('-', 1)[1], variable(dxvk_recipe, 'DXVK_COMMIT'),
            variable(vkd3d_recipe, 'VKD3D_COMMIT'), repos[-1].name.rsplit('-', 1)[1]]
    for index, (repo, url, revision) in enumerate(zip(repos, urls, pins)):
        checkout(repo, url, revision, children=index in (2, 3))
        if index == 0 and not (repo / 'External/SPIRV-Tools/.git').exists():
            subprocess.run(['bash', str(repo / 'fetchDependencies'), '--none'], cwd=repo, check=True)
        snapshot(repo, stage / repo.relative_to(ROOT), revisions, source_root=stage)
        git_sources.append({'path': repo.relative_to(ROOT).as_posix(), 'url': url})
    # fetchDependencies pins MoltenVK's sibling source trees and its versions file.
    external = repos[0] / 'External'
    for repo in sorted(external.iterdir()):
        if (repo / '.git').exists():
            snapshot(repo, stage / repo.relative_to(ROOT), revisions, source_root=stage)
            url = subprocess.check_output(['git', '-C', str(repo), 'remote', 'get-url', 'origin'], text=True).strip()
            git_sources.append({'path': repo.relative_to(ROOT).as_posix(), 'url': url})
    cache = toolchains / 'mesa-d3d12'
    graphics = toolchains / 'graphics'
    archives = [graphics / 'mesa-25.0.7.tar.xz', graphics / 'mesa-26.2.4.tar.xz', cache / 'mesa-26.2.4.tar.xz',
        cache / 'dxc_2026_09_29.zip', cache / 'zlib-1.3.1.tar.gz', cache / 'zlib_1.3.1-1_patch.zip']
    headers = build.UPSTREAM / 'build/mesa-d3d12/work/mesa-26.2.4/subprojects/DirectX-Headers-1.0'
    mesa_recipe = (build.UPSTREAM / 'build/mesa-d3d12/build.sh').read_text()
    checkout(headers, variable(mesa_recipe, 'DXHEADERS_URL'), variable(mesa_recipe, 'DXHEADERS_COMMIT'))
    snapshot(headers, stage / headers.relative_to(ROOT), revisions, source_root=stage)
    git_sources.append({'path': headers.relative_to(ROOT).as_posix(), 'url': 'https://github.com/microsoft/DirectX-Headers.git'})
    sources = [
        ('https://archive.mesa3d.org/mesa-25.0.7.tar.xz', '592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6'),
        ('https://archive.mesa3d.org/mesa-26.2.4.tar.xz', variable(mesa_recipe, 'MESA_SHA256')),
        ('https://archive.mesa3d.org/mesa-26.2.4.tar.xz', variable(mesa_recipe, 'MESA_SHA256')),
        (variable(mesa_recipe, 'DXC_URL'), variable(mesa_recipe, 'DXC_SHA256')),
        (variable(mesa_recipe, 'ZLIB_URL'), variable(mesa_recipe, 'ZLIB_SHA256')),
        (variable(mesa_recipe, 'ZLIB_PATCH_URL'), variable(mesa_recipe, 'ZLIB_PATCH_SHA256'))]
    for archive, (url, sha) in zip(archives, sources):
        if not archive.exists():
            cache_file = ROOT / '.build/runtime-downloads' / (sha + '.tar')
            existed = cache_file.exists()
            fetch.fetch(ROOT, {'name': archive.name, 'destination': archive.relative_to(ROOT).as_posix(), 'url': url, 'sha256': sha})
            if not existed: cache_file.unlink()  # Only this call's redundant transfer copy.
        if archive.is_symlink() or not archive.is_file() or fetch.digest(archive) != sha:
            raise ValueError('Pinned graphics archive differs: ' + archive.name)
        destination = stage / archive.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive, destination)
    for item in git_sources: item['revision'] = revisions[item['path']]
    return git_sources


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


def exclude_unused_archives(stage):
    """Leave upstream source intact and omit exact unused binary inputs from delivery."""
    manifest = ROOT / 'ci/public-unused-archives.json'
    records = json.loads(manifest.read_text()) if manifest.exists() else {}
    validated = []
    for name, record in sorted(records.items()):
        path = stage / name
        if not path.exists() and not path.is_symlink(): continue
        if (not name.startswith('vendor/PPSSPP/ffmpeg/') or Path(name).suffix not in {'.a', '.lib', '.dll'}
                or '..' in Path(name).parts or path.is_symlink() or not path.is_file()
                or record.get('sha256') != hashlib.sha256(path.read_bytes()).hexdigest()):
            raise ValueError('Unreviewed unused archive: ' + name)
        validated.append((path, {'path': name, **record}))
    for path, record in validated: path.unlink()
    return [record for path, record in validated]


def collect(app, output, maps):
    build.verify_pin()
    runtime_receipts = build.check_bundle(app)
    madeira_outputs = {f'app/Madeira/{path}': sha for receipt in runtime_receipts.values()
                       for path, sha in receipt['files'].items()}
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
        snapshot(ROOT, stage, revisions, madeira_outputs=madeira_outputs)
        freetype = build.UPSTREAM / 'research/freetype'
        snapshot_freetype(stage / freetype.relative_to(ROOT), revisions, source_root=stage)
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
        graphics_sources = collect_graphics_sources(stage, revisions)
        component_sources = build.madeira_components.source_inventory(build.UPSTREAM)
        component_sources['gitSources'] = graphics_sources
        (stage / 'vendor/Madeira/iridium-runtime-sources.json').write_text(json.dumps(component_sources, indent=2) + '\n')
        psp_receipt = json.loads((build.PSP_OUTPUT / 'component.json').read_text())
        psp_atlases = atlas.collect_inputs(stage, psp_receipt, ROOT)
        psp_external = json.loads((ROOT / engine_pins.get('ppsspp')['buildDependencies']['moltenVK']['inputs']).read_text())
        if not psp_external or psp_external != psp_receipt.get('moltenVK', {}).get('sourceInputs'):
            raise ValueError('Linked MoltenVK source closure differs from the source manifest')
        for item in psp_external:
            archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
            if not archive.is_file() or fetch.digest(archive) != item['sha256']:
                raise ValueError('Missing linked PSP external source: ' + item['name'])
            dest = stage / '.build/runtime-downloads' / archive.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(archive, dest)
        import stikjit_frontend
        stikjit_frontend.collect_source(stage)
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
        (stage / 'PPSSPP-BUILD-RECEIPT.json').write_text(json.dumps(psp_receipt, indent=2) + '\n')
        phase3_receipts = {}
        if any(record['path'] == 'Frameworks/libIridiumRetroPlayer.dylib' for record in records):
            for engine in ('host', *phase3.PINS):
                directory = ROOT / '.build/phase3' / engine / 'iphoneos'
                receipt = json.loads((directory / 'component.json').read_text())
                phase3.verify_inputs(receipt)
                phase3_receipts[engine] = receipt
            for filename, expected in phase3.AZAHAR_DOWNLOADS.items():
                if not filename.endswith('.tar.xz'): continue
                source = ROOT / '.build/phase3-downloads' / filename
                if phase3.digest(source) != expected: raise ValueError('Azahar corresponding source differs')
                destination = stage / '.build/phase3-downloads' / filename
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            azahar_external = json.loads((ROOT / engine_pins.get('azahar')['buildDependencies']['moltenVK']['inputs']).read_text())
            if azahar_external != phase3_receipts['azahar'].get('moltenVK', {}).get('sourceInputs'):
                raise ValueError('Linked Azahar MoltenVK closure differs from its source manifest')
            for item in azahar_external:
                archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
                if not archive.is_file() or phase3.digest(archive) != item['sha256']:
                    raise ValueError('Missing linked Azahar external source: ' + item['name'])
                destination = stage / '.build/runtime-downloads' / archive.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(archive, destination)
            (stage / 'PHASE3-BUILD-RECEIPTS.json').write_text(json.dumps(phase3_receipts, indent=2) + '\n')
        (stage / 'MADEIRA-RUNTIME-RECEIPTS.json').write_text(json.dumps(runtime_receipts, indent=2) + '\n')
        manifest = {'madeira_runtime_receipts': 'MADEIRA-RUNTIME-RECEIPTS.json', 'psp_build_receipt': 'PPSSPP-BUILD-RECEIPT.json (before final package signature removal)',
                    'phase3_build_receipts': 'PHASE3-BUILD-RECEIPTS.json' if phase3_receipts else None,
                    'source_exclusions': exclude_signing_fixtures(stage) + exclude_unused_archives(stage) + psp_atlases['exclusions'],
                    'revisions': revisions, 'inputs': inputs, 'psp_external_source_inputs': psp_external,
                    'psp_atlas_font_inputs': psp_atlases['inputs'], 'binaries': records, 'static_archives': static,
                    'generated_frontend_components': {
                        'arm64ec-windows/faultrep.dll': {'source': 'vendor/Madeira/build/faultrep/faultrep.c', 'build': 'vendor/Madeira/build/faultrep/build.sh'},
                        'vulkan/arm64ec-windows/vulkan-1.dll': {'source': 'vendor/Madeira/wine/dlls/vulkan-1', 'build': 'vendor/Madeira/build/windows-runtime/build.sh'}},
                    'licenses': 'LICENSING.md and vendor/Madeira/THIRD-PARTY-NOTICES.md',
                    'build_and_replacement': 'docs/actions-ipa.md',
                    'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()}
        (stage / 'SOURCE-REVISIONS.json').write_text(json.dumps(revisions, indent=2) + '\n')
        (stage / 'MADEIRA-NATIVE-SOURCES.json').write_text(json.dumps(build.native_source_inventory(), indent=2) + '\n')
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
