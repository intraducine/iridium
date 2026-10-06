#!/usr/bin/env python3
"""Exercise the compiled Steam C ABI. --network uses QR/cancel without logging in."""
import argparse
import ctypes
import json
from pathlib import Path
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--network', action='store_true')
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.library.resolve(strict=True)))
    for name in ('initialize', 'submit', 'complete_chunk_batch'):
        function = getattr(library, 'iridium_steam_' + name)
        function.argtypes = [ctypes.c_char_p]
        function.restype = ctypes.c_int
    for name in ('snapshot', 'take_session', 'take_chunk_batch'):
        function = getattr(library, 'iridium_steam_' + name)
        function.argtypes = []
        function.restype = ctypes.c_void_p
    library.iridium_steam_free.argtypes = [ctypes.c_void_p]
    library.iridium_steam_free.restype = None
    library.iridium_steam_set_chunk_runtime.argtypes = [ctypes.c_int]
    library.iridium_steam_set_chunk_runtime.restype = None
    capacity_type = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32))
    library.iridium_steam_set_capacity_provider.argtypes = [ctypes.c_void_p]
    library.iridium_steam_set_capacity_provider.restype = ctypes.c_int

    # Retain the host callback for the entire native runtime lifetime.
    @capacity_type
    def capacity(directory, source):
        source[0] = 1
        return 1024 * 1024 * 1024


    def read(name='snapshot'):
        pointer = getattr(library, 'iridium_steam_' + name)()
        if not pointer:
            return None
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            library.iridium_steam_free(pointer)

    def send(action):
        return library.iridium_steam_submit(json.dumps({'action': action}).encode())

    with tempfile.TemporaryDirectory(prefix='iridium-steam-abi-') as directory:
        assert read('take_chunk_batch') is None
        assert library.iridium_steam_complete_chunk_batch(None) == 0
        library.iridium_steam_set_chunk_runtime(0)
        assert library.iridium_steam_set_capacity_provider(None) == 0
        assert library.iridium_steam_set_capacity_provider(capacity) == 1
        assert library.iridium_steam_initialize(directory.encode()) == 1
        assert library.iridium_steam_set_capacity_provider(capacity) == 0
        assert library.iridium_steam_initialize(directory.encode()) == 1
        assert read()['phase'] == 'signedOut'
        assert read('take_session') is None
        assert read('take_chunk_batch') is None
        assert library.iridium_steam_complete_chunk_batch(b'{invalid') == 0
        assert library.iridium_steam_complete_chunk_batch(b'{' + b' ' * 1024 + b'}') == 0
        assert library.iridium_steam_complete_chunk_batch(json.dumps({
            'operationId': '00000000-0000-0000-0000-000000000001',
            'batchId': '00000000-0000-0000-0000-000000000002', 'code': 'ok',
        }).encode()) == 0
        library.iridium_steam_set_chunk_runtime(0)
        library.iridium_steam_set_chunk_runtime(1)
        assert library.iridium_steam_submit(b'{invalid') == 0
        assert send('install') == 0
        assert send('cloud') == 0
        assert send('unknown') == 0
        if args.network:
            assert send('qr') == 1
            try:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    state = read()
                    assert 'refreshToken' not in state
                    if state['phase'] == 'qr' and state['challengeUrl']:
                        break
                    assert state['busy'], 'Steam QR request ended before returning a challenge'
                    time.sleep(0.2)
                else:
                    raise AssertionError('Steam QR challenge timed out')
            finally:
                assert send('cancel') == 1
                deadline = time.monotonic() + 15
                while read()['busy'] and time.monotonic() < deadline:
                    time.sleep(0.1)
            assert not read()['busy'] and not read()['signedIn']
            assert read('take_session') is None
        assert send('signOut') == 1
        assert read()['phase'] == 'signedOut'
    print('PASS: native Steam C ABI' + (' and live QR challenge/cancel' if args.network else ''))


if __name__ == '__main__':
    main()
