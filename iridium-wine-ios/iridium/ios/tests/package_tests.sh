#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
REPO_ROOT=${ROOT:h:h}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iridium-wine-ios-package-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

function fail() {
  echo "FAIL: $1" >&2
  exit 1
}

function require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

function require_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

function require_contains() {
  local file="$1"
  local pattern="$2"
  grep -F -- "$pattern" "$file" >/dev/null 2>&1 || fail "missing pattern '$pattern' in $file"
}

function require_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "unexpected pattern '$pattern' in $file"
  fi
}

function write_fake_x86_64_elf() {
  local file="$1"
  mkdir -p "${file:h}"
  printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' > "$file"
}

function write_fake_x86_64_elf_with_pt_interp() {
  local file="$1"
  mkdir -p "${file:h}"
  python3 - "$file" <<'PY'
from pathlib import Path
import sys

interpreter = b"/lib64/ld-linux-x86-64.so.2\0"
data = bytearray(160)
data[0:4] = b"\x7fELF"
data[4] = 2
data[5] = 1
data[16:18] = (2).to_bytes(2, "little")
data[18:20] = (62).to_bytes(2, "little")
data[32:40] = (64).to_bytes(8, "little")
data[52:54] = (64).to_bytes(2, "little")
data[54:56] = (56).to_bytes(2, "little")
data[56:58] = (1).to_bytes(2, "little")
data[64:68] = (3).to_bytes(4, "little")
data[72:80] = (128).to_bytes(8, "little")
data[96:104] = len(interpreter).to_bytes(8, "little")
data[104:112] = len(interpreter).to_bytes(8, "little")
data[128:128 + len(interpreter)] = interpreter
Path(sys.argv[1]).write_bytes(data)
PY
}

function write_fake_macho() {
  local file="$1"
  mkdir -p "${file:h}"
  printf '\xcf\xfa\xed\xfeMachO' > "$file"
}

function write_fake_opengl_backend() {
  local file="$1"
  mkdir -p "${file:h}"
  print -n "ELF egl_handle eglGetProcAddress" > "$file"
}

function write_fake_egl_loader() {
  local file="$1"
  mkdir -p "${file:h}"
  print -n "ELF libEGL.so.1 eglGetProcAddress" > "$file"
}

function expect_failure() {
  local expected="$1"
  shift

  local output
  if output=$("$@" 2>&1); then
    fail "command unexpectedly succeeded: $*"
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "expected failure containing '$expected'"
  fi
}

if ! command -v zstd >/dev/null 2>&1; then
  fail "zstd is required for package tests"
fi

cc -std=c11 -pthread \
  -I"$ROOT/include" \
  "$ROOT/src/embedded_wineserver.c" \
  "$ROOT/tests/embedded_wineserver_tests.c" \
  -o "$TEST_ROOT/embedded_wineserver_tests"
"$TEST_ROOT/embedded_wineserver_tests"

cc -std=c11 \
  -I"$REPO_ROOT/include" \
  "$ROOT/tests/guest_image_arena_tests.c" \
  -o "$TEST_ROOT/guest_image_arena_tests"
"$TEST_ROOT/guest_image_arena_tests"

