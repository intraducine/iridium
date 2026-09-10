#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
madeira=$(CDPATH= cd -- "$root/../../../testrepos/Madeira" && pwd)
wine="$madeira/wine"
out="$root/.build/media"
gst=${IRIDIUM_GSTREAMER_SDK:-"$root/.build/media-sdk/GStreamer.xcframework/ios-arm64"}
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$out"
for name in unixlib wg_muxer wg_allocator wg_transform wg_media_type wg_format wg_parser; do
  xcrun clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=18.0 -O2 -fPIC \
    -fno-strict-aliasing -fno-stack-protector -I"$gst/Headers" \
    -I"$wine/build-macos/include" -I"$wine/include" -D__WINESRC__ -DWINE_UNIX_LIB \
    -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
    -D__wine_unix_call_funcs=iridium_media_unix_funcs \
    -D__wine_unix_call_wow64_funcs=iridium_media_wow64_funcs \
    -c "$wine/dlls/winegstreamer/$name.c" -o "$out/$name.o"
done
python3 - "$madeira/build/ntdll-unix/virtual_ios.c" "$out/virtual_media.c" <<'PY'
import sys
s=open(sys.argv[1]).read()
marker='        if (match && strstr(match, "winemetal")) {'
assert s.count(marker) == 1, 'Madeira loader changed; review media hook'
s=s.replace(marker, '''        if (match && strstr(match, "winegstreamer")) {
            const void *(*get_funcs)(void) = dlsym(RTLD_DEFAULT, "iridium_media_get_unix_funcs");
            if (get_funcs && !wow) { *funcs = get_funcs(); return STATUS_SUCCESS; }
        }
'''+marker)
open(sys.argv[2],'w').write(s)
PY
xcrun clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=18.0 -O2 -fPIC \
  -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
  -Wno-implicit-function-declaration -Wno-int-conversion \
  -include "$wine/build-macos/include/config.h" \
  -include "$madeira/build/ntdll-unix/shims/wine_ios_exit.h" \
  -I"$madeira/build/ntdll-unix/shims" -I"$madeira/build/ntdll-unix" \
  -I"$wine/build-macos/dlls/ntdll" -I"$wine/dlls/ntdll" -I"$wine/dlls/ntdll/unix" \
  -I"$wine/build-macos/include" -I"$wine/include" \
  -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
  -DWINE_UNIX_LIB -DWINE_IOS=1 \
  -Dget_thread_context=ntdll_get_thread_context -Dset_thread_context=ntdll_set_thread_context \
  -c "$out/virtual_media.c" -o "$out/virtual.o"
cp "$madeira/app/Madeira/libntdll_unix.a" "$out/libntdll_media.a"
xcrun ar -r "$out/libntdll_media.a" "$out/virtual.o" "$out/unixlib.o" "$out/wg_"*.o
echo "Built media-enabled Wine native archive; original archive preserved."
pe="$root/.build/wine-media"
mkdir -p "$pe" "$root/MediaRuntime"
export PATH="$(brew --prefix bison)/bin:$madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
if [ ! -f "$pe/Makefile" ]; then
  (cd "$pe" && "$wine/configure" --enable-win64 --enable-archs=arm64ec \
    --without-x --without-freetype --without-gstreamer --enable-winegstreamer)
fi
make -C "$pe" -j"${JOBS:-2}" dlls/winegstreamer/arm64ec-windows/winegstreamer.dll dlls/msvproc/arm64ec-windows/msvproc.dll
make -C "$pe" -j"${JOBS:-2}" dlls/xaudio2_7/arm64ec-windows/xaudio2_7.dll
make -C "$pe" -j"${JOBS:-2}" dlls/d3dx9_42/arm64ec-windows/d3dx9_42.dll dlls/d3dcompiler_42/arm64ec-windows/d3dcompiler_42.dll
cp "$wine/libs/faudio/LICENSE" "$root/MediaRuntime/FAudio-LICENSE.txt"
for name in winegstreamer msvproc xaudio2_7 d3dx9_42 d3dcompiler_42; do
  cp "$pe/dlls/$name/arm64ec-windows/$name.dll" "$root/MediaRuntime/$name.dll"
done
python3 "$root/MediaSupport/video_processor_registry.py" "$wine" "$root/MediaRuntime/video-processor.reg"
cp "$wine/COPYING" "$root/MediaRuntime/msvproc-COPYING.txt"
x86_64-w64-mingw32-gcc -O2 "$root/MediaSupport/mfprobe.c" \
  -o "$root/MediaRuntime/iridium-mfprobe.exe" -lmfreadwrite -lmfplat -lmfuuid -lole32 -luuid -ld3d11 -ldxguid

sh "$root/Scripts/build_media_graphics.sh"

python3 "$root/Scripts/build_media_reader.py" "$pe"
