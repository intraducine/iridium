#!/usr/bin/env python3
"""Select retained manual-build artifacts only when their producer inputs match."""
import ast
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import symtable

ROOT = Path(__file__).resolve().parents[1]
REPO = os.environ.get('GITHUB_REPOSITORY', 'intraducine/iridium')
WORKFLOW = '.github/workflows/build-unsigned-ipa.yml'
MEDIA_INPUTS = ('ci/prepare-media-sdk.sh', 'ci/fetch-runtime-inputs.py',
                'ci/check-media-toolchain.py',
                'ci/runtime-inputs.json', 'ci/patches/cerbero-gperf-cxx14.patch',
                'ci/patches/cerbero-assets-library.patch', 'ci/patches/cerbero-cargo-source-cache.patch', 'ci/patches/cerbero-meson-source-cache.patch',
                'ci/patches/cerbero-spandsp-mirror.patch',
                'iridium/apps/ios/stikjit.yml',
                'check-public-source.py')
SPANDSP_MIRROR_PATCH = 'ci/patches/cerbero-spandsp-mirror.patch'
SPANDSP_MIRROR_SHA256 = 'f3976698deeb45698587c1a5ee63b76ce7acfe2a6507c7c2e33431e631f348cb'
SPANDSP_OLD_LOOP = 'cerbero-meson-source-cache.patch; do'
SPANDSP_NEW_LOOP = 'cerbero-meson-source-cache.patch cerbero-spandsp-mirror.patch; do'
PREFIX_INPUTS = ('testrepos/Madeira/wine', 'testrepos/Madeira/scripts/build-prefix-snapshot.sh',
                 'ci/prepare-prefix.sh', 'ci/sanitize-prefix.py', 'ci/wineboot-from-build.sh')
NATIVE_INPUTS = MEDIA_INPUTS + (
    'ci', 'testrepos/Madeira', 'iridium-fex-ios', 'iridium-wine-ios', 'iridium-runtime-sdk',
    'iridium/apps/ios/Scripts', 'iridium/apps/ios/MediaSupport',
    'iridium/apps/ios/MediaRuntime', 'iridium/apps/ios/ControllerRuntime',
    'iridium/apps/ios/MadeiraSupport/xinput.c', 'iridium/apps/ios/MadeiraSupport/xinput.def',
    'iridium/apps/ios/MadeiraSupport/prerequisites.c',
    'iridium/apps/ios/project.yml', 'iridium/apps/ios/madeira.yml', '.gitmodules')

COMPONENT_INPUTS = {
    'madeira-native': ('vendor/Madeira', 'ci/madeira-frontend.py', 'ci/runtime-inputs.json',
                       'ci/local_build_tools.py', 'ci/fetch-runtime-inputs.py'),
    'madeira-windows': ('vendor/Madeira', 'ci/madeira-frontend.py', 'ci/runtime-inputs.json',
                        'ci/local_build_tools.py', 'ci/fetch-runtime-inputs.py'),
    # App UI, docs, and tools are not inputs to the native compiler recipes.
    # Track Madeira's compiler trees rather than its entire repository.
    # Both XcodeGen specs configure the later app build, not these libraries.
    # Native targets and flags live in the tracked compiler recipes below.
    # Controller and prerequisite helpers are rebuilt after every restore;
    # cached copies are replaced before staging, so their edits cannot stale
    # the library checkpoint. Keep the media compiler script as a library input.
    'native': tuple(p for p in NATIVE_INPUTS if p not in {
                  'ci', 'iridium/apps/ios/project.yml',
                  'iridium/apps/ios/madeira.yml', 'testrepos/Madeira',
                  'iridium/apps/ios/Scripts', 'iridium/apps/ios/ControllerRuntime',
                  'iridium/apps/ios/MadeiraSupport/xinput.c',
                  'iridium/apps/ios/MadeiraSupport/xinput.def',
                  'iridium/apps/ios/MadeiraSupport/prerequisites.c'}) +
              ('testrepos/Madeira/FEX', 'testrepos/Madeira/wine',
               'testrepos/Madeira/build', 'testrepos/Madeira/research/dxmt',
               'testrepos/Madeira/research/freetype', 'testrepos/Madeira/toolchains',
               'testrepos/Madeira/research/madeira-d3d12',
               'testrepos/Madeira/research/remote-metal',
               'testrepos/Madeira/app/Madeira/Winios',
               'ci/prepare-native-runtime.sh', 'ci/prepare-runtime-inputs.sh',
               'iridium/apps/ios/Scripts/build_media_runtime.sh',
               'ci/apply-fex-runtime-corrections.py',
               'ci/patches/rpmalloc-compact-runtime.patch',
               'ci/patches/fex-thread-init-failure.patch'),
    'wine': ('testrepos/Madeira/wine', 'testrepos/Madeira/build/madeira_cfg.h',
             'ci/compile-wine.sh', 'testrepos/Madeira/build/wine-i386', 'ci/prepare-native-runtime.sh',
             'ci/prepare-runtime-inputs.sh', 'ci/apply-fex-runtime-corrections.py',
             'ci/patches/fex-thread-init-failure.patch',
             'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json'),
    'windows': ('testrepos/Madeira/research/madeira-d3d12',
                'testrepos/Madeira/build/madeira-d3d12', 'testrepos/Madeira/FEX', 'testrepos/Madeira/research/dxmt',
                'testrepos/Madeira/wine', 'ci/compile-windows-modules.sh',
                'ci/compile-wine.sh', 'testrepos/Madeira/build/wine-i386', 'ci/prepare-native-runtime.sh', 'ci/prepare-runtime-inputs.sh',
                'ci/apply-fex-runtime-corrections.py',
                'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json',
                'ci/patches/rpmalloc-compact-runtime.patch',
                'ci/patches/fex-thread-init-failure.patch'),
    'graphics': ('ci/prepare-graphics.sh', 'ci/verify-graphics.py'),
    'jit': ('ci/prepare-stikjit.sh',
            'ci/fetch-runtime-inputs.py', 'ci/runtime-inputs.json'),
}