require_contains "$REPO_ROOT/configure.ac" "WINE_CONFIG_MAKEFILE(dlls/wineios.drv)"
require_contains "$REPO_ROOT/configure" "wine_fn_config_makefile dlls/wineios.drv enable_wineios_drv"
require_file "$REPO_ROOT/dlls/wineios.drv/Makefile.in"
require_file "$REPO_ROOT/dlls/wineios.drv/bridge.c"
require_file "$REPO_ROOT/dlls/wineios.drv/dllmain.c"
require_file "$REPO_ROOT/dlls/wineios.drv/init.c"
require_file "$REPO_ROOT/dlls/wineios.drv/input.c"
require_file "$REPO_ROOT/dlls/wineios.drv/iosdrv.h"
require_file "$REPO_ROOT/dlls/wineios.drv/opengl.c"
require_file "$REPO_ROOT/dlls/wineios.drv/surface.c"
require_contains "$REPO_ROOT/dlls/wineios.drv/surface.c" '#pragma makedep unix'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'IRIDIUM_WINE_IOS_GRAPHICS_DRIVER_ENV'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'IRIDIUM_WINE_IOS_AUDIO_DRIVER_ENV'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'wineiosdrv_present_frame'
require_contains "$REPO_ROOT/dlls/wineios.drv/iosdrv.h" 'wineiosdrv_OpenGLInit'
require_contains "$REPO_ROOT/dlls/wineios.drv/window.c" '.pOpenGLInit = wineiosdrv_OpenGLInit'
require_contains "$REPO_ROOT/dlls/wineios.drv/opengl.c" 'p_eglCreatePbufferSurface'
require_contains "$REPO_ROOT/dlls/wineios.drv/opengl.c" 'p_glReadPixels'
require_contains "$REPO_ROOT/dlls/wineios.drv/init.c" 'wineiosdrv_get_playable_session_contract'
require_contains "$REPO_ROOT/dlls/wineios.drv/init.c" 'metalOpenGLFallback'
require_not_contains "$REPO_ROOT/dlls/wineios.drv/init.c" '#include "config.h"'
require_contains "$REPO_ROOT/dlls/win32u/driver.c" 'IRIDIUM_WINE_IOS_GRAPHICS_DRIVER'
require_contains "$REPO_ROOT/dlls/win32u/driver.c" 'load_iridium_environment_driver'
require_contains "$REPO_ROOT/dlls/win32u/driver.c" 'preferring Iridium environment driver over prefix registry'
require_contains "$REPO_ROOT/dlls/win32u/driver.c" 'registry GraphicsDriver load'
require_file "$REPO_ROOT/dlls/winecoreaudio.drv/iridium_ios_audio.c"
require_file "$REPO_ROOT/dlls/winecoreaudio.drv/iridium_ios_audio.h"
require_contains "$REPO_ROOT/dlls/winecoreaudio.drv/Makefile.in" 'iridium_ios_audio.c'
require_contains "$REPO_ROOT/dlls/winecoreaudio.drv/iridium_ios_audio.c" '#pragma makedep unix'
require_contains "$REPO_ROOT/dlls/winecoreaudio.drv/coreaudio.c" 'iridium_ios_audio_render_ready'
require_contains "$ROOT/build_install_root.sh" 'stage_linux_runtime_deps.sh --install-root /work/install-root'
require_contains "$ROOT/build_install_root.sh" 'embedded-server-only)'
require_contains "$ROOT/build_install_root.sh" '"--with-opengl"'
require_contains "$ROOT/build_install_root.sh" 'if [[ "$PLATFORM" == "host" || "$EMBEDDED_SERVER_ONLY" -eq 1 ]]'
require_contains "$ROOT/build_install_root.sh" '"--without-opengl"'
require_contains "$REPO_ROOT/server/mapping.c" 'IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS'
require_contains "$REPO_ROOT/server/mapping.c" 'mapping->image.machine == IMAGE_FILE_MACHINE_AMD64'
require_contains "$REPO_ROOT/dlls/ntdll/unix/virtual.c" 'correcting PE relocation base'
require_contains "$REPO_ROOT/dlls/ntdll/unix/virtual.c" 'constraining AMD64 PE image'
require_contains "$REPO_ROOT/dlls/ntdll/unix/virtual.c" 'IRIDIUM_GUEST_IMAGE_ARENA_END - 1'
require_contains "$REPO_ROOT/server/mapping.c" 'ignoring cached PE address'

UNMANAGED_SEED_ROOT="$TEST_ROOT/unmanaged-seed-root"
mkdir -p "$UNMANAGED_SEED_ROOT"
print -n "keep" > "$UNMANAGED_SEED_ROOT/sentinel"
expect_failure \
  "refusing to replace unmanaged prefix-seed output" \
  "$ROOT/generate_prefix_seed.sh" \
  --output "$UNMANAGED_SEED_ROOT"
