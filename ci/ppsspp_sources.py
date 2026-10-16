"""Source pins and notices shared by the native PPSSPP component builder."""
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'fa50bb1976065c4f8b1b47af227d367fe9771555'

DEPENDENCIES = (
    'libretro/libretro-common', 'ext/SPIRV-Cross', 'ext/armips', 'ext/glslang',
    'ext/cpu_features', 'ext/libchdr', 'ext/lua', 'ext/nanosvg', 'ext/rapidjson',
    'ext/rcheevos', 'ext/zstd', 'ext/aemu_postoffice', 'ext/OpenXR-SDK', 'ext/miniupnp',
)


def notices(source, destination):
    """Retain upstream terms and embedded source notices; source delivery is separate."""
    destination.mkdir(parents=True, exist_ok=True)
    terms = {
        'PPSSPP-LICENSE.TXT': source / 'LICENSE.TXT',
        'GPL-3.0.txt': ROOT / 'vendor/Madeira/COPYING',
        'LGPL-2.1.txt': ROOT / 'iridium/apps/ios/MadeiraSupport/Notices/Media/ffmpeg-7.1/COPYING.LGPLv2.1',
    }
    for name, path in terms.items():
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing required license text: ' + name)
        shutil.copy2(path, destination / name)
    chunks = ['PPSSPP source attribution at ' + REVISION + '\n'
              'This inventory retains source notices, including some unused implementation files.\n'
              'The component manifest identifies the selected dependencies and actual compiled inputs.\n']
    roots = [source / name for name in ('Common', 'Core', 'GPU', 'UI', 'ios', 'ext', 'ffmpeg', 'assets')]
    for base in roots:
        for path in sorted(base.rglob('*')):
            if '.git' in path.parts or path.is_symlink() or not path.is_file():
                continue
            name = path.name.lower()
            if name.startswith(('license', 'copying', 'notice')) and path.stat().st_size <= 256 * 1024:
                content = path.read_text(errors='replace')
            elif path.suffix in ('.c', '.cpp', '.cc', '.h', '.hpp'):
                # Leading comment blocks contain the original per-file grants;
                # never rewrite them into a guessed common SPDX identifier.
                with path.open(errors='replace') as stream:
                    prefix = stream.read(16384).lstrip('\ufeff\r\n ')
                match = re.match(r'(?:(?:/\*.*?\*/|//[^\n]*(?:\n|$))\s*)+', prefix, re.S)
                content = match.group(0) if match else ''
                if not re.search(r'copyright|licen[sc]e|permission', content, re.I):
                    continue
            else:
                continue
            chunks.append('\n--- ' + path.relative_to(source).as_posix() + ' ---\n' + content)
    (destination / 'SOURCE-NOTICES.txt').write_text('\n'.join(chunks))
