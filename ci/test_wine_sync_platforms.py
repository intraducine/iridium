"""Keep Apple's scheduler and timing code out of the Linux prefix producer."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WineSyncPlatformsTests(unittest.TestCase):
    def test_platform_preprocessing(self):
        source = (ROOT / 'testrepos/Madeira/wine/dlls/ntdll/unix/sync.c').read_text()
        # Exercise the real platform guards without requiring both platform SDKs.
        source = re.sub(r'^\s*#\s*include[^\n]*', '', source, flags=re.MULTILINE)
        compiler = shutil.which('cc')
        self.assertIsNotNone(compiler, 'A C compiler is required')
        for platform in ('__linux__', '__APPLE__'):
            result = subprocess.run([compiler, '-E', '-P', '-x', 'c', '-U__APPLE__',
                                     '-U__linux__', '-D' + platform, '-'], input=source,
                                    text=True, capture_output=True, check=True).stdout
            for symbol in ('qos_class_t', 'pthread_set_qos_class_self_np',
                           'mach_absolute_time', 'mach_timebase_info'):
                if platform == '__linux__':
                    self.assertNotIn(symbol, result)
                else:
                    self.assertIn(symbol, result)
            self.assertIn('NtWaitForAlertByThreadId', result)
            self.assertIn('futex_wait', result)

    def test_windows_timer_architectures(self):
        source = (ROOT / 'testrepos/Madeira/wine/dlls/ntdll/sync.c').read_text()
        source = source[source.index('static inline ULONGLONG ios_xp_ticks'):source.index('static void ios_xp_cs_waited')]
        compiler = shutil.which('cc')
        self.assertIsNotNone(compiler, 'A C compiler is required')
        for arch in ('__x86_64__', '__aarch64__', '__arm64ec__'):
            result = subprocess.run([compiler, '-E', '-P', '-x', 'c',
                                     '-U__aarch64__', '-U__arm64ec__', '-U__x86_64__',
                                     '-D' + arch, '-'], input=source, text=True,
                                    capture_output=True, check=True).stdout
            if arch == '__x86_64__':
                self.assertNotIn('cntvct_el0', result)
                self.assertNotIn('cntfrq_el0', result)
                self.assertIn('NtQueryPerformanceCounter( &counter, &frequency )', result)
            else:
                self.assertIn('cntvct_el0', result)
                self.assertIn('cntfrq_el0', result)
                self.assertNotIn('NtQueryPerformanceCounter', result)


if __name__ == '__main__':
    unittest.main()
