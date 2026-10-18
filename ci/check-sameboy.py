#!/usr/bin/env python3
"""Execute the real statically linked core with an original synthetic cartridge."""
import ctypes as c
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def cartridge(fixed_palette=False):
    # Original test code only. No commercial ROM, firmware or Nintendo logo.
    # Battery marker and polled joypad register expose actual CPU/input behavior.
    data = bytearray(32768)
    data[0x100:0x103] = bytes([0xc3, 0x50, 1])
    data[0x134:0x13a] = b'IRTEST'
    data[0x147] = 0x10  # MBC3, RAM, battery, RTC
    data[0x149] = 2
    program = bytearray([0xf3, 0x31, 0xfe, 0xff, 0x3e, 0x0a, 0xea, 0, 0,
                         0x3e, 0x42, 0xea, 0, 0xa0])
    def register(address, value):
        program.extend([0x3e, value, 0xe0, address])
    register(0x40, 0)  # LCD off while defining an original test tile.
    program.extend([0x21, 0, 0x80, 0x06, 8, 0x3e, 0xaa, 0x22, 0xaf, 0x22, 0x3e, 0xaa, 0x05, 0x20, 0xf8])
    register(0x47, 0xe4)
    register(0x40, 0x91)
    for address, value in [(0x26, 0x80), (0x24, 0x77), (0x25, 0xff),
                           (0x11, 0x80), (0x12, 0xf0), (0x13, 0x50), (0x14, 0x87)]:
        register(address, value)
    register(0, 0x10)  # Select joypad buttons.
    loop = 0x150 + len(program)
    # Store actual input and make it visibly change the palette.
    program.extend([0xf0, 0, 0xea, 1, 0xa0])
    if not fixed_palette: program.extend([0xe0, 0x47])
    program.extend([0xc3, loop & 255, loop >> 8])
    data[0x150:0x150 + len(program)] = program
    data[0x14d] = (-sum(data[0x134:0x14d]) - 25) & 255
    return data


class Frame(c.Structure):
    _fields_ = [('pixels', c.POINTER(c.c_uint32)), ('width', c.c_uint), ('height', c.c_uint),
                ('audio', c.POINTER(c.c_int16)), ('audio_frames', c.c_size_t), ('fps', c.c_double),
                ('rate', c.c_double), ('input_polled', c.c_bool)]


