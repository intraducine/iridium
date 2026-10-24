"""Read build pins from the existing source inventory, one engine at a time."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'UPSTREAM-SOURCES.json'
STAGES = {'madeira-native': 'madeira', 'madeira-windows': 'madeira',
          'host': 'flycast', 'psp': 'ppsspp', 'sameboy': 'sameboy',
          'dolphin': 'dolphin', 'azahar': 'azahar', 'play': 'play', 'flycast': 'flycast'}


def relative_path(value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts or str(path) != value or value in ('', '.'):
        raise ValueError('Invalid engine input path: ' + value)
    return value


def get(name, data=None):
    if data is None:
        data = json.loads((ROOT / MANIFEST).read_text())
    entries = [data['frontend_runtime']] if name == 'madeira' else [
        entry for entry in data['console_runtimes'] if entry['id'] == name]
    if len(entries) != 1:
        raise ValueError('Expected one engine pin: ' + name)
    entry = entries[0]
    if not re.fullmatch('[0-9a-f]{40}', entry['revision']):
        raise ValueError('Invalid engine revision: ' + name)
    relative_path(entry['path'])
    if not re.fullmatch(r'https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', entry['upstream']):
        raise ValueError('Invalid engine source: ' + name)
    for artifact in entry.get('artifacts', {}).values():
        if Path(relative_path(artifact['filename'])).name != artifact['filename'] or not re.fullmatch('[0-9a-f]{64}', artifact['sha256']):
            raise ValueError('Invalid engine artifact: ' + name)
    for dependency in entry.get('buildDependencies', {}).values():
        if 'inputs' in dependency:
            relative_path(dependency['inputs'])
        if 'revision' in dependency and not re.fullmatch('[0-9a-f]{40}', dependency['revision']):
            raise ValueError('Invalid engine dependency revision: ' + name)
    return entry


def selected(stage, data=None):
    entry = get(STAGES[stage], data)
    return {key: entry[key] for key in ('path', 'upstream', 'revision', 'releaseTag',
            'version', 'dependencies', 'buildDependencies', 'artifacts') if key in entry}


def verify(root=ROOT):
    data = json.loads((root / MANIFEST).read_text())
    for name in ('madeira', *(entry['id'] for entry in data['console_runtimes'])):
        entry = get(name, data)
        tree = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '--', entry['path']], text=True).split()
        if len(tree) < 3 or tree[:3] != ['160000', entry['revision'], '0']:
            raise ValueError('Update the matching submodule pin: ' + entry['path'])
        source = root / entry['path']
        if (source / '.git').exists() and subprocess.check_output(
                ['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != entry['revision']:
            raise ValueError('Checked-out engine differs from its pin: ' + entry['path'])
        print(name + ': ' + entry['revision'])


if __name__ == '__main__':
    verify()