# These functions only run in the later app/presentation actions. Keep every
# other function, import, global, signature and command-line route as input.
# In particular, compiler helpers are not an allowlist that can miss new code.
FRONTEND_APP_FUNCTIONS = frozenset(('overlay', 'project', 'refresh_generated_tree',
                                    'prepare', 'verify', 'app'))
FRONTEND_IMPORTS = frozenset(('argparse', 'plistlib', 'shutil', 'subprocess', 'shlex',
                              'hashlib', 'importlib.util', 'inspect', 'json', 'os',
                              'time', 'sys', 'madeira_presentation'))
# This reviewed route cannot run app preparation during a compiler action.
# A new CLI shape uses whole-file comparison until its isolation is reviewed.
FRONTEND_MAIN = """if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'verify', 'app', 'native', 'windows', 'toolchains', 'check-bundle'))
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    if args.action == 'check-bundle':
        if args.app is None: parser.error('check-bundle requires the built app path')
        check_bundle(args.app)
        print('The built app contains the pinned Madeira runtime farms, WoW64 and D3D12.')
    else:
        if args.app is not None: parser.error('Only check-bundle accepts an app path')
        {'prepare': prepare, 'verify': verify, 'app': app, 'native': native, 'windows': windows, 'toolchains': toolchains}[args.action]()
"""