require_file "$UNMANAGED_SEED_ROOT/sentinel"

expect_failure \
  "prefix-seed template and prefix-seed output must not overlap" \
  "$ROOT/generate_prefix_seed.sh" \
  --output "$ROOT"

expect_failure \
  "refusing to replace install root because it contains protected path" \
  "$ROOT/build_install_root.sh" \
  --build-root "$TEST_ROOT/safe-build-root" \
  --install-root "$REPO_ROOT" \
  --platform host

INSTALL_ROOT="$TEST_ROOT/install-root"
mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib/wine/x86_64-unix" "$INSTALL_ROOT/share/wine"
print -n "wine64" > "$INSTALL_ROOT/bin/wine64"
print -n "wineserver" > "$INSTALL_ROOT/bin/wineserver"
print -n "dll" > "$INSTALL_ROOT/lib/wine/kernel32.dll"
print -n "build-only" > "$INSTALL_ROOT/lib/wine/libkernel32.a"
write_fake_x86_64_elf "$INSTALL_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$INSTALL_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$INSTALL_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$INSTALL_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$INSTALL_ROOT/share/wine/readme.txt"
mkdir -p "$INSTALL_ROOT/share/wine/nls"
print -n "intl" > "$INSTALL_ROOT/share/wine/nls/l_intl.nls"
print -n "explorer" > "$INSTALL_ROOT/share/wine/explorer.exe"
print -n "cmd" > "$INSTALL_ROOT/share/wine/cmd.exe"

expect_failure \
  "source root and output root must not overlap" \
  "$ROOT/stage_userland.sh" \
  --source-root "$INSTALL_ROOT" \
  --output-root "$INSTALL_ROOT"
require_file "$INSTALL_ROOT/bin/wineserver"

STAGED_ROOT="$TEST_ROOT/staged-root"
SEED_ROOT="$TEST_ROOT/generated-prefix-seed"
"$ROOT/stage_userland.sh" \
  --source-root "$INSTALL_ROOT" \
  --output-root "$STAGED_ROOT" \
  --seed-output "$SEED_ROOT"

require_file "$STAGED_ROOT/.iridium-userland-stage"
require_file "$STAGED_ROOT/bin/wine64"
require_file "$STAGED_ROOT/bin/wineserver"
require_dir "$STAGED_ROOT/lib/wine"
[[ ! -e "$STAGED_ROOT/lib/wine/libkernel32.a" ]] || fail "staged runtime retained build-only static library"
require_file "$STAGED_ROOT/lib/wine/x86_64-unix/wineios.so"
require_file "$STAGED_ROOT/lib/wine/x86_64-unix/opengl32.so"
require_file "$STAGED_ROOT/lib/wine/x86_64-unix/win32u.so"
require_dir "$STAGED_ROOT/share/wine"
require_dir "$STAGED_ROOT/prefix-seed"
require_contains "$STAGED_ROOT/.iridium-userland-stage" "embedded_guest_loader=lib/wine/x86_64-unix/wine"
require_contains "$STAGED_ROOT/.iridium-userland-stage" "wineios_driver=lib/wine/x86_64-unix/wineios.so"
require_contains "$STAGED_ROOT/.iridium-userland-stage" "opengl_backend=lib/wine/x86_64-unix/opengl32.so"
require_file "$SEED_ROOT/system.reg"
require_file "$SEED_ROOT/user.reg"
require_file "$SEED_ROOT/userdef.reg"
require_contains "$STAGED_ROOT/prefix-seed/system.reg" "WINE REGISTRY Version 2"
require_contains "$STAGED_ROOT/prefix-seed/system.reg" "#arch=win64"
require_contains "$STAGED_ROOT/prefix-seed/system.reg" '"GraphicsDriver"="wineios.drv"'
require_contains "$STAGED_ROOT/prefix-seed/user.reg" '"Graphics"="ios"'
require_contains "$STAGED_ROOT/prefix-seed/user.reg" '"Audio"="coreaudio"'

