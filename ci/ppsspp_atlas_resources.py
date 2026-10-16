"""Locked native PSP atlas resources and generation helpers (no engine overlay)."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'ci/psp-atlas-host'
RESOURCE_ROOT = ROOT / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases'
MANIFEST = ROOT / 'ci/psp-atlas-resources.json'
FONT_LOCK = ROOT / 'ci/psp-atlas-inputs.json'
REVISION = 'fa50bb1976065c4f8b1b47af227d367fe9771555'
FILES = tuple(a + '_atlas.' + ext for a in ('font', 'ppge') for ext in ('meta', 'zim'))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def font_cache(root=ROOT):
    return root / '.build/psp-atlas-fonts'


def input_path(item, source, root=ROOT):
    return source / item['source'].removeprefix('PPSSPP/') if 'source' in item else font_cache(root) / item['file']


def locked_inputs(source, root=ROOT):
    lock = json.loads((root / 'ci/psp-atlas-inputs.json').read_text())
    for item in lock['inputs']:
        path = input_path(item, source, root)
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Missing or changed licensed font input: ' + item['file'])
    return lock


def replacement_plan(origin, root=ROOT):
    receipt = json.loads((root / 'ci/psp-atlas-resources.json').read_text())
    if receipt['revision'] != REVISION or set(receipt['resources']) != set(FILES):
        raise ValueError('Licensed atlas resource inventory differs')
    if receipt['fontInputs'] != json.loads((root / 'ci/psp-atlas-inputs.json').read_text()):
        raise ValueError('Licensed atlas font manifest differs')
    result = {}
    for name, record in receipt['resources'].items():
        original = origin / name
        replacement = root / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases' / name
        # Corresponding source omits these superseded bitmap inputs. The owned
        # replacement set is complete regardless of whether old bytes exist.
        if original.is_symlink() or (original.exists() and digest(original) != record['originalSHA256']):
            raise ValueError('Upstream atlas changed: ' + name)
        if replacement.is_symlink() or not replacement.is_file() or digest(replacement) != record['sha256']:
            raise ValueError('Licensed atlas changed: ' + name)
        result[name] = replacement
    return result


def collect_inputs(stage, component, root=ROOT):
    """Supply exact generation inputs and omit only reviewed superseded atlases."""
    selected = component.get('licensedAtlases')
    if selected is None:
        return {'inputs': [], 'exclusions': []}  # Preserve older personal builds.
    current = json.loads((root / 'ci/psp-atlas-resources.json').read_text())
    if selected != current:
        raise ValueError('Linked licensed atlas receipt differs from source')
    lock = locked_inputs(root / 'vendor/PPSSPP', root)
    if lock != selected['fontInputs']:
        raise ValueError('Linked atlas generation inputs differ')
    deletions = []
    for name in FILES:
        record = selected['resources'][name]
        original = stage / 'vendor/PPSSPP/assets' / name
        replacement = stage / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases' / name
        if (not original.is_file() or original.is_symlink() or digest(original) != record['originalSHA256']
                or replacement.is_symlink() or not replacement.is_file() or digest(replacement) != record['sha256']):
            raise ValueError('Unreviewed corresponding-source atlas exclusion: ' + name)
        deletions.append((original, {'path': original.relative_to(stage).as_posix(),
                                    'sha256': record['originalSHA256'],
                                    'replacement': replacement.relative_to(stage).as_posix(),
                                    'replacementSHA256': record['sha256'],
                                    'reason': 'Superseded upstream font atlas; generated from locked OFL inputs.'}))
    for item in lock['inputs']:
        target = font_cache(stage) / item['file']; target.parent.mkdir(parents=True, exist_ok=True)
        import shutil
        shutil.copy2(input_path(item, root / 'vendor/PPSSPP', root), target)
    for original, record in deletions:
        original.unlink()
    return {'inputs': lock['inputs'], 'exclusions': [r for _, r in deletions]}


def tool_source(upstream, ranges):
    """Only input ranges and undefined missing-record initialization are adapted."""
    anchor = 'void GetLocales(const char *locales, std::vector<CharRange> &ranges)\n{'
    if upstream.count(anchor) != 1 or upstream.count('Data dat;') != 2:
        raise ValueError('Pinned upstream host atlas tool changed')
    branches = []
    for atlas, flag in (('font', 'A'), ('ppge', 'P')):
        definition = ranges[atlas]
        lines = []
        for first, last in definition['ranges']:
            selected = [cp for cp in definition['requiredCodepoints'] if first <= cp < last]
            # Upstream treats an empty filter as unrestricted. 0xffff is outside
            # these intentionally empty historical ranges.
            selected = selected or [65535]
            values = ','.join(map(str, selected))
            lines.append(f'ranges.push_back(range({first}, {last - 1}, std::set<u16>{{{values}}}));')
        branches.append(f'if (!strcmp(locales, "{flag}")) {{\n' + '\n'.join(lines) + '\nreturn;\n}')
    result = upstream.replace(anchor, anchor + '\n' + '\n'.join(branches), 1)
    result = result.replace('Data dat;', 'Data dat{};')
    anchor = 'std::vector<Data> results = bucket.Resolve(&dest);'
    if result.count(anchor) != 1:
        raise ValueError('Pinned upstream rasterizer output hook changed')
    # Compare serialization to the actual in-memory rasterizer output, without
    # depending on the diagnostic PNG encoder/decoder's platform optimizations.
    capture = '''
    FILE *raw_pixels = fopen((out_prefix + "-rasterizer.rgba").c_str(), "wb");
    if (!raw_pixels) return 1;
    size_t pixel_count = (size_t)dest.width() * dest.height();
    if (fwrite(dest.dat.data(), 4, pixel_count, raw_pixels) != pixel_count) return 1;
    if (fclose(raw_pixels) != 0) return 1;
'''
    return result.replace(anchor, anchor + capture, 1)


def png_write(path, width, height, rgba):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    rows = b''.join(b'\0' + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def icon_pixels(path):
    """Decode our small, checked RGBA PNGs; reject unsupported filters/encodings."""
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Invalid source icon')
    offset = 8
    compressed = bytearray()
    size = None
    while offset < len(data):
        length, = struct.unpack_from('>I', data, offset)
        tag = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        crc, = struct.unpack_from('>I', data, offset + 8 + length)
        if zlib.crc32(tag + body) != crc:
            raise ValueError('Source icon checksum differs')
        if tag == b'IHDR':
            w, h, depth, color, compression, filtering, interlace = struct.unpack('>2I5B', body)
            if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError('Unsupported source icon encoding')
            size = w, h
        elif tag == b'IDAT':
            compressed.extend(body)
        offset += length + 12
    w, h = size
    rows = zlib.decompress(compressed)
    if len(rows) != h * (w * 4 + 1) or any(rows[y * (w * 4 + 1)] for y in range(h)):
        raise ValueError('Unsupported source icon filters')
    return size, b''.join(rows[y * (w * 4 + 1) + 1:(y + 1) * (w * 4 + 1)] for y in range(h))


def verify_quantization(png_rgba, zim_rgba, width, height, format):
    """Check every serialized pixel against upstream's scalar ordered dither."""
    if len(png_rgba) != width * height * 4 or len(zim_rgba) != len(png_rgba):
        raise ValueError('Generated pixel inventory differs')
    if format == 0:
        if png_rgba != zim_rgba:
            raise ValueError('RGBA8888 texture differs from rasterizer pixels')
        return width * height
    if format != 1:
        raise ValueError('Unexpected generated texture format')
    dither = (1, 9, 3, 11, 13, 5, 15, 7, 4, 12, 2, 10, 16, 8, 14, 6)
    for y in range(height):
        for x in range(width):
            pos = (y * width + x) * 4
            bias = dither[(x & 3) + ((y & 3) << 2)] - 8
            for channel in range(4):
                expected = max(0, min(15, (png_rgba[pos + channel] + bias) >> 4)) * 17
                if zim_rgba[pos + channel] != expected:
                    raise ValueError('Host ZIM conversion differs from scalar reference')
    return width * height


