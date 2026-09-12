#!/usr/bin/env python3
"""Link the app's actual static plugin selection before attempting the full app."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1]).resolve()
if not archive.is_file():
    raise SystemExit('Missing media archive')
plugins = re.findall(r'GST_PLUGIN_STATIC_REGISTER\((\w+)\)',
                     (ROOT / 'iridium/apps/ios/MediaSupport/MediaRuntime.c').read_text())
frameworks = re.findall(r'sdk: (\w+)\.framework',
                       (ROOT / 'iridium/apps/ios/madeira.yml').read_text())
versions = set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET: "([0-9.]+)"',
                         (ROOT / 'iridium/apps/ios/stikjit.yml').read_text()))
if not plugins or len(versions) != 1:
    raise SystemExit('Missing plugin selection or ambiguous deployment target')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='iridium-media-link-') as temp:
    work = Path(temp)
    code = '\n'.join('extern void gst_plugin_' + p + '_register(void);' for p in plugins)
    code += '\nint main(void) {\n'
    code += '\n'.join('gst_plugin_' + p + '_register();' for p in plugins)
    code += '\nreturn 0; }\n'
    (work / 'probe.c').write_text(code)
    command = ['xcrun', 'clang', '-target', 'arm64-apple-ios' + versions.pop(),
               '-isysroot', sdk, str(work / 'probe.c'), str(archive),
               '-lc++', '-lz', '-lsqlite3', '-liconv', '-lresolv', '-o', str(work / 'probe')]
    for name in dict.fromkeys(frameworks + ['Foundation']):
        command += ['-framework', name]
    subprocess.run(command, check=True)
print(f'Linked {len(plugins)} selected media plugins. Device playback is not tested.')
