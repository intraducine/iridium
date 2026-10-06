#!/usr/bin/env python3
"""Type-check the real Steam model and SwiftUI screen early using the iOS SDK.

The temporary host declarations isolate runtime and artwork storage dependencies.
The shared controls and page chrome are the actual app implementations.
The full Xcode application build still validates its real implementation.
"""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    ios = root / 'iridium/apps/ios'
    app = ios / 'Iridium'
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='iridium-steam-ui-') as directory:
        host = Path(directory) / 'AppViewModel.swift'
        host.write_text('''import Combine
import SwiftUI
import UIKit
enum LiveContainerIntegration { static func isHosted() -> Bool { false } }
@MainActor final class AppViewModel: ObservableObject {
    func registerSteamDownload(title: String, appID: String,
        directory: String, executable: String) async throws {}
    func deleteSteamDownload(_ job: SteamDownloadJob, from steam: SteamLibraryModel) async throws {}
}
struct LibraryAppearance { var background: String?; var backgroundY = 0.5 }
@MainActor final class LibraryArtwork: ObservableObject {
    static let shared = LibraryArtwork()
    var backdropGameID: UUID?
    func appearance(_ id: UUID) -> LibraryAppearance { LibraryAppearance() }
    func displayImage(_ name: String?) -> UIImage? { nil }
    func steamPortraitCoverURL(for appID: UInt32) async -> URL? { nil }
    func steamStoreStorageEstimate(for appID: UInt32) async -> String? { nil }
}
struct ArtworkImage: View {
    let image: UIImage
    let title: String
    let position: Double
    var body: some View { Image(uiImage: image) }
}
''', encoding='utf-8')
        subprocess.run([
            'xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-parse-as-library',
            '-sdk', sdk, '-target', 'arm64-apple-ios18.0', '-swift-version', '5',
            '-module-cache-path', str(Path(directory) / 'module-cache'),
            '-D', 'IRIDIUM_APP',
            str(app / 'SteamDownloadQueue.swift'),
            str(app / 'SteamLibraryModel.swift'),
            str(app / 'SteamChunkTransfer.swift'),
            str(app / 'SteamBackgroundSession.swift'),
            str(app / 'SteamBackgroundAppDelegate.swift'),
            str(app / 'SteamDownloadRuntime.swift'),
            str(app / 'SteamDownloadActivity.swift'),
            str(ios / 'SteamActivityShared/SteamDownloadActivityAttributes.swift'),
            str(app / 'SteamCloudModels.swift'),
            str(app / 'SteamCloudFileAccess.swift'),
            str(app / 'RuntimeLogCapture.swift'),
            str(app / 'LibraryController.swift'),
            str(app / 'Views/LibraryChrome.swift'),
            str(ios / 'MadeiraSupport/MadeiraSyncEngine.swift'),
            str(ios / 'MadeiraSupport/MadeiraSyncSettingsView.swift'),
            str(app / 'Views/SteamLibraryView.swift'), str(host),
        ], check=True, timeout=180)
    print('Steam model, SwiftUI screen and sync settings passed iOS type checking.')


if __name__ == '__main__':
    main()