def frontend_compiler_source(text):
    """Exclude reviewed app bodies without executing producer source.

    Unknown layouts or dependencies retain the original whole-file contract.
    Preserve raw compiler text: native completion stamps use inspect.getsource,
    so even a comment-only recipe edit must still invalidate the artifact.
    """
    try:
        tree = ast.parse(text)
        symbols = symtable.symtable(text, 'madeira-frontend.py', 'exec')
    except (SyntaxError, ValueError):
        return text
    lines = text.splitlines(keepends=True)
    names, ignored, retained = set(), [], []
    main = ast.dump(ast.parse(FRONTEND_MAIN).body[0])
    root = ast.dump(ast.parse("Path(__file__).resolve().parents[1]", mode='eval').body)
    if not tree.body or ast.dump(tree.body[-1]) != main:
        return text
    def app_reference(table):
        return (any(s.get_name() in FRONTEND_APP_FUNCTIONS and s.is_global() and s.is_referenced()
                    for s in table.get_symbols())
                or any(app_reference(child) for child in table.get_children()))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            if node.name in names:
                return text
            names.add(node.name)
            if node.name in FRONTEND_APP_FUNCTIONS:
                # Defaults, annotations and decorators can execute app bodies
                # at import time. Only ordinary, inert definitions are omitted.
                if (node.decorator_list or node.returns or node.args.defaults
                        or any(node.args.kw_defaults) or getattr(node, 'type_params', [])
                        or any(arg.annotation for arg in ast.walk(node.args) if isinstance(arg, ast.arg))
                        or node.body[0].lineno == node.lineno
                        or not lines[node.lineno - 1].rstrip().endswith(':')):
                    return text
                ignored.append(node)
                continue
            if getattr(node, 'type_params', []):
                return text
            table = next(t for t in symbols.get_children() if t.get_name() == node.name)
            headers = node.decorator_list + [node.args] + ([node.returns] if node.returns else [])
            if (app_reference(table) or any(isinstance(n, ast.Name) and n.id in FRONTEND_APP_FUNCTIONS
                                           for header in headers for n in ast.walk(header))):
                return text
            if any(isinstance(n, (ast.Import, ast.ImportFrom))
                   or isinstance(n, ast.Name) and n.id == '__file__' for n in ast.walk(node)):
                return text  # Dynamic dependencies and self-reading need the full file.
            # A local argument named "app" is not a call into the app action.
            retained.extend(n for n in ast.walk(node)
                            if not isinstance(n, ast.Name) or n.id not in FRONTEND_APP_FUNCTIONS)
            continue
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            if not (isinstance(node, ast.Import) and all(a.name in FRONTEND_IMPORTS and not a.asname for a in node.names)
                    or isinstance(node, ast.ImportFrom) and node.module == 'pathlib' and not node.level
                    and len(node.names) == 1 and node.names[0].name == 'Path' and not node.names[0].asname):
                return text
            imported = {a.asname or a.name.split('.')[0] for a in node.names}
            if '*' in imported or names & imported:
                return text
            names.update(imported)
        elif isinstance(node, ast.Assign):
            if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
                return text
            name = node.targets[0].id
            if name in names:
                return text
            names.add(name)
            # Reviewed module initialization is literals and checkout paths;
            # arbitrary module-time calls could invoke otherwise unused code.
            try:
                ast.literal_eval(node.value)
            except (ValueError, TypeError):
                value = node.value
                while isinstance(value, ast.BinOp) and isinstance(value.op, ast.Div) and isinstance(value.right, ast.Constant):
                    value = value.left
                if not ((name == 'ROOT' and ast.dump(node.value) == root)
                        or isinstance(value, ast.Name) and value.id == 'ROOT'):
                    return text
        elif isinstance(node, ast.If) and node is tree.body[-1] and ast.dump(node) == main:
            # Keep its raw source in the comparison, but the known app-action
            # references in this isolated dispatch need no dependency fallback.
            continue
        elif not (isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)
                  and isinstance(node.value.value, str)):
            return text
        retained.extend(ast.walk(node))
    if not FRONTEND_APP_FUNCTIONS <= {n.name for n in ignored}:
        return text
    for node in retained:
        if (isinstance(node, ast.Name) and node.id in FRONTEND_APP_FUNCTIONS | {
                'globals', 'locals', 'vars', 'eval', 'exec', 'compile', 'getattr', 'setattr', 'delattr',
                '__import__', '__builtins__', 'type', 'object', 'dir'}
                or isinstance(node, ast.Constant) and isinstance(node.value, str)
                    and (node.value in FRONTEND_APP_FUNCTIONS or 'madeira-frontend.py' in node.value)
                or isinstance(node, ast.Attribute) and (node.attr.startswith('__') or node.attr in {
                    'modules', '_getframe', 'currentframe', 'import_module', 'load_module'}
                    or node.attr in FRONTEND_APP_FUNCTIONS
                    or isinstance(node.value, ast.Name) and node.value.id == 'inspect' and node.attr != 'getsource')):
            return text
    for node in reversed(ignored):
        lines[node.lineno:node.end_lineno] = ['    pass\n']
    return ''.join(lines)

SPEC = importlib.util.spec_from_file_location('linux_reuse', ROOT / 'ci/verify-linux-reuse.py')
linux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(linux)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPO + '/' + path], text=True))


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def media_mirror_transport_only(root, revision):
    """The pinned SpanDSP archive is unchanged; only its download URL moved."""
    if git(root, 'ls-tree', revision, '--', SPANDSP_MIRROR_PATCH):
        return False
    patch = root / SPANDSP_MIRROR_PATCH
    if not patch.is_file() or hashlib.sha256(patch.read_bytes()).hexdigest() != SPANDSP_MIRROR_SHA256:
        return False
    script = 'ci/prepare-media-sdk.sh'
    old = git(root, 'show', revision + ':' + script)
    new = git(root, 'show', 'HEAD:' + script)
    return old.count(SPANDSP_OLD_LOOP) == 1 and new == old.replace(SPANDSP_OLD_LOOP, SPANDSP_NEW_LOOP)


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


