"""Stage Iridium-owned application code independently of an engine's UI tree."""
from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
APP = Path('iridium/apps/ios/App')
PROJECT = Path('iridium/apps/ios/AppProject/Madeira.xcodeproj/project.pbxproj')
IMPORT_MARKER = '// IRIDIUM-OWNED-UNIT\n'


def ownership(root=ROOT):
    return json.loads((root / APP / 'source-ownership.json').read_text())


def logical_source(name, root=ROOT):
    """Read actual shipping source; old source-unit names are test compatibility only."""
    units = ownership(root)['logicalUnits'].get(name)
    if units:
        parts = []
        for unit in units:
            text = (root / APP / unit['path']).read_text()
            if unit.get('stripImportPrefix'):
                text = text.split(IMPORT_MARKER, 1)[1]
            parts.append(text)
        return ''.join(parts)
    matches = [path for path in main_sources(root) if path.name == name]
    return matches[0].read_text() if len(matches) == 1 else None


def main_sources(root=ROOT):
    app = root / APP
    sources = [path for path in app.rglob('*.swift') if 'Helper' not in path.relative_to(app).parts]
    for folder in ('MadeiraFrontend', 'RuntimeSupport'):
        sources.extend((root / 'iridium/apps/ios' / folder).glob('*.swift'))
    sources.append(root / 'iridium/apps/ios/Iridium/RuntimeDiagnosticLogFiles.swift')
    names = [path.name for path in sources]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate app-owned Swift source names')
    return sorted(sources)


def stage(app, root=ROOT):
    # Upstream Swift screens/models must never slip into the app after a pin bump.
    for path in app.rglob('*.swift'):
        path.unlink()
    destination = app / 'Madeira'
    for source in main_sources(root):
        shutil.copy2(source, destination / source.name)
    metadata = root / PROJECT.parent.parent / 'Metadata'
    shutil.copy2(metadata / 'Info.plist', destination / 'Info.plist')
    shutil.copy2(metadata / 'Madeira.entitlements', destination / 'Madeira.entitlements')
    shutil.copy2(metadata / 'Helper-Info.plist', app / 'MadeiraJITHelper/Info.plist')
    helper = root / APP / ownership(root)['helper']
    shutil.copy2(helper, app / 'MadeiraJITHelper/MadeiraJITHelper.swift')
    resources = root / APP / 'Resources'
    catalog = destination / 'Assets.xcassets'
    if catalog.exists():
        shutil.rmtree(catalog)
    shutil.copytree(resources / 'Assets.xcassets', catalog)
    for source in resources.iterdir():
        if source.is_file():
            shutil.copy2(source, destination / source.name)
    shutil.copy2(root / APP / 'Windows/WiniosGamepad.c', destination / 'Winios/WiniosGamepad.c')
    return [path.name for path in main_sources(root)]


def verify(app, root=ROOT):
    expected = {path.name: path for path in main_sources(root)}
    actual = list((app / 'Madeira').rglob('*.swift'))
    if {path.name for path in actual} != set(expected) or len(actual) != len(expected):
        raise ValueError('Application Swift source set differs from Iridium-owned sources')
    for path in actual:
        if path.read_bytes() != expected[path.name].read_bytes():
            raise ValueError('Staged app-owned source differs: ' + path.name)
    helper = root / APP / ownership(root)['helper']
    if (app / 'MadeiraJITHelper/MadeiraJITHelper.swift').read_bytes() != helper.read_bytes():
        raise ValueError('Staged JIT service differs from its owned source')
    for source in (root / APP / 'Resources').rglob('*'):
        if source.is_file():
            target = app / 'Madeira' / source.relative_to(root / APP / 'Resources')
            if not target.is_file() or target.read_bytes() != source.read_bytes():
                raise ValueError('Staged app resource differs: ' + str(source.relative_to(root / APP)))
    if (app / 'Madeira/Winios/WiniosGamepad.c').read_bytes() != (root / APP / 'Windows/WiniosGamepad.c').read_bytes():
        raise ValueError('Staged input adapter differs from its owned source')
