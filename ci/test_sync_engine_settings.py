"""Run the production sync setting store against the native configuration reader.

All settings and permission fixtures use a consumer-local temporary directory.
No native runtime, game, signing material or user configuration is involved.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


class SyncEngineSettingsTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc') and shutil.which('cc'), 'Swift and C compilers unavailable')
    def test_configuration_and_restart_state(self):
        with tempfile.TemporaryDirectory(prefix='iridium-sync-settings-') as temporary:
            directory = Path(temporary)
            native = directory / 'native-config'
            subprocess.run(['cc', '-x', 'c', '-', '-I', str(ROOT / 'testrepos/Madeira/build'),
                            '-o', str(native)], input=r'''
#include "madeira_cfg.h"
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2 || setenv("MADEIRA_DOCS_DIR", argv[1], 1)) return 1;
    if (argc == 2) printf("%d\n", madeira_cfg_sync_engine());
    else {
        char value[1024];
        size_t cap = argc > 3 ? (size_t)atoi(argv[3]) : sizeof value;
        if (!cap || cap > sizeof value || !madeira_cfg_get(argv[2], value, cap)) return 2;
        fwrite(value, 1, strlen(value), stdout);
    }
    return 0;
}
''', text=True, check=True, timeout=30)
            bridge = ''
            if sys.platform == 'darwin':
                # Compile the exact production late-export body, with only its
                # logging macro stubbed. It runs in a synthetic child process.
                source = (ROOT / 'testrepos/Madeira/app/Madeira/WineProcessBridge.m').read_text()
                start = source.index('/* ml1095: "env.NAME = value"')
                end = source.index('\n            }\n        }\n\n        // Steam S0', start)
                body = source[start:end]
                bridge = str(directory / 'bridge-config')
                subprocess.run(['cc', '-x', 'objective-c', '-fobjc-arc', '-framework', 'Foundation',
                                '-I', str(ROOT / 'testrepos/Madeira/build'), '-', '-o', bridge],
                               input='''#import <Foundation/Foundation.h>
#include "madeira_cfg.h"
#define LOG(...) ((void)0)
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2 || setenv("MADEIRA_DOCS_DIR", argv[1], 1)) return 1;
    unsetenv("MADEIRA_FASTSYNC");
    NSString *docs = [NSString stringWithUTF8String:argv[1]];
''' + body + '''
    const char *fast = getenv("MADEIRA_FASTSYNC");
    printf("%s", fast ? fast : "<unset>");
    return 0;
} }
''', text=True, check=True, timeout=30)
            binary = directory / 'sync-checks'
            subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                            '-module-cache-path', str(directory / 'module-cache'),
                            str(IOS / 'MadeiraSupport/MadeiraSyncEngine.swift'),
                            str(IOS / 'MadeiraSupportTests/SyncEngineCheck.swift'), '-o', str(binary)],
                           check=True, timeout=90)
            fixtures = directory / 'fixtures'
            fixtures.mkdir()
            subprocess.run([str(binary), str(native), str(fixtures.resolve()), bridge], check=True, timeout=45)


if __name__ == '__main__':
    unittest.main()
