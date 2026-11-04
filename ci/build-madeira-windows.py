"""Run existing Windows recipes with checked object cleanup between modules."""
import importlib.util
import json
from pathlib import Path
import shutil
import madeira_components

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(frontend, space):
    sdk = frontend.compiler_identity()
    names = madeira_components.EXTRA
    for name in names:
        # Validate each existing contract before removing its build-only objects.
        try:
            madeira_components.EXTRA = (name,)
            madeira_components.build(frontend.UPSTREAM, sdk)
        finally:
            madeira_components.EXTRA = names
        record = json.loads((frontend.UPSTREAM / '.build' / ('iridium-' + name + '.json')).read_text())
        space.cleanup_madeira_module(ROOT, frontend.UPSTREAM, name, record['key'])
    if shutil.disk_usage(ROOT).free < 40 * 1024**3:
        raise ValueError('Madeira i386 needs 20 GiB reserve plus 20 GiB working space')
    frontend.windows()
    record = json.loads((frontend.UPSTREAM / '.build/iridium-i386.json').read_text())
    space.cleanup_madeira_module(ROOT, frontend.UPSTREAM, 'i386', record['key'])


if __name__ == '__main__':
    build(load('windows_frontend', 'madeira-frontend.py'), load('windows_space', 'free-build-space.py'))
