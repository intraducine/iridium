#!/usr/bin/env python3
"""Type-check the real Steam model and SwiftUI screen early using the iOS SDK.

The temporary host declaration isolates AppViewModel's runtime dependencies.
The full Xcode application build still validates its real implementation.
"""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    app = root / 'iridium/apps/ios/Iridium'
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='iridium-steam-ui-') as directory:
        host = Path(directory) / 'AppViewModel.swift'
        host.write_text('''import Combine
@MainActor final class AppViewModel: ObservableObject {
    func registerSteamDownload(title: String, appID: String,
        directory: String, executable: String) async throws {}
}
''', encoding='utf-8')
        subprocess.run([
            'xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-parse-as-library',
            '-sdk', sdk, '-target', 'arm64-apple-ios18.0', '-swift-version', '5',
            str(app / 'SteamLibraryModel.swift'),
            str(app / 'Views/SteamLibraryView.swift'), str(host),
        ], check=True, timeout=180)
    print('Steam model and SwiftUI screen passed iOS type checking.')


if __name__ == '__main__':
    main()
