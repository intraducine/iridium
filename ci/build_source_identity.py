"""Build-time source provenance for the app; no runtime/compiler recipe changes."""
import json
import re
import subprocess

def source_identity(ROOT, PSP_REVISION):
    """Never use an enclosing checkout's HEAD for an extracted source archive."""
    revision, state = 'Unknown', 'Unknown'
    archived = {}
    if (ROOT / '.git').exists():
        try:
            revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
            dirty = subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain',
                '--untracked-files=normal', '--ignore-submodules=all'], text=True).strip()
            state = 'Local changes' if dirty else 'Committed source'
        except (OSError, subprocess.CalledProcessError):
            revision = 'Unknown'
    else:
        try:
            archived = json.loads((ROOT / 'SOURCE-REVISIONS.json').read_text())
            if not isinstance(archived, dict): raise ValueError('Invalid source revisions')
            revision = archived.get('.', 'Unknown')
            state = 'Source archive; local changes unknown'
        except (OSError, ValueError, AttributeError):
            archived = {}
    if not isinstance(revision, str) or not re.fullmatch('[0-9a-f]{40}', revision):
        revision, state = 'Unknown', 'Unknown'
    pins = json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['frontend_runtime']
    runtimes = {'Madeira': pins['revision'], **pins['dependencies'], 'PPSSPP': PSP_REVISION}
    try:
        runtimes['SameBoy'] = (subprocess.check_output(['git', '-C', str(ROOT / 'vendor/SameBoy'), 'rev-parse', 'HEAD'], text=True).strip()
            if (ROOT / '.git').exists() else archived.get('vendor/SameBoy', 'Unknown'))
    except (OSError, subprocess.CalledProcessError):
        runtimes['SameBoy'] = 'Unknown'
    return {'IridiumRootRevision': revision, 'IridiumSourceState': state, 'IridiumRuntimeRevisions': runtimes}

