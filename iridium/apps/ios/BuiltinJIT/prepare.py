#!/usr/bin/env python3
"""Fetch the pinned, digest-checked StikJIT release into this worktree only."""
import hashlib
import io
import plistlib
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent / "Vendor"
URL = "https://github.com/StikDebug/StikJIT/releases/download/1.5.0/StikJIT.xcframework.zip"
SHA256 = "444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85"
if __name__ == "__main__":
    data = urllib.request.urlopen(URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("StikJIT archive digest mismatch; nothing extracted")
    ROOT.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            if not (ROOT / entry.filename).resolve().is_relative_to(ROOT.resolve()):
                raise SystemExit("Unsafe archive path")
        archive.extractall(ROOT)
    # Xcode 27 resolves the module name as the identically named public enum.
    # Strip only redundant self-module qualification; the binary ABI is unchanged.
    for interface in (ROOT / "StikJIT.xcframework").rglob("*.swiftinterface"):
        interface.write_text(interface.read_text().replace("StikJIT.", ""))
    # The published framework omits its own Info.plist. iOS signing requires it.
    info = {
        "CFBundleIdentifier": "software.iridium.vendor.StikJIT",
        "CFBundleName": "StikJIT", "CFBundleExecutable": "StikJIT",
        "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.5.0",
        "CFBundleVersion": "1.5.0", "MinimumOSVersion": "17.4",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
    }
    (ROOT / "StikJIT.xcframework/ios-arm64/StikJIT.framework/Info.plist").write_bytes(plistlib.dumps(info))
    print("Verified StikJIT 1.5.0 and applied the Xcode 27 interface correction")