ARCHIVE_PATH="$TEST_ROOT/wine-userland.tar.zst"
"$ROOT/package_userland.sh" \
  --source-root "$STAGED_ROOT" \
  --output "$ARCHIVE_PATH" \
  --prefix-seed "$STAGED_ROOT/prefix-seed"

require_file "$ARCHIVE_PATH"
MEMBERS="$TEST_ROOT/archive-members.txt"
tar -tf "$ARCHIVE_PATH" | sed 's#^\./##' > "$MEMBERS"

require_contains "$MEMBERS" "bin/wine64"
require_contains "$MEMBERS" "bin/wineserver"
require_contains "$MEMBERS" "lib/wine/kernel32.dll"
require_contains "$MEMBERS" "lib/wine/x86_64-unix/wine"
require_contains "$MEMBERS" "lib/wine/x86_64-unix/wineios.so"
require_contains "$MEMBERS" "lib/wine/x86_64-unix/opengl32.so"
require_contains "$MEMBERS" "lib/wine/x86_64-unix/win32u.so"
require_contains "$MEMBERS" "share/wine/readme.txt"
require_contains "$MEMBERS" "share/wine/nls/l_intl.nls"
require_contains "$MEMBERS" "prefix-seed/system.reg"
require_contains "$MEMBERS" "prefix-seed/user.reg"
require_contains "$MEMBERS" "prefix-seed/userdef.reg"
require_not_contains "$MEMBERS" "share/wine/explorer.exe"
require_not_contains "$MEMBERS" "share/wine/cmd.exe"

PRELOADER_ROOT="$TEST_ROOT/preloader-root"
mkdir -p "$PRELOADER_ROOT/bin" "$PRELOADER_ROOT/lib/wine/x86_64-unix" "$PRELOADER_ROOT/lib/x86_64-linux-gnu" "$PRELOADER_ROOT/lib64" "$PRELOADER_ROOT/share/wine"
print -n "wine64" > "$PRELOADER_ROOT/bin/wine64"
print -n "wineserver" > "$PRELOADER_ROOT/bin/wineserver"
print -n "dll" > "$PRELOADER_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf_with_pt_interp "$PRELOADER_ROOT/lib/wine/x86_64-unix/wine"
write_fake_x86_64_elf "$PRELOADER_ROOT/lib/wine/x86_64-unix/wine-preloader"
print -n "wineios" > "$PRELOADER_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$PRELOADER_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$PRELOADER_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "ld-linux" > "$PRELOADER_ROOT/lib64/ld-linux-x86-64.so.2"
print -n "libc" > "$PRELOADER_ROOT/lib/x86_64-linux-gnu/libc.so.6"
print -n "share" > "$PRELOADER_ROOT/share/wine/readme.txt"
mkdir -p "$PRELOADER_ROOT/share/wine/nls"
print -n "intl" > "$PRELOADER_ROOT/share/wine/nls/l_intl.nls"

PRELOADER_STAGE_ROOT="$TEST_ROOT/preloader-stage-root"
PRELOADER_SEED_ROOT="$TEST_ROOT/preloader-seed"
"$ROOT/stage_userland.sh" \
  --source-root "$PRELOADER_ROOT" \
  --output-root "$PRELOADER_STAGE_ROOT" \
  --seed-output "$PRELOADER_SEED_ROOT"

require_contains "$PRELOADER_STAGE_ROOT/.iridium-userland-stage" "embedded_guest_loader=lib/wine/x86_64-unix/wine-preloader"
require_file "$PRELOADER_STAGE_ROOT/lib64/ld-linux-x86-64.so.2"
require_file "$PRELOADER_STAGE_ROOT/lib/x86_64-linux-gnu/libc.so.6"

PRELOADER_ARCHIVE_PATH="$TEST_ROOT/preloader-userland.tar.zst"
"$ROOT/package_userland.sh" \
  --source-root "$PRELOADER_STAGE_ROOT" \
  --output "$PRELOADER_ARCHIVE_PATH" \
  --prefix-seed "$PRELOADER_STAGE_ROOT/prefix-seed"

