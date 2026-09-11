#!/usr/bin/env python3
"""Check the patched Meson API selection with an iOS 26+ SDK; no SDK build."""
from pathlib import Path
import subprocess,tempfile,sys,shutil
meson=shutil.which('meson')
if not meson: raise SystemExit('meson is required')
sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
source=(Path(sys.argv[1])/'sys/applemedia/meson.build').read_text()
block=source.split("  ios_media_dep = dependency('appleframeworks', modules : ['Foundation'], required : applemedia_option)",1)[1].split("  iosurface_dep =",1)[0]
for target in ['17.0','27.0']:
 work=Path(tempfile.mkdtemp(prefix='iridium-assets-meson-'))
 (work/'meson.build').write_text("project('assets-api-check', 'objc')\nobjc = meson.get_compiler('objc')\nsubsystem = 'ios'\napplemedia_sources = []\nios_deprecated_sources = ['iosassetsrc.m']\napplemedia_frameworks = []\napplemedia_args = []\n"+block+"\nassert(applemedia_sources.contains('iosassetsrc.m') == "+('true' if target=='17.0' else 'false')+", 'Wrong legacy API selection')\n")
 flags=['-arch','arm64','-isysroot',sdk,'-miphoneos-version-min='+target]
 (work/'cross.ini').write_text("[binaries]\nobjc = 'clang'\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n[built-in options]\nobjc_args = "+repr(flags)+"\nobjc_link_args = "+repr(flags)+"\n")
 subprocess.run([str(meson),'setup',str(work/'build'),str(work),'--cross-file',str(work/'cross.ini')],check=True)
 print('PASS actual Meson API detection for iOS '+target)