def validate(run, jobs, stage, branch, allow_other_branch=False):
    revision = run.get('head_sha', '')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid producer revision')
    if stage == 'linux-userland':
        linux.validate_run(run, jobs, revision, branch, allow_other_branch=allow_other_branch)
    elif (run.get('event') != 'workflow_dispatch'
          or (run.get('head_branch') not in ('main', branch) and not allow_other_branch)
          or run.get('path') != WORKFLOW
          or run.get('head_repository', {}).get('full_name') != REPO
          or not any(
              (j.get('name') == 'build' and any(
                  step.get('name') == ('Retain ' + stage + ' compilation' if stage in COMPONENT_INPUTS else 'Retain prepared runtime and source')
                  and step.get('conclusion') == 'success' for step in j.get('steps', [])))
              if stage == 'native-runtime' or stage in COMPONENT_INPUTS else
              (j.get('name') == stage and j.get('conclusion') == 'success')
              for j in jobs)):
        raise ValueError('Producer must have completed its artifact stage on trusted current history')
    return revision


def compatible(root, revision, stage):
    linux.fetch_revision(root, revision)
    paths = {'media': MEDIA_INPUTS, 'native-runtime': NATIVE_INPUTS,
             'prefix': PREFIX_INPUTS, 'linux-userland': linux.INPUTS + ('check-public-source.py',), **COMPONENT_INPUTS}[stage]
    if stage in COMPONENT_INPUTS:
        paths += ('ci/compiled-components.py',)
    mirror_only = stage == 'media' and media_mirror_transport_only(root, revision)
    for path in paths:
        if mirror_only and path in ('ci/prepare-media-sdk.sh', SPANDSP_MIRROR_PATCH):
            continue
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
        if stage in ('madeira-native', 'madeira-windows') and path == 'ci/madeira-frontend.py':
            old = git(root, 'ls-tree', revision, '--', path)
            new = git(root, 'ls-tree', 'HEAD', '--', path)
            if (old and new and old.split()[:2] == new.split()[:2]
                    and frontend_compiler_source(git(root, 'show', revision + ':' + path))
                    == frontend_compiler_source(git(root, 'show', 'HEAD:' + path))):
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


def can_reuse_run(run_id):
    current = os.environ.get('GITHUB_RUN_ID', '')
    if str(run_id) != current:
        return True
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '1')
    return attempt.isdigit() and int(attempt) > 1


def verify_producer(root, run_id, stage, branch):
    if not re.fullmatch('[0-9]{1,20}', str(run_id)):
        raise ValueError('Invalid producer run ID')
    path = 'actions/runs/' + str(run_id)
    run = api(path)
    # Reruns keep the same workflow run ID. Inspect all attempts so a successful
    # retained artifact from an earlier attempt can satisfy producer validation.
    jobs = api(path + '/jobs?filter=all&per_page=100')['jobs']
    other_branch = run.get('head_branch') not in ('main', branch)
    revision = validate(run, jobs, stage, branch, allow_other_branch=other_branch)
    if other_branch and not linux.producer_revision_is_in_history(root, revision):
        raise ValueError('Producer revision is not in trusted merged history')
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
                    or not can_reuse_run(run_id)):
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


if __name__ == '__main__':
    branch = os.environ.get('GITHUB_REF_NAME') or git(ROOT, 'branch', '--show-current')
    reuse = os.environ.get('REUSE_ASSETS', 'true') == 'true'
    values = {}
    for stage, key in [('media', 'media_run_id'), ('linux-userland', 'linux_run_id'), ('prefix', 'prefix_run_id')]:
        explicit = os.environ.get(key.upper(), '')
        if ((stage in ('linux-userland', 'prefix') and os.environ.get('MEDIA_ONLY') == 'true')
                or (stage == 'linux-userland' and os.environ.get('IRIDIUM_RUNTIME_PROFILE') == 'madeira')):
            values[key] = ''
        else:
            values[key] = select(ROOT, stage, branch, explicit) if reuse or explicit else ''
        print(f"{stage}: " + ('reuse run ' + values[key] if values[key] else 'build fresh'))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in values.items():
                output.write(f'{key}={value}\n')