def check(library):
    lib = c.CDLL(str(library))
    lib.ir_core_open.argtypes = [c.c_void_p, c.c_size_t, c.c_char_p]
    lib.ir_core_open.restype = c.c_bool
    lib.ir_core_step.argtypes = [c.c_uint16, c.POINTER(Frame)]
    lib.ir_core_step.restype = c.c_bool
    lib.ir_core_save_size.argtypes = [c.c_bool]
    lib.ir_core_save_size.restype = c.c_size_t
    for name in ['read', 'write']:
        fn = getattr(lib, 'ir_core_' + name + '_save')
        fn.argtypes = [c.c_bool, c.c_void_p, c.c_size_t]
        fn.restype = c.c_bool
    rom = cartridge()
    buffer = (c.c_uint8 * len(rom)).from_buffer_copy(rom)
    frame = Frame()
    assert not lib.ir_core_open(None, 0, b'/unused')
    assert not lib.ir_core_step(0, c.byref(frame))
    saved = None
    with tempfile.TemporaryDirectory() as folder:
        for cycle in range(3):
            rom[0x143] = 0x80 if cycle == 1 else 0
            rom[0x14d] = (-sum(rom[0x134:0x14d]) - 25) & 255
            buffer = (c.c_uint8 * len(rom)).from_buffer_copy(rom)
            assert lib.ir_core_open(buffer, len(rom), folder.encode())
            assert not lib.ir_core_open(buffer, len(rom), folder.encode())
            if saved is not None:
                payload = (c.c_uint8 * len(saved)).from_buffer_copy(saved)
                assert lib.ir_core_write_save(False, payload, len(saved))
                restored = (c.c_uint8 * len(saved))()
                assert lib.ir_core_read_save(False, restored, len(saved))
                assert bytes(restored) == saved
            audio = 0
            for _ in range(250):
                assert lib.ir_core_step(0, c.byref(frame))
                assert frame.width == 160 and frame.height == 144
                assert 59 < frame.fps < 61 and frame.rate == 96000
                assert 0 < frame.audio_frames < 2000
                audio += frame.audio_frames
            expected = 250 * frame.rate / frame.fps
            assert expected * 0.98 < audio < expected * 1.02
            size = lib.ir_core_save_size(False)
            assert size == 8192
            data = (c.c_uint8 * size)()
            assert lib.ir_core_read_save(False, data, size)
            assert data[0] == 0x42 and data[1] & 1
            marker = b'IRIDIUM-SAVE-TEST'
            if saved is not None:
                assert bytes(data)[512:512 + len(marker)] == marker
            assert not lib.ir_core_write_save(False, data, size - 1)
            assert lib.ir_core_step(1 << 8, c.byref(frame))
            assert lib.ir_core_read_save(False, data, size) and not data[1] & 1
            assert lib.ir_core_step(0, c.byref(frame))
            assert lib.ir_core_read_save(False, data, size) and data[1] & 1
            assert any(frame.audio[i] for i in range(frame.audio_frames * 2))
            if cycle != 1:  # DMG palette affects pixels; CGB has its own palettes.
                before = c.string_at(frame.pixels, frame.width * frame.height * 4)
                for _ in range(3): assert lib.ir_core_step(1 << 8, c.byref(frame))
                after = c.string_at(frame.pixels, frame.width * frame.height * 4)
                assert before != after
            for i, byte in enumerate(marker): data[512 + i] = byte
            assert lib.ir_core_write_save(False, data, size)
            saved = bytes(data)
            clock_size = lib.ir_core_save_size(True)
            assert 0 < clock_size < 1024
            clock = (c.c_uint8 * clock_size)()
            assert lib.ir_core_read_save(True, clock, clock_size)
            assert lib.ir_core_write_save(True, clock, clock_size)
            lib.ir_core_close(); lib.ir_core_close()
            assert not lib.ir_core_step(0, c.byref(frame))
    # Ordinary DMG cartridges must receive CGB boot colorization, not a tint
    # painted over grayscale frames by the frontend.
    rom = cartridge(fixed_palette=True)
    buffer = (c.c_uint8 * len(rom)).from_buffer_copy(rom)
    assert lib.ir_core_open(buffer, len(rom), folder.encode())
    for _ in range(250): assert lib.ir_core_step(0, c.byref(frame))
    colors = {int(frame.pixels[i]) & 0xffffff for i in range(frame.width * frame.height)}
    assert len(colors) > 1
    assert any(len({v >> 16, (v >> 8) & 255, v & 255}) > 1 for v in colors), colors
    assert lib.ir_core_audio_dropped_frames() == 0
    print('DMG compatibility colors:', [hex(v) for v in sorted(colors)])
    lib.ir_core_close()
    # Upstream 1.0.4 no longer exposes RTC memory for cartridges without an RTC.
    rom[0x147] = 3  # MBC1 RAM/battery, no clock
    rom[0x146] = 3  # SGB-capable header selects standalone iOS's SGB2 model
    rom[0x14d] = (-sum(rom[0x134:0x14d]) - 25) & 255
    buffer = (c.c_uint8 * len(rom)).from_buffer_copy(rom)
    assert lib.ir_core_open(buffer, len(rom), folder.encode())
    assert lib.ir_core_save_size(True) == 0
    for _ in range(250): assert lib.ir_core_step(0, c.byref(frame))
    assert frame.width == 160 and frame.height == 144 and frame.rate == 96000
    assert 59 < frame.fps < 62
    lib.ir_core_close()
    print('Real SameBoy: five lifecycles, 1250 frames, DMG CGB-boot colorization, CGB/SGB2, 96 kHz audio, input, SRAM, RTC and no-RTC passed')


def main():
    spec = importlib.util.spec_from_file_location('sameboy_build', ROOT / 'ci/build-sameboy.py')
    build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)
    out = ROOT / '.build/sameboy-check'
    archive = build.build(out)
    library = out / ('core.dylib' if sys.platform == 'darwin' else 'core.so')
    command = ['cc', '-std=c11', '-O2', '-fPIC', '-shared', '-I' + str(out),
               '-I' + str(ROOT / 'vendor/SameBoy/libretro'),
               str(ROOT / 'iridium/apps/ios/RuntimeBridge/IridiumCoreBridge.c'), str(archive), '-lm']
    if sys.platform == 'darwin': command += ['-framework', 'CoreFoundation']
    subprocess.run(command + ['-o', str(library)], check=True)
    check(library)


if __name__ == '__main__':
    main()
