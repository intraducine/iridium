"""Validate pinned Madeira patches without changing a checkout's real index."""
import os
from pathlib import Path
import subprocess
import tempfile


def expected(upstream, component):
    repo = upstream / component
    if not (repo / '.git').exists():
        return {}  # Corresponding-source archives already contain the applied patch bytes.
    folder = 'dock' if component == 'madeira-dock' else component.lower()
    patches = sorted((upstream / 'build' / (folder + '-patches')).glob('*.patch'))
    if not patches:
        return {}
    with tempfile.TemporaryDirectory(prefix='iridium-patch-index-') as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(scratch) / 'index'))
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repo), *args], env=env)
        git('read-tree', 'HEAD')
        for patch in patches:
            git('apply', '--cached', str(patch))
        names = git('diff', '--cached', '--name-only', '-z', 'HEAD').split(b'\0')
        result = {name.decode(): git('show', ':' + name.decode()) for name in names if name}
        if component == 'dxmt':
            # The pinned shader generator adds this Metal SDK compatibility branch.
            name = 'src/airconv/shaders/air_tessellation.metal'
            text = git('show', 'HEAD:' + name).decode()
            old = '  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);\n'
            if text.count(old) != 1: raise ValueError('Unexpected DXMT atomic shader source')
            result[name] = text.replace(old, '#ifdef __METAL_MEMORY_FLAGS_NONE__\n' + old.replace('__);', '__, __METAL_MEMORY_FLAGS_NONE__);') + '#else\n' + old + '#endif\n').encode()
        return result
