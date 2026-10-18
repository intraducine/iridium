#!/usr/bin/env python3
"""Render glyph proofs from the production parser's dumps at upstream sizes."""
import argparse
import hashlib
import json
import math
from pathlib import Path
from ppsspp_atlas_resources import HOST, icon_pixels, png_write

SAMPLES = [
    ('Latin', 'God of War · Continue'), ('Greek', 'Ελληνικά'),
    ('Cyrillic', 'Русский язык'), ('Hebrew glyph order', 'עברית'),
    ('Thai glyph order', 'ภาษาไทย'), ('Coptic', 'ϢϣϤϥϦϧϨϩϪϫϬϭϮϯ'),
    ('Japanese', '日本語 字幕'), ('Chinese', '简体中文'),
    ('Korean', '한국어'), ('Vertical forms in horizontal cells', '〱〲'),
]


def check_dump(dump, required, raw, atlas):
    if dump['size'] != [2048, 2048] or len(raw) != 2048 * 2048 * 4:
        raise ValueError('Atlas canvas differs')
    font = dump['fonts'][0]
    if font['name'] != required['fontName'] or font['ranges'] != required['ranges']:
        raise ValueError('Atlas font ID/ranges differ')
    if set(map(int, font['glyphs'])) != set(required['requiredCodepoints']):
        raise ValueError('Atlas loses or unexpectedly adds glyphs')
    if atlas == 'ppge':
        icons = json.loads((HOST / 'icons.json').read_text())['images']
        if set(i['name'] for i in dump['images']) != set(i['name'] for i in icons):
            raise ValueError('PSP image IDs differ')
        for icon in icons:
            image = next(i for i in dump['images'] if i['name'] == icon['name'])
            if image['size'] != icon['size']:
                raise ValueError('PSP image size differs')
            sx = round(image['uv'][0] * 2048 - .5)
            sy = round(image['uv'][1] * 2048 - .5)
            w, h = image['size']
            pixels = b''.join(raw[((sy + y) * 2048 + sx) * 4:((sy + y) * 2048 + sx + w) * 4] for y in range(h))
            if hashlib.sha256(pixels).hexdigest() != icon['rgbaSHA256']:
                raise ValueError('PSP icon texels changed')
    elif dump['images']:
        raise ValueError('Unexpected UI atlas images')
    return font


class Proof:
    def __init__(self, dump, pixels, width, height):
        self.texture = pixels
        self.dump = dump
        self.font = dump['fonts'][0]
        self.width, self.height = width, height
        self.canvas = bytearray(bytes((25, 31, 40, 255)) * width * height)
        self.records = []

    def sample_alpha(self, x, y):
        x0, y0 = math.floor(x), math.floor(y)
        fx, fy = x - x0, y - y0
        def at(dx, dy):
            px, py = min(2047, max(0, x0 + dx)), min(2047, max(0, y0 + dy))
            return self.texture[(py * 2048 + px) * 4 + 3] / 255
        return ((1 - fx) * at(0, 0) + fx * at(1, 0)) * (1 - fy) + ((1 - fx) * at(0, 1) + fx * at(1, 1)) * fy

    def text(self, text, x, y, scale):
        start = x
        baseline = y + self.font['ascend'] * scale
        clipped = 0
        for char in text:
            glyph = self.font['glyphs'].get(str(ord(char)))
            if glyph is None:
                raise ValueError('Proof requests an unavailable glyph: ' + char)
            sx, sy, ex, ey, ox, oy, advance, pw, ph = glyph
            left, top = x + ox * scale, baseline + oy * scale
            right, bottom = left + pw * scale, top + ph * scale
            for py in range(math.floor(top), math.ceil(bottom)):
                for px in range(math.floor(left), math.ceil(right)):
                    fx, fy = (px + .5 - left) / (pw * scale), (py + .5 - top) / (ph * scale)
                    if not (0 <= fx <= 1 and 0 <= fy <= 1):
                        continue
                    alpha = self.sample_alpha((sx + (ex - sx) * fx) * 2048 - .5,
                                              (sy + (ey - sy) * fy) * 2048 - .5)
                    if not (0 <= px < self.width and 0 <= py < self.height):
                        if alpha > .01: clipped += 1
                        continue
                    pos = (py * self.width + px) * 4
                    for c, value in enumerate((233, 236, 243)):
                        self.canvas[pos + c] = round(value * alpha + self.canvas[pos + c] * (1 - alpha))
            x += advance * scale
        record = {'text': text, 'scale': scale, 'width': x - start,
                  'lineHeight': self.font['height'] * scale, 'clippedInkPixels': clipped}
        self.records.append(record)
        if clipped:
            raise ValueError('Proof glyphs clip outside the canvas')
        return record

    def save(self, path):
        png_write(path, self.width, self.height, self.canvas)