PRELOADER_MEMBERS="$TEST_ROOT/preloader-archive-members.txt"
tar -tf "$PRELOADER_ARCHIVE_PATH" | sed 's#^\./##' > "$PRELOADER_MEMBERS"
require_contains "$PRELOADER_MEMBERS" "lib/wine/x86_64-unix/wine-preloader"
require_contains "$PRELOADER_MEMBERS" "lib64/ld-linux-x86-64.so.2"
require_contains "$PRELOADER_MEMBERS" "lib/x86_64-linux-gnu/libc.so.6"

LINUX_INSTALL_ROOT="$TEST_ROOT/linux-install-root"
LINUX_SYSROOT="$TEST_ROOT/linux-sysroot"
FAKE_LDD="$TEST_ROOT/fake-ldd"
mkdir -p "$LINUX_INSTALL_ROOT/lib/wine/x86_64-unix" "$LINUX_SYSROOT/lib64" "$LINUX_SYSROOT/lib/x86_64-linux-gnu"
write_fake_x86_64_elf_with_pt_interp "$LINUX_INSTALL_ROOT/lib/wine/x86_64-unix/wine"
write_fake_x86_64_elf "$LINUX_INSTALL_ROOT/lib/wine/x86_64-unix/wine-preloader"
print -n "ld-linux" > "$LINUX_SYSROOT/lib64/ld-linux-x86-64.so.2"
print -n "libc" > "$LINUX_SYSROOT/lib/x86_64-linux-gnu/libc.so.6"
cat > "$FAKE_LDD" <<EOF
#!/bin/sh
cat <<'LDD'
	linux-vdso.so.1 (0x00007fff00000000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fff00000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007fff00000000)
LDD
EOF
chmod 755 "$FAKE_LDD"
LDD_BIN="$FAKE_LDD" LINUX_RUNTIME_DEP_SOURCE_ROOT="$LINUX_SYSROOT" "$ROOT/stage_linux_runtime_deps.sh" \
  --install-root "$LINUX_INSTALL_ROOT"
require_file "$LINUX_INSTALL_ROOT/lib64/ld-linux-x86-64.so.2"
require_file "$LINUX_INSTALL_ROOT/lib/x86_64-linux-gnu/libc.so.6"

MISSING_PRELOADER_INTERP_ROOT="$TEST_ROOT/missing-preloader-interp-root"
mkdir -p "$MISSING_PRELOADER_INTERP_ROOT/bin" "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix" "$MISSING_PRELOADER_INTERP_ROOT/share/wine"
print -n "wine64" > "$MISSING_PRELOADER_INTERP_ROOT/bin/wine64"
print -n "wineserver" > "$MISSING_PRELOADER_INTERP_ROOT/bin/wineserver"
print -n "dll" > "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf_with_pt_interp "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix/wine"
write_fake_x86_64_elf "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix/wine-preloader"
print -n "wineios" > "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$MISSING_PRELOADER_INTERP_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$MISSING_PRELOADER_INTERP_ROOT/share/wine/readme.txt"
mkdir -p "$MISSING_PRELOADER_INTERP_ROOT/share/wine/nls"
print -n "intl" > "$MISSING_PRELOADER_INTERP_ROOT/share/wine/nls/l_intl.nls"
expect_failure \
  "wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter" \
  "$ROOT/stage_userland.sh" \
  --source-root "$MISSING_PRELOADER_INTERP_ROOT" \
  --output-root "$TEST_ROOT/missing-preloader-interp-stage"

