"""Exercise the registry and file migration used before wineserver starts."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'testrepos/Madeira/app/Madeira/WineProcessBridge.m'


class WineProfileRepairTests(unittest.TestCase):
    def test_mobile_paths_and_colliding_saves(self):
        source = SOURCE.read_text()
        functions = source[source.index('static int ios_reg_replace('):
                           source.index('static void madeira_repair_profile(')]
        program = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#define LOG(...) ((void)0)
''' + functions + r'''
int main(int argc, char **argv)
{
    if (argc != 8) return 1;
    if (ios_reg_replace(argv[1], "users\\\\mobile", "users\\\\madeira") != 1) return 2;
    ios_merge_move(argv[2], argv[3], 12);
    ios_merge_move(argv[4], argv[5], 12);
    ios_merge_move(argv[6], argv[7], 12);
    if (ios_reg_replace(argv[1], "users\\\\mobile", "users\\\\madeira") != 0) return 3;
    if (ios_reg_replace(argv[7], "users\\\\mobile", "users\\\\madeira") != 0) return 4;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            registry = root / 'user.reg'
            registry.write_text(r'"AppData"="C:\\users\\mobile\\AppData"' + '\n'
                                + r'"Unrelated"="C:\\games\\mobile"' + '\n')
            mobile, madeira = root / 'mobile', root / 'madeira'
            mobile.mkdir()
            madeira.mkdir()
            (mobile / 'existing.sav').write_bytes(b'old save')
            (madeira / 'existing.sav').write_bytes(b'new save')
            (mobile / 'unique.sav').write_bytes(b'unique save')
            unsafe, outside = root / 'unsafe', root / 'outside'
            unsafe.mkdir()
            outside.mkdir()
            (unsafe / 'private.sav').write_bytes(b'private save')
            link = root / 'linked'
            link.symlink_to(outside, target_is_directory=True)
            source_link = root / 'source-linked'
            source_link.symlink_to(unsafe, target_is_directory=True)
            empty_dest = root / 'empty-dest'
            exe = root / 'check'
            subprocess.run(['cc', '-x', 'c', '-', '-o', str(exe)], input=program,
                           text=True, check=True)
            subprocess.run([str(exe), str(registry), str(mobile), str(madeira),
                            str(unsafe), str(link), str(source_link), str(empty_dest)], check=True)
            self.assertIn(r'C:\\users\\madeira\\AppData', registry.read_text())
            self.assertNotIn(r'users\\mobile', registry.read_text())
            self.assertEqual((madeira / 'existing.sav').read_bytes(), b'new save')
            self.assertEqual((mobile / 'existing.sav').read_bytes(), b'old save')
            self.assertEqual((madeira / 'unique.sav').read_bytes(), b'unique save')
            self.assertEqual((unsafe / 'private.sav').read_bytes(), b'private save')
            self.assertEqual(list(outside.iterdir()), [])
            self.assertFalse(empty_dest.exists())


if __name__ == '__main__':
    unittest.main()