def proofs(work, output):
    output.mkdir(parents=True, exist_ok=True)
    required = json.loads((HOST / 'ranges.json').read_text())
    result = {'rendering': 'Production getChar metadata; bilinear texture alpha; upstream horizontal advance/bearings. Shaping and BiDi unchanged.',
              'sizeSources': ['Common/UI/Context.cpp: sizePts / 24', 'UI/Theme.cpp: 14,17,22,28 points',
                              'Core/Dialog/PSPMsgDialog.cpp: 0.65 and 0.6'], 'atlases': {}, 'proofs': {}}
    for atlas in ('font', 'ppge'):
        dump = json.loads((work / f'final-{atlas}.json').read_text())
        raw = (work / f'final-{atlas}.rgba').read_bytes()
        font = check_dump(dump, required[atlas], raw, atlas)
        result['atlases'][atlas] = {k: font[k] for k in ('name', 'height', 'ascend', 'padding', 'slope')}
        result['atlases'][atlas].update(validGlyphs=len(font['glyphs']), images=dump['images'], size=dump['size'])
        samples = SAMPLES + [('Symbols', '℡™' if atlas == 'font' else '℡™ № ∼∫√∞')]
        if atlas == 'font':
            for points in (14, 17, 22, 28):
                scale = points / 24
                row = math.ceil(font['height'] * scale) + 26
                proof = Proof(dump, raw, 640, 70 + row * len(samples))
                proof.text(f'UI atlas - {points} pt - actual pixels', 20, 12, .5)
                for i, (label, text) in enumerate(samples):
                    y = 60 + i * row
                    proof.text(label, 20, y, .30)
                    proof.text(text, 20, y + 18, scale)
                name = f'ui-{points}pt.png'; proof.save(output / name)
                result['proofs'][name] = proof.records
        else:
            for scale in (.6, .65):
                for page, start in enumerate((0, 6)):
                    proof = Proof(dump, raw, 480, 272)
                    proof.text(f'PSP dialog - scale {scale} - actual 480x272', 12, 8, .5)
                    for i, (label, text) in enumerate(samples[start:start + 6]):
                        y = 40 + i * 36
                        proof.text(label, 12, y, .28)
                        proof.text(text, 190 if len(text) < 12 else 12, y + 10, scale)
                    name = f'ppge-{scale}-page{page + 1}.png'; proof.save(output / name)
                    result['proofs'][name] = proof.records
            proof = Proof(dump, raw, 480, 120)
            for i, image in enumerate(dump['images']):
                _, rgba = icon_pixels(HOST / 'icons' / (image['name'] + '.png'))
                w, h = image['size']; x, y = 30 + i * 112, 55
                for yy in range(h):
                    pos = ((y + yy) * proof.width + x) * 4
                    proof.canvas[pos:pos + w * 4] = rgba[yy * w * 4:(yy + 1) * w * 4]
                proof.text(image['name'], x - 10, 10, .5)
            proof.save(output / 'psp-icons.png')
    (output / 'PROOF-METRICS.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('work', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    proofs(args.work, args.output)