HAND_PREPARED_ROOT="$TEST_ROOT/hand-prepared-root"
mkdir -p "$HAND_PREPARED_ROOT/bin" "$HAND_PREPARED_ROOT/lib/wine/x86_64-unix" "$HAND_PREPARED_ROOT/share/wine" "$HAND_PREPARED_ROOT/prefix-seed"
print -n "wine64" > "$HAND_PREPARED_ROOT/bin/wine64"
print -n "wineserver" > "$HAND_PREPARED_ROOT/bin/wineserver"
print -n "dll" > "$HAND_PREPARED_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf "$HAND_PREPARED_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$HAND_PREPARED_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$HAND_PREPARED_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$HAND_PREPARED_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$HAND_PREPARED_ROOT/share/wine/readme.txt"
mkdir -p "$HAND_PREPARED_ROOT/share/wine/nls"
print -n "intl" > "$HAND_PREPARED_ROOT/share/wine/nls/l_intl.nls"
cp "$SEED_ROOT"/system.reg "$HAND_PREPARED_ROOT/prefix-seed/system.reg"
cp "$SEED_ROOT"/user.reg "$HAND_PREPARED_ROOT/prefix-seed/user.reg"
cp "$SEED_ROOT"/userdef.reg "$HAND_PREPARED_ROOT/prefix-seed/userdef.reg"

expect_failure \
  "source root must be produced by iridium/ios/stage_userland.sh" \
  "$ROOT/package_userland.sh" \
  --source-root "$HAND_PREPARED_ROOT" \
  --output "$TEST_ROOT/invalid.tar.zst" \
  --prefix-seed "$HAND_PREPARED_ROOT/prefix-seed"

MISSING_WINESERVER_ROOT="$TEST_ROOT/missing-wineserver-root"
mkdir -p "$MISSING_WINESERVER_ROOT/bin" "$MISSING_WINESERVER_ROOT/lib/wine/x86_64-unix" "$MISSING_WINESERVER_ROOT/share/wine"
print -n "wine64" > "$MISSING_WINESERVER_ROOT/bin/wine64"
print -n "dll" > "$MISSING_WINESERVER_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf "$MISSING_WINESERVER_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$MISSING_WINESERVER_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$MISSING_WINESERVER_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$MISSING_WINESERVER_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$MISSING_WINESERVER_ROOT/share/wine/readme.txt"
mkdir -p "$MISSING_WINESERVER_ROOT/share/wine/nls"
print -n "intl" > "$MISSING_WINESERVER_ROOT/share/wine/nls/l_intl.nls"
expect_failure \
  "source root must contain bin/wineserver" \
  "$ROOT/stage_userland.sh" \
  --source-root "$MISSING_WINESERVER_ROOT" \
  --output-root "$TEST_ROOT/unused-stage"

MACHO_ONLY_ROOT="$TEST_ROOT/macho-only-root"
mkdir -p "$MACHO_ONLY_ROOT/bin" "$MACHO_ONLY_ROOT/lib/wine/x86_64-unix" "$MACHO_ONLY_ROOT/share/wine"
print -n "wine64" > "$MACHO_ONLY_ROOT/bin/wine64"
print -n "wineserver" > "$MACHO_ONLY_ROOT/bin/wineserver"
print -n "dll" > "$MACHO_ONLY_ROOT/lib/wine/kernel32.dll"
write_fake_macho "$MACHO_ONLY_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$MACHO_ONLY_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$MACHO_ONLY_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$MACHO_ONLY_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$MACHO_ONLY_ROOT/share/wine/readme.txt"
mkdir -p "$MACHO_ONLY_ROOT/share/wine/nls"
print -n "intl" > "$MACHO_ONLY_ROOT/share/wine/nls/l_intl.nls"
expect_failure \
  "embedded-FEX-compatible x86_64 ELF Wine loader" \
  "$ROOT/stage_userland.sh" \
  --source-root "$MACHO_ONLY_ROOT" \
  --output-root "$TEST_ROOT/macho-stage"
expect_failure \
  "Mach-O" \
  "$ROOT/stage_userland.sh" \
  --source-root "$MACHO_ONLY_ROOT" \
  --output-root "$TEST_ROOT/macho-stage"

