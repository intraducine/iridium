#!/usr/bin/env python3
"""Fetch public artwork and metadata for the isolated Simulator UI preview.

No game binaries, BIOS, saves, accounts or runtime assets are downloaded.
Artwork stays under .build and is not part of the device app or source control.
"""
from pathlib import Path
import concurrent.futures
import json
import urllib.request
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1] / '.build/iridium-ui-preview/PreviewSamples'
ROOT.mkdir(parents=True, exist_ok=True)
GAMES = [
    ('Hades', 'windows', 'madeira', 'exe', 1145360),
    ('Stardew Valley', 'windows', 'madeira', 'exe', 413150),
    ('Portal', 'windows', 'madeira', 'exe', 400),
    ('Undertale', 'windows', 'madeira', 'exe', 391540),
    ('Tetris', 'gameBoy', 'sameboy', 'gb', 'Nintendo_-_Game_Boy'),
    ("Legend of Zelda, The - Link's Awakening", 'gameBoy', 'sameboy', 'gb', 'Nintendo_-_Game_Boy'),
    ('Pokemon - Crystal Version', 'gameBoyColor', 'sameboy', 'gbc', 'Nintendo_-_Game_Boy_Color'),
    ('Patapon', 'psp', 'ppsspp', 'iso', 'Sony_-_PlayStation_Portable'),
    ('Wipeout Pure', 'psp', 'ppsspp', 'iso', 'Sony_-_PlayStation_Portable'),
    ('Lumines', 'psp', 'ppsspp', 'iso', 'Sony_-_PlayStation_Portable'),
    ('Legend of Zelda, The - The Wind Waker', 'gameCube', 'dolphin', 'iso', 'Nintendo_-_GameCube'),
    ('Metroid Prime', 'gameCube', 'dolphin', 'iso', 'Nintendo_-_GameCube'),
    ("Luigi's Mansion", 'gameCube', 'dolphin', 'iso', 'Nintendo_-_GameCube'),
    ('Super Mario Galaxy', 'wii', 'dolphin', 'iso', 'Nintendo_-_Wii'),
    ('Xenoblade Chronicles', 'wii', 'dolphin', 'iso', 'Nintendo_-_Wii'),
    ('Legend of Zelda, The - A Link Between Worlds', 'nintendo3DS', 'azahar', '3ds', 'Nintendo_-_Nintendo_3DS'),
    ('Animal Crossing - New Leaf', 'nintendo3DS', 'azahar', '3ds', 'Nintendo_-_Nintendo_3DS'),
    ('Shadow of the Colossus', 'playStation2', 'play', 'iso', 'Sony_-_PlayStation_2'),
    ('Katamari Damacy', 'playStation2', 'play', 'iso', 'Sony_-_PlayStation_2'),
    ('Jet Grind Radio', 'dreamcast', 'flycast', 'gdi', 'Sega_-_Dreamcast'),
    ('Crazy Taxi', 'dreamcast', 'flycast', 'gdi', 'Sega_-_Dreamcast'),
    ('Virtua Tennis', 'arcade', 'flycast', 'zip', 'Sega_-_Dreamcast'),
]


def fetch(url, target=None):
    if target and target.is_file(): return target.read_bytes()
    request = urllib.request.Request(url, headers={'User-Agent': 'Iridium-Simulator-Artwork-Preview'})
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read(12 * 1024 * 1024 + 1)
    if len(data) > 12 * 1024 * 1024: raise ValueError('Artwork response too large')
    if target: target.write_bytes(data)
    return data


def index(repository):
    cache = ROOT.parent / (repository + '.json')
    if cache.is_file(): return json.loads(cache.read_bytes())['tree']
    base = f'https://api.github.com/repos/libretro-thumbnails/{repository}/git/trees/'
    tree = json.loads(fetch(base + 'master'))['tree']
    result = []
    for item in tree:
        if item['path'] in {'Named_Boxarts', 'Named_Snaps'}:
            children = json.loads(fetch(base + item['sha']))['tree']
            result += [dict(path=item['path'] + '/' + child['path'], type=child['type']) for child in children]
    cache.write_text(json.dumps(dict(tree=result)))
    return result


indexes = {}
for repository in sorted({g[4] for g in GAMES if isinstance(g[4], str)}):
    indexes[repository] = [item['path'] for item in index(repository) if item['type'] == 'blob']


def sample(game):
    title, platform, runtime, ext, source = game
    identity = str(uuid.uuid5(uuid.NAMESPACE_URL, 'iridium-artwork-preview/' + platform + '/' + title)).upper()
    cover = identity + '-cover.jpg' if platform == 'windows' else identity + '-cover.png'
    if platform == 'windows':
        base = f'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/{source}/'
        cover_url = base + 'library_600x900_2x.jpg'
        background_url = base + 'library_hero.jpg'
    else:
        choices = [p for p in indexes[source] if p.startswith('Named_Boxarts/') and p.split('/')[-1].lower().startswith(title.lower() + ' (')]
        if not choices: raise ValueError('No exact artwork title: ' + title)
        choices.sort(key=lambda p: ('(USA' not in p, '(World' not in p, len(p), p))
        path = choices[0]
        base = f'https://raw.githubusercontent.com/libretro-thumbnails/{source}/master/'
        cover_url = base + urllib.parse.quote(path)
        snap = path.replace('Named_Boxarts/', 'Named_Snaps/')
        background_url = base + urllib.parse.quote(snap) if snap in indexes[source] else None
    fetch(cover_url, ROOT / cover)
    background = identity + '-background.jpg' if platform == 'windows' else identity + '-background.png'
    if background_url: fetch(background_url, ROOT / background)
    result = dict(id=identity, title=title, platform=platform, runtime=runtime, ext=ext,
                  steamID=source if platform == 'windows' else None, cover=cover,
                  background=background if background_url else None)
    return result, dict(title=title, cover=cover_url, background=background_url)


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(sample, GAMES))
(ROOT / 'samples.json').write_text(json.dumps([r[0] for r in results], indent=2))
(ROOT / 'artwork-sources.json').write_text(json.dumps([r[1] for r in results], indent=2))
print(f'Prepared {len(results)} metadata-only games with public artwork at {ROOT}')
