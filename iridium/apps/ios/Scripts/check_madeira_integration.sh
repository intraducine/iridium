#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
check_binary=$(mktemp /tmp/iridium-madeira-check.XXXXXX)
trap 'rm -f "$check_binary"' EXIT
xcrun swiftc "$root/MadeiraSupport/MadeiraGamePreparation.swift" \
  "$root/MadeiraSupportTests/GamePreparationCheck.swift" -o "$check_binary"
"$check_binary"
xcrun clang "$root/MadeiraSupportTests/ControllerPacketCheck.c" -o "$check_binary"
"$check_binary"
xcrun swiftc "$root/MadeiraSupport/MadeiraKeys.swift" \
  "$root/MadeiraSupportTests/ControllerCheck.swift" -o "$check_binary"
"$check_binary"
xcrun swiftc "$root/MadeiraSupport/MadeiraLaunchReadiness.swift" \
  "$root/MadeiraSupportTests/LaunchReadinessCheck.swift" -o "$check_binary"
"$check_binary"
xcrun swiftc "$root/MadeiraSupport/MadeiraPointerContact.swift" \
  "$root/MadeiraSupportTests/PointerContactCheck.swift" -o "$check_binary"
"$check_binary"
if [ "$#" -gt 0 ]; then
  app=$1
  codesign --verify --deep --strict "$app"
  codesign -d --entitlements :- "$app" 2>/dev/null | python3 -c 'import plistlib,sys; assert plistlib.loads(sys.stdin.buffer.read())["com.apple.developer.kernel.increased-memory-limit"] is True'
  test -f "$app/arm64ec-windows/xtajit64.dll"
  test -f "$app/arm64ec-windows/cube-x64.exe"
  test -f "$app/prefix-template.tar.gz"
  test -f "$app/legal/LICENSE"
  for symbol in _macdrv_functions _wine_process_start _madeira_get_present_count; do
    xcrun dyld_info -exports "$app/Frameworks/MadeiraNative.framework/MadeiraNative" | rg -q "$symbol"
  done
  echo 'PASS: signed app, production translator, cube, prefix, license, runtime exports'
fi

if [ -n "${1:-}" ]; then
  for name in xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0; do
    cmp "$1/ControllerRuntime/arm64ec/xinput.dll" "$1/arm64ec-windows/$name.dll"
  done
  echo 'PASS: system XInput libraries route to the controller bridge'
fi
