"""Build an isolated iOS MF reader variant; never edit Madeira's Wine source."""
from pathlib import Path
import os
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
madeira = root.parent.parent.parent / 'testrepos/Madeira'
pe = Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/wine-media'
source = madeira / 'wine/dlls/mfreadwrite/reader.c'
out = root / '.build/media/reader_media.c'
env = dict(os.environ)
env['PATH'] = str(madeira / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin') + ':' + env['PATH']
obj = 'dlls/mfreadwrite/arm64ec-windows/reader.o'
dll = 'dlls/mfreadwrite/arm64ec-windows/mfreadwrite.dll'
subprocess.run(['make', '-j' + env.get('JOBS', '2'), dll], cwd=pe, env=env, check=True)
s = source.read_text()
start = s.index('static HRESULT source_reader_create_sample_allocator_attributes(')
end = s.index('\nstatic HRESULT source_reader_setup_sample_allocator(', start)
block = s[start:end]
old = '    UINT32 shared = 0, shared_without_mutex = 0;'
assert block.count(old) == 1
block = block.replace(old, '''    /* Iridium iOS: Unity opens final video frames on its render device.
     * Keep the final allocator shareable, like the processor's allocator. */
    UINT32 shared = 0, shared_without_mutex = !!(reader->flags & SOURCE_READER_DXGI_DEVICE_MANAGER);''')
old = '    IMFAttributes_GetUINT32(reader->attributes, &MF_SA_D3D11_SHARED, &shared);'
assert block.count(old) == 1
block = block.replace(old, '''    /* Explicit caller settings override the default, including FALSE. */
    if (SUCCEEDED(IMFAttributes_GetUINT32(reader->attributes, &MF_SA_D3D11_SHARED, &shared)))
        shared_without_mutex = 0;''')
out.write_text(s[:start]+block+s[end:])
command = subprocess.check_output(['make', '-n', '-W', str(source), obj], cwd=pe, env=env, text=True)
args = shlex.split(command.replace('\\\n', ' '))
assert args[0] == 'arm64ec-w64-mingw32-clang' and args.count(str(source)) == 1
args[args.index(str(source))] = str(out)
subprocess.run(args, cwd=pe, env=env, check=True)
subprocess.run(['make', '-j' + env.get('JOBS', '2'), dll], cwd=pe, env=env, check=True)
(root / 'MediaRuntime/mfreadwrite.dll').write_bytes((pe/dll).read_bytes())
