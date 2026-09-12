"""Check the desktop/iOS boundary without configuring all of Wine."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WineIOSHooksTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "C preprocessor required")
    def test_bitmap_hooks_only_exist_in_ios_build(self):
        source = (ROOT / "testrepos/Madeira/wine/dlls/win32u/dibdrv/bitblt.c").read_text()
        # Headers need a configured Wine tree; retain all source conditionals.
        source = "\n".join(line for line in source.splitlines()
                           if not line.lstrip().startswith("#include"))
        hooks = ("winios_dump_srcbits", "ios_srcwatch_arm_geom", "ios_srcwatch_arm")
        for ios in (False, True):
            command = ["cc", "-E", "-P", "-x", "c", "-"]
            if ios:
                command.insert(1, "-DWINE_IOS=1")
            result = subprocess.run(command, input=source, text=True,
                                    capture_output=True, check=True).stdout
            for hook in hooks:
                self.assertEqual(hook in result, ios, hook)

    @unittest.skipUnless(shutil.which("cc"), "C preprocessor required")
    def test_loader_jit_alias_calls_only_exist_in_arm64ec_build(self):
        source = (ROOT / "testrepos/Madeira/wine/dlls/ntdll/loader.c").read_text()
        source = "\n".join(line for line in source.splitlines()
                           if not line.lstrip().startswith("#include"))
        for arch in ("__aarch64__", "__x86_64__", "__i386__", "__arm64ec__"):
            result = subprocess.run(
                ["cc", "-E", "-P", "-undef", "-D" + arch, "-x", "c", "-"],
                input=source, text=True, capture_output=True, check=True).stdout
            for hook in ("xlate_ios_jit", "iat_life_sweep"):
                self.assertEqual(hook in result, arch == "__arm64ec__", (arch, hook))
