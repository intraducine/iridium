"""Execute shipping artwork precedence and embedded-editor navigation policies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'

CHECKS = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        typealias Source = IridiumArtworkSourcePolicy.Source
        var item = IridiumArtworkAppearance()
        item.cover = "automatic-cover.jpg"
        item.background = "automatic-background.jpg"
        func sources(_ backdrop: Bool) -> [Source] {
            IridiumArtworkSourcePolicy.sources(item, legacyCover: "chosen-cover.jpg",
                legacyBackground: "imported-background.jpg", steamID: 123, backdrop: backdrop)
        }
        precondition(sources(false) == [.legacyCover("chosen-cover.jpg"), .shared("automatic-cover.jpg"), .steam(123)])
        precondition(sources(true) == [.legacyBackground("imported-background.jpg"), .legacyCover("chosen-cover.jpg"),
            .shared("automatic-background.jpg"), .shared("automatic-cover.jpg"), .steam(123)])
        precondition(!IridiumArtworkSourcePolicy.needsAutomaticCover(item, legacyCover: "chosen-cover.jpg"))
        precondition(!IridiumArtworkSourcePolicy.needsAutomaticBackground(item, legacyCover: "chosen-cover.jpg", legacyBackground: nil))
        item.customCover = true; item.cover = "new-manual.jpg"
        precondition(sources(false) == [.shared("new-manual.jpg")])
        precondition(sources(true).first == .legacyBackground("imported-background.jpg"))
        item.cover = nil
        precondition(sources(false).isEmpty) // Explicit removal never resurrects old or online art.
        precondition(!sources(true).contains(.legacyCover("chosen-cover.jpg")))
        item.customBackground = true; item.background = "new-background.jpg"
        precondition(sources(true) == [.shared("new-background.jpg")])
        item.background = nil
        precondition(sources(true).isEmpty)
        item.customCover = false; item.ignoreLegacyCover = true; item.cover = "automatic-cover.jpg"
        precondition(sources(false) == [.shared("automatic-cover.jpg"), .steam(123)])
        item.customBackground = false; item.ignoreLegacyBackground = true; item.background = "automatic-background.jpg"
        precondition(sources(true) == [.shared("automatic-background.jpg"), .shared("automatic-cover.jpg"), .steam(123)])
        item.automaticLookup = false; item.cover = nil; item.background = nil
        precondition(sources(false).isEmpty && sources(true).isEmpty)

        // Older shared records lack the newly optional per-slot opt-out flags.
        let data = try JSONEncoder().encode(IridiumArtworkAppearance())
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "ignoreLegacyCover"); json.removeValue(forKey: "ignoreLegacyBackground")
        let older = try JSONDecoder().decode(IridiumArtworkAppearance.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(older.ignoreLegacyCover == nil && older.ignoreLegacyBackground == nil)
        precondition(IridiumArtworkSourcePolicy.sources(older, legacyCover: "old.jpg", legacyBackground: nil,
            steamID: nil, backdrop: false) == [.legacyCover("old.jpg")])

        precondition(IridiumArtworkBackPolicy.action(pickerPresented: true, fieldFocused: true) == .ignore)
        precondition(IridiumArtworkBackPolicy.action(pickerPresented: true, fieldFocused: false) == .ignore)
        precondition(IridiumArtworkBackPolicy.action(pickerPresented: false, fieldFocused: true) == .endEditing)
        precondition(IridiumArtworkBackPolicy.action(pickerPresented: false, fieldFocused: false) == .leaveEditor)
        // Exercise the production deferral with both synchronous subscriber
        // orders. The editor may receive Back before or after its parent.
        for editorFirst in [false, true] {
            var page = "artwork"
            var pops = 0
            let parent: @MainActor () -> Void = {
                if page != "artwork" { pops += 1 }
            }
            let editor: @MainActor () -> Void = {
                IridiumArtworkBackPolicy.leaveAfterCurrentDelivery {
                    if page == "artwork" { page = "options"; pops += 1 }
                }
            }
            if editorFirst { editor(); parent() } else { parent(); editor() }
            precondition(page == "artwork" && pops == 0)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            precondition(page == "options" && pops == 1)
        }

        let urls = (0..<7).map { URL(string: "https://example.invalid/app/123/asset\($0).jpg")! }
        var attempts: [URL] = []
        let fallback: String = try await IridiumArtworkFallback.firstAvailable([urls[0], urls[0], urls[1], urls[2]]) { url in
            attempts.append(url)
            if url != urls[2] { throw URLError(.fileDoesNotExist) }
            return "decoded candidate artwork"
        }
        precondition(fallback == "decoded candidate artwork" && attempts == Array(urls.prefix(3)))
        attempts = []
        do {
            let _: String = try await IridiumArtworkFallback.firstAvailable(urls) { url in
                attempts.append(url)
                throw URLError(.fileDoesNotExist)
            }
            fatalError("unavailable artwork was accepted")
        } catch { precondition(attempts == Array(urls.prefix(5))) }
        attempts = []
        do {
            let _: String = try await IridiumArtworkFallback.firstAvailable(urls) { url in
                attempts.append(url)
                throw URLError(.cancelled)
            }
            fatalError("cancelled artwork continued")
        } catch is CancellationError { precondition(attempts == [urls[0]]) }
        print("Artwork precedence, fallback and navigation passed")
    }
}
'''

class ArtworkPresentationPolicyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for artwork policy execution')
    def test_legacy_manual_removal_and_navigation(self):
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'Checks.swift'
            main.write_text(CHECKS)
            executable = Path(folder) / 'check'
            subprocess.run(['swiftc', '-swift-version', '6',
                str(IOS / 'RuntimeSupport/IridiumRuntime.swift'),
                str(IOS / 'MadeiraFrontend/IridiumArtworkState.swift'),
                str(IOS / 'MadeiraFrontend/IridiumArtworkPresentationPolicy.swift'),
                str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)
