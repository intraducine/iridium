#!/usr/bin/env python3
"""Select retained manual-build artifacts only when their producer inputs match."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPO = 'intraducine/iridium'
WORKFLOW = '.github/workflows/build-unsigned-ipa.yml'
MEDIA_INPUTS = ('ci/prepare-media-sdk.sh', 'ci/fetch-runtime-inputs.py',
                'ci/check-media-toolchain.py',
                'ci/runtime-inputs.json', 'ci/patches/cerbero-gperf-cxx14.patch',
                'ci/patches/cerbero-assets-library.patch', 'iridium/apps/ios/stikjit.yml',
                'check-public-source.py')
PREFIX_INPUTS = ('testrepos/Madeira/wine', 'testrepos/Madeira/scripts/build-prefix-snapshot.sh',
                 'ci/prepare-prefix.sh', 'ci/sanitize-prefix.py', 'ci/wineboot-from-build.sh')
NATIVE_INPUTS = MEDIA_INPUTS + (
    'ci', 'testrepos/Madeira', 'iridium-fex-ios', 'iridium-wine-ios', 'iridium-runtime-sdk',
    'iridium/apps/ios/Scripts', 'iridium/apps/ios/MediaSupport',
    'iridium/apps/ios/MediaRuntime', 'iridium/apps/ios/ControllerRuntime',
    'iridium/apps/ios/MadeiraSupport/xinput.c', 'iridium/apps/ios/MadeiraSupport/xinput.def',
    'iridium/apps/ios/project.yml', 'iridium/apps/ios/madeira.yml', '.gitmodules')

COMPONENT_INPUTS = {
    'native': tuple(p for p in NATIVE_INPUTS if p != 'ci') +
              ('ci/prepare-native-runtime.sh', 'ci/prepare-runtime-inputs.sh'),
    'wine': ('testrepos/Madeira/wine', 'ci/compile-wine.sh', 'ci/prepare-native-runtime.sh',
             'ci/prepare-runtime-inputs.sh', 'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json'),
    'windows': ('testrepos/Madeira/FEX', 'testrepos/Madeira/research/dxmt',
                'testrepos/Madeira/wine', 'ci/compile-windows-modules.sh',
                'ci/compile-wine.sh', 'ci/prepare-native-runtime.sh', 'ci/prepare-runtime-inputs.sh',
                'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json'),
    'graphics': ('ci/prepare-graphics.sh', 'ci/verify-graphics.py'),
    'jit': ('ci/prepare-stikjit.sh',
            'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json'),
}

SPEC = importlib.util.spec_from_file_location('linux_reuse', ROOT / 'ci/verify-linux-reuse.py')
linux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(linux)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPO + '/' + path], text=True))


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def normalize_source_only_changes(text):
    # Only reviewed transport upgrades: preserve every action input and unknown pin.
    pins = {
        'checkout': ('11bd71901bbe5b1630ceea73d27597364c9af683',
                     'fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09',
                     '3d3c42e5aac5ba805825da76410c181273ba90b1'),
        'upload-artifact': ('ea165f8d65b6e75b540449e92b4886f43607fa02',
                            '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'),
        'download-artifact': ('d3f86a106a0bac45b974a628896c90dbdf5c8093',
                              '3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'),
    }
    for action, versions in pins.items():
        text = re.sub(r'actions/' + action + r'@(?:' + '|'.join(versions) + r')(?: *#[^\n]*)?',
                      'actions/' + action + '@reviewed-compatible', text)
    return text


def producer_job(text, stage):
    text = normalize_source_only_changes(text)
    if stage in COMPONENT_INPUTS:
        # Compare the compiler step, not later packaging or checkpoint plumbing.
        match = re.search(r'^      - name: Compile ' + stage + r'\n.*?(?=^      - |\Z)', text, re.M | re.S)
        if not match:
            raise ValueError('Missing compiler step: ' + stage)
        inherited = ''.join(m.group(0) for m in re.finditer(
            r'^(?:env|defaults):.*?(?=^[^ \n]|\Z)', text, re.M | re.S))
        job = re.search(r'^  build:\n(.*?)(?=^    steps:)', text, re.M | re.S)
        header = '\n'.join(line for line in job[1].splitlines()
                           if not line.startswith(('    needs:', '    if:'))) if job else ''
        return inherited + header + '\n'.join(line for line in match[0].splitlines()
                                      if not line.startswith('        if:'))
    stage = 'build' if stage == 'native-runtime' else stage
    match = re.search(r'^  ' + re.escape(stage) + r':\n(.*?)(?=^  [\w-]+:|\Z)', text, re.M | re.S)
    if not match:
        raise ValueError('Missing producer job: ' + stage)
    # Scheduling does not change produced bytes. All runner, step, environment,
    # Unreviewed action versions and tool-install changes still invalidate reuse.
    inherited = ''.join(m.group(0) for m in re.finditer(
        r'^(?:env|defaults):.*?(?=^[^ \n]|\Z)', text, re.M | re.S))
    return inherited + '\n'.join(line for line in match[1].splitlines()
                     if not line.startswith(('    if:', '    needs:')))


def validate(run, jobs, stage, branch):
    revision = run.get('head_sha', '')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid producer revision')
    if stage == 'linux-userland':
        linux.validate_run(run, jobs, revision, branch)
    elif (run.get('event') != 'workflow_dispatch' or run.get('head_branch') not in ('main', branch)
          or run.get('path') != WORKFLOW
          or run.get('head_repository', {}).get('full_name') != REPO
          or not any(
              (j.get('name') == 'build' and any(
                  step.get('name') == ('Retain ' + stage + ' compilation' if stage in COMPONENT_INPUTS else 'Retain prepared runtime and source')
                  and step.get('conclusion') == 'success' for step in j.get('steps', [])))
              if stage == 'native-runtime' or stage in COMPONENT_INPUTS else
              (j.get('name') == stage and j.get('conclusion') == 'success')
              for j in jobs)):
        raise ValueError('Producer must have completed its artifact stage on main or this branch')
    return revision


def compatible(root, revision, stage):
    subprocess.run(['git', '-C', str(root), 'fetch', '--quiet', '--depth=1', 'origin', revision], check=True)
    paths = {'media': MEDIA_INPUTS, 'native-runtime': NATIVE_INPUTS,
             'prefix': PREFIX_INPUTS, 'linux-userland': linux.INPUTS + ('check-public-source.py',), **COMPONENT_INPUTS}[stage]
    if stage in COMPONENT_INPUTS:
        paths += ('ci/compiled-components.py',)
    for path in paths:
        # ls-tree returns an empty result for absent inputs, so old producers
        # without newly required scripts are invalidated without a Git error.
        if path == 'ci/prepare-media-sdk.sh':
            def compile_script(ref):
                text = git(root, 'show', ref + ':' + path)
                # The sdist manifest only changes the source archive, never compilation.
                text = text.replace('"$PACKAGING_PYTHON" "$ROOT/ci/check-media-source-package.py" "$CERBERO"\n', '')
                return text.replace('if git -C "$ROOT" apply --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch" 2>/dev/null; then\n    git -C "$ROOT" apply --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch"\nelse\n    git -C "$ROOT" apply --reverse --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch"\nfi\n', '')
            if compile_script(revision) == compile_script('HEAD'):
                continue
        if git(root, 'ls-tree', revision, '--', path) != git(root, 'ls-tree', 'HEAD', '--', path):
            raise ValueError('Changed producer input: ' + path)
    if producer_job(git(root, 'show', revision + ':' + WORKFLOW), stage) != producer_job(git(root, 'show', 'HEAD:' + WORKFLOW), stage):
        raise ValueError('Changed producer workflow: ' + stage)


def artifact_name(stage):
    if stage == 'native-runtime' or stage in COMPONENT_INPUTS:
        key = os.environ.get('NATIVE_TOOLCHAIN', '')
        if not re.fullmatch('[0-9a-f]{64}', key):
            raise ValueError('Missing native toolchain fingerprint')
        return ('compiled-' + stage + '-' if stage in COMPONENT_INPUTS else 'native-runtime-with-source-') + key
    if stage == 'prefix':
        return 'wine-prefix'
    return 'media-sdk-with-source' if stage == 'media' else 'linux-runtime-with-source'


def verify_producer(root, run_id, stage, branch):
    if not re.fullmatch('[0-9]{1,20}', str(run_id)):
        raise ValueError('Invalid producer run ID')
    path = 'actions/runs/' + str(run_id)
    revision = validate(api(path), api(path + '/jobs?per_page=100')['jobs'], stage, branch)
    name = artifact_name(stage)
    artifacts = api(path + '/artifacts?per_page=100')['artifacts']
    matching = [a for a in artifacts if a['name'] == name and not a['expired']]
    if len(matching) != 1:
        raise ValueError('Producer artifact absent or expired: ' + name)
    compatible(root, revision, stage)
    return revision


def select(root, stage, branch, explicit=''):
    if explicit:
        verify_producer(root, explicit, stage, branch)
        return explicit
    if stage in COMPONENT_INPUTS:
        # Search retained artifacts, not only the last few runs. A compiler may
        # remain unchanged through many packaging attempts during its lifetime.
        page = 1
        checked = set()
        while True:
            result = api('actions/artifacts?name=' + artifact_name(stage) + '&per_page=100&page=' + str(page))
            for artifact in result['artifacts']:
                run = artifact.get('workflow_run', {})
                run_id = str(run.get('id', ''))
                if (artifact.get('expired') or not run_id or run_id in checked
                        or run_id == os.environ.get('GITHUB_RUN_ID')
                        or run.get('head_branch') not in ('main', branch)):
                    continue
                checked.add(run_id)
                try:
                    verify_producer(root, run_id, stage, branch)
                    return run_id
                except ValueError as error:
                    print(f'Skip {stage} run {run_id}: {error}')
            if page * 100 >= result['total_count']:
                return ''
            page += 1
    runs = api('actions/workflows/build-unsigned-ipa.yml/runs?event=workflow_dispatch&per_page=30')['workflow_runs']
    for run in runs:
        if str(run['id']) == os.environ.get('GITHUB_RUN_ID'):
            continue
        if run.get('head_branch') not in ('main', branch):
            continue
        try:
            verify_producer(root, str(run['id']), stage, branch)
            return str(run['id'])
        except ValueError as error:
            print(f"Skip {stage} run {run['id']}: {error}")
    return ''


if __name__ == '__main__':
    branch = os.environ.get('GITHUB_REF_NAME') or git(ROOT, 'branch', '--show-current')
    reuse = os.environ.get('REUSE_ASSETS', 'true') == 'true'
    values = {}
    for stage, key in [('media', 'media_run_id'), ('linux-userland', 'linux_run_id'), ('prefix', 'prefix_run_id')]:
        explicit = os.environ.get(key.upper(), '')
        if stage in ('linux-userland', 'prefix') and os.environ.get('MEDIA_ONLY') == 'true':
            values[key] = ''
        else:
            values[key] = select(ROOT, stage, branch, explicit) if reuse or explicit else ''
        print(f"{stage}: " + ('reuse run ' + values[key] if values[key] else 'build fresh'))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in values.items():
                output.write(f'{key}={value}\n')