PT_INTERP_ONLY_ROOT="$TEST_ROOT/pt-interp-only-root"
mkdir -p "$PT_INTERP_ONLY_ROOT/bin" "$PT_INTERP_ONLY_ROOT/lib/wine/x86_64-unix" "$PT_INTERP_ONLY_ROOT/share/wine"
print -n "wine64" > "$PT_INTERP_ONLY_ROOT/bin/wine64"
print -n "wineserver" > "$PT_INTERP_ONLY_ROOT/bin/wineserver"
print -n "dll" > "$PT_INTERP_ONLY_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf_with_pt_interp "$PT_INTERP_ONLY_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$PT_INTERP_ONLY_ROOT/lib/wine/x86_64-unix/wineios.so"
write_fake_opengl_backend "$PT_INTERP_ONLY_ROOT/lib/wine/x86_64-unix/opengl32.so"
write_fake_egl_loader "$PT_INTERP_ONLY_ROOT/lib/wine/x86_64-unix/win32u.so"
print -n "share" > "$PT_INTERP_ONLY_ROOT/share/wine/readme.txt"
mkdir -p "$PT_INTERP_ONLY_ROOT/share/wine/nls"
print -n "intl" > "$PT_INTERP_ONLY_ROOT/share/wine/nls/l_intl.nls"
expect_failure \
  "without PT_INTERP" \
  "$ROOT/stage_userland.sh" \
  --source-root "$PT_INTERP_ONLY_ROOT" \
  --output-root "$TEST_ROOT/pt-interp-stage"
expect_failure \
  "PT_INTERP" \
  "$ROOT/stage_userland.sh" \
  --source-root "$PT_INTERP_ONLY_ROOT" \
  --output-root "$TEST_ROOT/pt-interp-stage"

cp "$SEED_ROOT"/user.reg "$STAGED_ROOT/prefix-seed/user.reg.bak"
rm "$STAGED_ROOT/prefix-seed/user.reg"
expect_failure \
  "prefix seed is missing user.reg" \
  "$ROOT/package_userland.sh" \
  --source-root "$STAGED_ROOT" \
  --output "$TEST_ROOT/missing-seed.tar.zst" \
  --prefix-seed "$STAGED_ROOT/prefix-seed"
mv "$STAGED_ROOT/prefix-seed/user.reg.bak" "$STAGED_ROOT/prefix-seed/user.reg"

MISSING_OPENGL_ROOT="$TEST_ROOT/missing-opengl-root"
mkdir -p "$MISSING_OPENGL_ROOT/bin" "$MISSING_OPENGL_ROOT/lib/wine/x86_64-unix" "$MISSING_OPENGL_ROOT/share/wine"
print -n "wine64" > "$MISSING_OPENGL_ROOT/bin/wine64"
print -n "wineserver" > "$MISSING_OPENGL_ROOT/bin/wineserver"
print -n "dll" > "$MISSING_OPENGL_ROOT/lib/wine/kernel32.dll"
write_fake_x86_64_elf "$MISSING_OPENGL_ROOT/lib/wine/x86_64-unix/wine"
print -n "wineios" > "$MISSING_OPENGL_ROOT/lib/wine/x86_64-unix/wineios.so"
print -n "share" > "$MISSING_OPENGL_ROOT/share/wine/readme.txt"
mkdir -p "$MISSING_OPENGL_ROOT/share/wine/nls"
print -n "intl" > "$MISSING_OPENGL_ROOT/share/wine/nls/l_intl.nls"
expect_failure \
  "OpenGL backend" \
  "$ROOT/stage_userland.sh" \
  --source-root "$MISSING_OPENGL_ROOT" \
  --output-root "$TEST_ROOT/missing-opengl-stage"

rm "$STAGED_ROOT/bin/wineserver"
expect_failure \
  "source root must contain bin/wineserver" \
  "$ROOT/package_userland.sh" \
  --source-root "$STAGED_ROOT" \
  --output "$TEST_ROOT/missing-wineserver.tar.zst" \
  --prefix-seed "$STAGED_ROOT/prefix-seed"

echo "package_tests passed"
