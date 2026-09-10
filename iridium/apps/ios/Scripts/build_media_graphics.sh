#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
madeira=$(CDPATH= cd -- "$root/../../../testrepos/Madeira" && pwd)
dxmt="$madeira/research/dxmt"
out="$root/.build/media"
mkdir -p "$out"
python3 - "$dxmt/src/winemetal/unix/winemetal_unix.c" "$out/winemetal_media.c" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
for name, call in [('Register','iridium_port_register(params->name, params->mach_port)'),('LookUp','iridium_port_lookup(params->name, &params->mach_port)')]:
 marker='_WMTBootstrap'+name+'(void *obj) {\n  struct unixcall_bootstrap *params = obj;'
 assert s.count(marker)==1, 'Review changed DXMT bootstrap implementation'
 s=s.replace(marker,marker+'\n#if TARGET_OS_IOS\n  return '+call+' ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;\n#endif')
marker='static inline void madeira_log_present_cadence(const char *path, double after) {'
assert s.count(marker)==1
s=s.replace(marker, 'extern void iridium_profile_present(void);\n'+marker+'\n  iridium_profile_present();')
Path(sys.argv[2]).write_text(s)
PY
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=18.0 -fblocks -O2 -x objective-c \
 -I"$dxmt/include" -I"$dxmt/libs" -I"$dxmt/src/winemetal" -I"$dxmt/src/airconv" -I"$dxmt/src/winemetal/unix" \
 -include "$root/MediaSupport/LocalSharedPorts.h" \
 -c "$out/winemetal_media.c" -o "$out/winemetal_unix.o"
cp "$madeira/app/Madeira/libdxmt_combined.a" "$out/libdxmt_media.a"
xcrun ar -r "$out/libdxmt_media.a" "$out/winemetal_unix.o"
