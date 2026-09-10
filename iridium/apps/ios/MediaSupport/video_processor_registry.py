"""Generate offline test-prefix registration from Wine's processor format lists.

Mirrors msvproc DllRegisterServer and mfplat MFTRegister. Does not run Wine or
change a live prefix. Source format changes must pass the checks below.
"""
from pathlib import Path
import re
import sys
import uuid

wine, destination = map(Path, sys.argv[1:])
source = (wine / 'dlls/msvproc/msvproc.c').read_text()
headers = (wine / 'include/mfapi.h').read_text() + source
d3d = (wine / 'include/d3d9types.h').read_text()
major = uuid.UUID('73646976-0000-0010-8000-00aa00389b71').bytes_le
processor = '88753b26-5b24-49bd-b2e7-0c445c78c982'
category = '302ea3fc-aa5f-47f9-9f7a-c2188bb16302'

def formats(direction):
    block = re.search(r'video_processor_mft_' + direction + r'\[\]\s*=\s*\{(.*?)\n    \};', source, re.S)
    assert block, 'Wine registration changed'
    names = re.findall(r'\{MFMediaType_Video, MFVideoFormat_(\w+)\}', block[1])
    result = b''
    for name in names:
        definition = re.search(r'DEFINE_MEDIATYPE_GUID\(MFVideoFormat_' + name + r',\s*(.*?)\);', headers)[1]
        if definition.startswith('MAKEFOURCC'):
            chars = re.findall(r"'(.)'", definition)
            assert len(chars) == 4
            value = int.from_bytes(''.join(chars).encode('ascii'), 'little')
        else:
            value = int(re.search(r'\b' + definition + r'\s*=\s*(\d+)', d3d)[1])
        subtype = uuid.UUID(f'{value:08x}-0000-0010-8000-00aa00389b71').bytes_le
        result += major + subtype
    assert len(result) == len(names) * 32 and names
    return names, result

def section(key, body=''):
    return '[' + ('Software\\Classes\\' + key).replace('\\', '\\\\') + ']\n' + body + '\n'

text = ''
for clsid, dll in [(processor, 'msvproc.dll'), ('d527607f-89cb-4e94-9571-bcfe62175613', 'winegstreamer.dll')]:
    text += section('CLSID\\{' + clsid + '}\\InprocServer32', '@="' + dll + '"\n"ThreadingModel"="Both"\n')
body = '@="Microsoft Video Processor MFT"\n"MFTFlags"=dword:00000001\n'
for direction in ['inputs', 'outputs']:
    names, blob = formats(direction)
    assert len(names) == (22 if direction == 'inputs' else 21), 'Review changed Wine formats'
    assert 'NV12' in names and 'RGB32' in names
    body += '"' + direction.title().replace('s', 'Types') + '"=hex:' + ','.join(f'{b:02x}' for b in blob) + '\n'
text += section('MediaFoundation\\Transforms\\' + processor, body)
text += section('MediaFoundation\\Transforms\\Categories\\' + category + '\\' + processor)
assert '"InputTypes"' in text and '"OutputTypes"' in text
assert text.count('InprocServer32]') == 2
assert uuid.UUID(bytes_le=major).hex.startswith('73646976')
destination.write_text(text)
print('Generated processor registration: 22 input and 21 output formats')
