#!/usr/bin/env python3
"""Regenerate native PSP atlases from locked OFL inputs for separate review."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile
import ppsspp_atlas_resources as atlas

ROOT = atlas.ROOT


def fetch_inputs(source):
    lock = json.loads(atlas.FONT_LOCK.read_text())
    cache = atlas.font_cache(); cache.mkdir(parents=True, exist_ok=True)
    for item in lock['inputs']:
        target = atlas.input_path(item, source)
        if target.exists():
            if target.is_symlink() or atlas.digest(target) != item['sha256']:
                raise ValueError('Existing font input differs: ' + item['file'])
            continue
        if 'source' in item:
            raise ValueError('Pinned Roboto source is missing')
        download = cache / (item['file'] + '.download')
        with urllib.request.urlopen(item['url'], timeout=60) as response, download.open('wb') as output:
            shutil.copyfileobj(response, output)
        expected = item.get('archiveSHA256', item['sha256'])
        if atlas.digest(download) != expected:
            raise ValueError('Downloaded font checksum differs: ' + item['file'])
        if 'entry' in item:
            with zipfile.ZipFile(download) as archive:
                content = archive.read(item['entry'])
            if len(content) != item['bytes'] or hashlib.sha256(content).hexdigest() != item['sha256']:
                raise ValueError('Extracted font checksum differs: ' + item['file'])
            target.write_bytes(content)
            download.unlink()
        else:
            download.rename(target)
    return atlas.locked_inputs(source)


def run(*command, cwd=None):
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def source_revisions(source, root=ROOT):
    if (source / '.git').exists():
        if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != atlas.REVISION:
            raise ValueError('PPSSPP release source differs')
        if subprocess.check_output(['git', '-C', str(source), 'diff', '--ignore-submodules', 'HEAD'], text=True):
            raise ValueError('PPSSPP source has tracked changes')
        dependencies = {}
        for name in ('ext/freetype', 'ext/zstd'):
            pin = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD:' + name], text=True).strip()
            actual = subprocess.check_output(['git', '-C', str(source / name), 'rev-parse', 'HEAD'], text=True).strip()
            if pin != actual or subprocess.check_output(['git', '-C', str(source / name), 'diff', 'HEAD'], text=True):
                raise ValueError('Host dependency differs: ' + name)
            dependencies[name] = pin
        return dependencies
    # Corresponding source is a Git-free snapshot. Its revisions and actual
    # compiled inputs still have to match the linked resource receipt.
    if source != root / 'vendor/PPSSPP':
        raise ValueError('Git-free source must use the corresponding-source layout')
    revisions = json.loads((root / 'SOURCE-REVISIONS.json').read_text())
    receipt = json.loads((root / 'ci/psp-atlas-resources.json').read_text())
    if revisions.get('vendor/PPSSPP') != atlas.REVISION or receipt['revision'] != atlas.REVISION:
        raise ValueError('Archived PPSSPP source revision differs')
    for name, pin in receipt['sourceRevisions'].items():
        if revisions.get('vendor/PPSSPP/' + name) != pin:
            raise ValueError('Archived host dependency differs')
    for name, checksum in receipt['compiledUpstreamSHA256'].items():
        if not name.startswith('PPSSPP/') or '..' in Path(name).parts:
            raise ValueError('Unreviewed archived source path')
        path = source / name.removeprefix('PPSSPP/')
        if path.is_symlink() or atlas.digest(path) != checksum:
            raise ValueError('Archived host source differs: ' + name)
    if atlas.digest(source / 'ext/native/tools/atlastool.cpp') != receipt['upstreamToolSHA256']:
        raise ValueError('Archived rasterizer differs')
    return receipt['sourceRevisions']


def generate(source, work, fetch=False, jobs=4):
    dependencies = source_revisions(source)
    lock = fetch_inputs(source) if fetch else atlas.locked_inputs(source)
    if work.exists() and any(work.iterdir()):
        raise ValueError('Use a fresh atlas output directory')
    work.mkdir(parents=True, exist_ok=True)
    for item in lock['inputs']:
        target = work / 'fonts' / item['file']; target.parent.mkdir(exist_ok=True)
        shutil.copy2(atlas.input_path(item, source), target)
    shutil.copytree(atlas.HOST / 'icons', work / 'icons')
    ranges = json.loads((atlas.HOST / 'ranges.json').read_text())
    upstream = source / 'ext/native/tools/atlastool.cpp'
    tool = work / 'atlastool-ranges.cpp'
    tool.write_text(atlas.tool_source(upstream.read_text(), ranges))
    host = work / 'host'
    run('cmake', '-S', atlas.HOST, '-B', host, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DPPSSPP_SOURCE=' + str(source), '-DATLAS_TOOL_SOURCE=' + str(tool))
    run('cmake', '--build', host, '--parallel', jobs)
    loader_results = {}
    quantization = {}
    for name, flag in (('font', 'A'), ('ppge', 'P')):
        lines = ['2048']
        lines.extend(f'font UBUNTU24 fonts/{file} {flag} {size} {offset}' for file, size, offset in lock['fonts'][name])
        if name == 'ppge':
            lines.extend(f'image {i["name"]} icons/{i["file"]} copy'
                         for i in json.loads((atlas.HOST / 'icons.json').read_text())['images'])
        script = work / (name + '.txt'); script.write_text('\n'.join(lines) + '\n')
        command = [host / 'atlastool', script.name, name]
        if name == 'font': command.append('8888')
        run(*command, cwd=work)
        def validate(prefix):
            result = subprocess.check_output([str(host / 'atlas-validate'), str(work / (name + '_atlas.meta')),
                                              str(work / (name + '_atlas.zim')), str(work / prefix)], text=True)
            return json.loads(result)
        validate('raw-' + name)
        raw_dump = json.loads((work / ('raw-' + name + '.json')).read_text())
        width, height = raw_dump['size']
        quantization[name] = atlas.verify_quantization((work / (name + '-rasterizer.rgba')).read_bytes(),
                                                       (work / ('raw-' + name + '.rgba')).read_bytes(),
                                                       width, height, raw_dump['format'])
        atlas.finish_atlas(work / name, name, raw_dump)
        loader_results[name] = validate('final-' + name)
    spec = importlib.util.spec_from_file_location('atlas_proofs', ROOT / 'ci/prove-ppsspp-atlases.py')
    proof = importlib.util.module_from_spec(spec); spec.loader.exec_module(proof)
    metrics = proof.proofs(work, work / 'proofs')
    previous = json.loads(atlas.MANIFEST.read_text()) if not (source / '.git').exists() else None
    records = {name: {'sha256': atlas.digest(work / name),
                      'originalSHA256': (atlas.digest(source / 'assets' / name) if (source / 'assets' / name).exists()
                                         else previous['resources'][name]['originalSHA256'])} for name in atlas.FILES}
    # Record source identities and portable input paths; no local paths or device metadata.
    host_inputs = {p.relative_to(ROOT).as_posix(): atlas.digest(p)
                   for p in sorted(atlas.HOST.rglob('*')) if p.is_file()}
    generated_inputs = {}
    for record in json.loads((host / 'compile_commands.json').read_text()):
        path = Path(record['file']).resolve()
        if path.is_relative_to(source):
            generated_inputs['PPSSPP/' + path.relative_to(source).as_posix()] = atlas.digest(path)
    receipt = {'schema': 1, 'revision': atlas.REVISION, 'sourceRevisions': dependencies,
               'resources': records, 'fontInputs': lock, 'hostSourceSHA256': host_inputs,
               'upstreamToolSHA256': atlas.digest(upstream), 'composedToolSHA256': atlas.digest(tool),
               'compiledUpstreamSHA256': generated_inputs, 'loaderResults': loader_results,
               'quantizationComparedPixels': quantization,
               'metrics': metrics['atlases'], 'normalization': 'U+3031/U+3032: one horizontal cell; advances and complete sampled glyph retained',
               'proofSHA256': {p.name: atlas.digest(p) for p in sorted((work / 'proofs').iterdir())},
               'generationRecipeSHA256': {p: atlas.digest(ROOT / p) for p in (
                   'ci/build-ppsspp-atlases.py', 'ci/ppsspp_atlas_resources.py', 'ci/prove-ppsspp-atlases.py')},
               'toolchain': subprocess.check_output(['c++', '--version'], text=True).splitlines()[0],
               'acceptance': 'Resource loader/bounds/glyph/icon and visual proof checks only; device layout and game dialogs remain untested.'}
    (work / 'ATLAS-RECEIPT.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print('Atlas resources generated and checked for separate review:', work)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'vendor/PPSSPP')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    generate(args.source.resolve(), args.output.resolve(), args.fetch, args.jobs)
