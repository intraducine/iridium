import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import ROOT, load

windows = load('windows_stage', 'stage-windows-runtime.py')
prefixes = load('prefix_stage', 'sanitize-prefix.py')
debian = load('debian_sources', 'collect-debian-sources.py')


class RuntimeStagingTests(unittest.TestCase):
    def test_debian_owner_ignores_diversions_and_rejects_ambiguity(self):
        path = '/lib64/ld-linux-x86-64.so.2'
        output = (f'diversion by libc6 from: {path}\n'
                  'diversion by libc6 to: /lib64/ld-linux-x86-64.so.2.usr-is-merged\n'
                  f'libc6:amd64: {path}\n')
        self.assertEqual(debian.package_owner(output, path), 'libc6:amd64')
        self.assertIsNone(debian.package_owner(output, '/unowned'))
        self.assertIsNone(debian.package_owner(f'diversion by libc6 from: {path}', path))
        with self.assertRaises(ValueError):
            debian.package_owner(output + f'other:amd64: {path}\n', path)

    def test_pe_machine_check(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'module.dll'
            header = bytearray(64)
            header[:2] = b'MZ'
            struct.pack_into('<I', header, 60, 64)
            for machine, arch in [(0xaa64, 'aarch64'), (0x8664, 'arm64ec')]:
                path.write_bytes(header + b'PE\0\0' + struct.pack('<H', machine))
                windows.check_pe(path, arch)
                with self.assertRaises(ValueError):
                    windows.check_pe(path, 'aarch64' if arch == 'arm64ec' else 'arm64ec')
            path.write_bytes(b'MZ')
            with self.assertRaises(ValueError):
                windows.check_pe(path, 'arm64ec')

    def test_prefix_never_follows_host_links_and_requires_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            prefix = root / 'prefix'
            user = prefix / 'drive_c/users/BuildUser'
            user.mkdir(parents=True)
            outside = root / 'keep.txt'
            outside.write_text('keep')
            (user / 'Desktop').symlink_to(outside)
            for name in ['system.reg', 'user.reg', 'userdef.reg']:
                (prefix / name).write_text('"User"="BuildUser"\n"ComputerName"="BuildHost"\n"Font"="Z:\\\\Users\\\\BuildUser\\\\font"\n')
            with self.assertRaises(ValueError):
                prefixes.sanitize(prefix, 'BuildUser', 'BuildHost')
            (root / '.iridium-prefix-build').touch()
            prefixes.sanitize(prefix, 'BuildUser', 'BuildHost')
            self.assertEqual(outside.read_text(), 'keep')
            self.assertFalse((prefix / 'drive_c/users/madeira/Desktop').exists())
            self.assertEqual((prefix / 'system.reg').read_text(), '"User"="madeira"\n"ComputerName"="iridium"\n')

    def test_debian_unknown_library_is_not_silently_redistributed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            installed = root / 'install/lib/example.so'
            installed.parent.mkdir(parents=True)
            installed.write_bytes(b'library')
            system = root / 'system'
            (system / 'lib').mkdir(parents=True)
            (system / 'lib/example.so').write_bytes(b'library')
            with patch.object(debian.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'not owned')):
                with self.assertRaisesRegex(ValueError, 'Debian owner'):
                    debian.collect(root / 'install', root / 'out', system)
            self.assertFalse((root / 'out/debian-runtime.json').exists())


if __name__ == '__main__':
    unittest.main()