def finish_atlas(prefix, atlas, dump):
    """Preserve the GE power-of-two canvas, icon texels and horizontal line cells."""
    from compression import zstd  # Regeneration uses Python 3.14; packaging does not.
    texture = prefix.with_name(prefix.name + '_atlas.zim')
    metadata = prefix.with_name(prefix.name + '_atlas.meta')
    header = texture.read_bytes()[:16]
    magic, width, height, flags = struct.unpack('<4s3I', header)
    if magic != b'ZIMG' or flags & 16 or not flags & 4096:
        raise ValueError('Unexpected generated ZIM layout')
    padded = 1 << (height - 1).bit_length()
    if width != 2048 or padded > 4096:
        raise ValueError('Generated atlas exceeds texture budget')
    pixel_size = 4 if flags & 15 == 0 else 2
    pixels = bytearray(zstd.decompress(texture.read_bytes()[16:]))
    if len(pixels) != width * height * pixel_size:
        raise ValueError('Generated texture byte size differs')
    pixels.extend(bytes(width * (padded - height) * pixel_size))
    if atlas == 'ppge':
        icons = json.loads((HOST / 'icons.json').read_text())['images']
        if {i['name'] for i in dump['images']} != {i['name'] for i in icons}:
            raise ValueError('PSP image IDs changed')
        for icon in icons:
            image = next(i for i in dump['images'] if i['name'] == icon['name'])
            path = HOST / 'icons' / icon['file']
            size, rgba = icon_pixels(path)
            if list(size) != image['size'] or digest(path) != icon['pngSHA256']:
                raise ValueError('PSP source icon changed')
            sx = round(image['uv'][0] * width - .5)
            sy = round(image['uv'][1] * height - .5)
            w, h = size
            for y in range(h):
                for x in range(w):
                    r, g, b, a = rgba[(y * w + x) * 4:(y * w + x + 1) * 4]
                    if any(v % 17 for v in (r, g, b, a)):
                        raise ValueError('Icon cannot be preserved in RGBA4444')
                    struct.pack_into('<H', pixels, ((sy + y) * width + sx + x) * 2,
                                     (r // 17 << 12) | (g // 17 << 8) | (b // 17 << 4) | (a // 17))
    texture.write_bytes(struct.pack('<4s3I', magic, width, padded, flags) + zstd.compress(pixels, level=22))
    data = metadata.read_bytes()
    magic, version, nfonts, nimages = struct.unpack_from('<4I', data)
    if version != 1 or nfonts != 1:
        raise ValueError('Unexpected generated atlas metadata')
    offset = 16
    def block():
        nonlocal offset
        n, = struct.unpack_from('<I', data, offset)
        offset += 4
        raw = bytearray(zstd.decompress(data[offset:offset + n]))
        offset += n
        return raw
    def packed(raw):
        compressed = zstd.compress(raw, level=22)
        return struct.pack('<I', len(compressed)) + compressed
    images = block()
    for i in range(nimages):
        u1, v1, u2, v2 = struct.unpack_from('<4f', images, i * 56)
        struct.pack_into('<4f', images, i * 56, u1, v1 * height / padded, u2, v2 * height / padded)
    fheader = bytearray(data[offset:offset + 56]); offset += 56
    padding, line_height, ascend, slope, nranges, nchars = struct.unpack_from('<4f2I', fheader)
    ranges = block(); chars = block()
    if offset != len(data):
        raise ValueError('Trailing generated atlas metadata')
    for i in range(nchars):
        sx, sy, ex, ey = struct.unpack_from('<4f', chars, i * 32)
        struct.pack_into('<4f', chars, i * 32, sx, sy * height / padded, ex, ey * height / padded)
    # Source Han's vertical repeat forms span two ems. The existing frontend is
    # horizontal, with one cell per character. Preserve advance and full texture
    # sampling, fitting these two quads to the prior one-cell layout.
    for i in range(nranges):
        first, last, index = struct.unpack_from('<3I', ranges, i * 12)
        for cp in (0x3031, 0x3032):
            if first <= cp < last:
                pos = (index + cp - first) * 32
                ph, = struct.unpack_from('<H', chars, pos + 30)
                struct.pack_into('<H', chars, pos + 30, (ph + 1) // 2)
                struct.pack_into('<f', chars, pos + 20, -28.25 if atlas == 'font' else -21.5)
    valid = [struct.unpack_from('<7f2H', chars, i * 32) for i in range(nchars)]
    valid = [c for c in valid if c[2] or c[3]]
    new_ascend = max(-c[5] for c in valid)
    new_height = new_ascend + max(c[8] + c[5] for c in valid)
    struct.pack_into('<3f', fheader, 0, padding + line_height - new_height, new_height, new_ascend)
    metadata.write_bytes(data[:16] + packed(images) + fheader + packed(ranges) + packed(chars))
