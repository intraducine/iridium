"""Extract complete MP4 box sequences from a local Unity resource, without editing it."""
import pathlib
import struct
import sys

def clips(data):
    cursor = 0
    while True:
        found = data.find(b"ftyp", cursor)
        if found < 0:
            return
        cursor = found + 4
        start = found - 4
        if start < 0:
            continue
        pos, types = start, set()
        while pos + 8 <= len(data):
            size, kind = struct.unpack_from(">I4s", data, pos)
            if kind not in {b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide", b"uuid"}:
                break
            header = 8
            if size == 1:
                if pos + 16 > len(data):
                    break
                size = struct.unpack_from(">Q", data, pos + 8)[0]
                header = 16
            if size < header or size > len(data) - pos:
                break
            types.add(kind)
            pos += size
        if {b"ftyp", b"moov", b"mdat"} <= types:
            yield start, data[start:pos]
            cursor = pos

if __name__ == "__main__":
    def box(kind, content=b""):
        return struct.pack(">I4s", len(content) + 8, kind) + content
    sample = box(b"ftyp", b"isom") + box(b"moov") + box(b"mdat", b"test")
    assert list(clips(b"junk" + sample)) == [(4, sample)]
    assert not list(clips(sample[:-1]))
    if len(sys.argv) == 3:
        target = pathlib.Path(sys.argv[2]); target.mkdir(parents=True, exist_ok=True)
        for offset, data in clips(pathlib.Path(sys.argv[1]).read_bytes()):
            path = target / f"clip-{offset}.mp4"
            path.write_bytes(data)
            print(path, len(data))
