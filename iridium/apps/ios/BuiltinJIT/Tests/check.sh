#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
scratch=$(mktemp -d "${TMPDIR:-/tmp}/iridium-stikjit-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc "$root/Shared/JITMessages.swift" "$root/Tests/PairingCheck.swift" -o "$scratch/pairing-check"
"$scratch/pairing-check"
node "$root/Tests/script-check.js"
xcrun clang -fobjc-arc -fblocks -fsyntax-only -target arm64-apple-ios27.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" "$root/Host/JITExtension.m"
if [ "$#" -gt 0 ]; then
  python3 - "$1" <<'PY'
import pathlib, plistlib, sys, subprocess
app = pathlib.Path(sys.argv[1])
helper = app / 'PlugIns/IridiumJITHelper.appex'
for bundle in [app, helper]:
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    assert info['MinimumOSVersion'] == '27.0', bundle
framework = helper / 'Frameworks/StikJIT.framework'
info = plistlib.loads((framework / 'Info.plist').read_bytes())
assert info['CFBundleExecutable'] == 'StikJIT'
assert (framework / info['CFBundleExecutable']).stat().st_size > 0
assert 'IRIDIUM_SCRIPT_LISTENING' in (helper / 'madeira-jit.js').read_text()
assert not (app / 'Frameworks/StikJIT.framework').exists(), 'Framework must run only in the helper'
assert (helper / 'StikJITNotices/StikJIT-MPL-2.0.txt').exists()
symbols = subprocess.check_output(['xcrun', 'nm', str(helper / 'IridiumJITHelper')], text=True)
assert ' T _NSExtensionMain' in symbols, 'Missing custom extension entry point'
print('PASS: iOS 27 deployment, helper entry point, custom script, framework metadata, notices, and helper-only embedding')
PY
fi
