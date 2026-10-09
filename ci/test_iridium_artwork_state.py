"""Execute the shipping Foundation-only artwork store and matcher with Swift.

The fixture uses synthetic metadata and delayed local completions. It does not
download artwork, compile an emulator, or claim device/UI validation.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'

CHECKS = r'''
import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

func reject(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(message) } catch { }
}

actor CompletionGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

@main struct ArtworkChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("iridium-artwork-checks-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("artwork")
        let store = try IridiumArtworkStore(root: root)
        let id = UUID()
        let candidate = IridiumArtworkCandidate(id: "sample-region", title: "Sample (USA)",
                                                platform: .gameBoy, source: "fixture")
        expect(store.appearance(id).automaticLookup, "new games should opt into lookup")
        expect(store.appearance(id) == store.appearance(id), "unstored defaults must be stable")
        expect(!fm.fileExists(atPath: root.path), "read-only initialization created files")
        let prepared = try store.prepareImageURL("first.jpg")
        try Data("synthetic image".utf8).write(to: prepared, options: .atomic)
        expect(fm.fileExists(atPath: prepared.path), "image write could not create fresh cache root")
        expect(!fm.fileExists(atPath: root.appendingPathComponent("appearance.json").path),
               "preparing image URL wrote metadata before commit")

        // Store presentation for different runtimes together; their input and
        // save files live elsewhere and must remain byte-for-byte unchanged.
        let gameFile = temporary.appendingPathComponent("game.gb")
        let saveFile = temporary.appendingPathComponent("save.sav")
        try Data("synthetic game".utf8).write(to: gameFile)
        try Data("synthetic save".utf8).write(to: saveFile)
        let ticket = store.begin(id)!
        expect(try store.apply(candidate, coverName: "cover.jpg", backgroundName: "background.jpg", ticket: ticket),
               "fresh result was rejected")
        expect(!(try store.apply(candidate, coverName: "duplicate.jpg", backgroundName: nil, ticket: ticket)),
               "ticket must commit at most once")
        try store.update(id) { $0.title = "My title"; $0.coverY = 0.23; $0.backgroundY = 0.81 }
        let windowsID = UUID()
        let windows = IridiumArtworkCandidate(id: "123", title: "Windows Sample", platform: .windows, source: "steam")
        expect(try store.apply(windows, coverName: nil, backgroundName: nil, ticket: store.begin(windowsID)!),
               "Windows string ID failed")
        let pspID = UUID()
        try store.update(pspID) {
            $0.match = IridiumArtworkMatch(id: "PSP sample.png", title: "PSP Sample", platform: .psp, source: "libretro")
        }
        let reloaded = try IridiumArtworkStore(root: root)
        expect(reloaded.entries == store.entries, "round-trip lost identity, crop, title, flags, or revision")
        let oldInstanceTicket = store.begin(id)!
        expect(!(try reloaded.apply(candidate, coverName: "restarted.jpg", backgroundName: nil, ticket: oldInstanceTicket)),
               "reopened store accepted another instance's pending request")
        store.cancel(oldInstanceTicket)
        expect(try Data(contentsOf: gameFile) == Data("synthetic game".utf8), "artwork changed game data")
        expect(try Data(contentsOf: saveFile) == Data("synthetic save".utf8), "artwork changed save data")
        expect(store.appearance(id).match?.platform == .gameBoy, "platform identity was lost")

        // A delayed network completion cannot win against a later manual edit.
        let manualGate = CompletionGate()
        let manualTicket = store.begin(id)!
        let delayedManual = Task { @MainActor in
            await manualGate.wait()
            return try store.apply(candidate, coverName: "late.jpg", backgroundName: "late-bg.jpg", ticket: manualTicket)
        }
        try store.update(id) { $0.cover = "manual.jpg"; $0.customCover = true; $0.coverY = 0.19 }
        await manualGate.release()
        expect(!(try await delayedManual.value), "delayed lookup overwrote a manual choice")
        expect(store.appearance(id).cover == "manual.jpg" && store.appearance(id).coverY == 0.19,
               "manual artwork or crop changed")

        let removedGate = CompletionGate()
        let removedTicket = store.begin(id)!
        let delayedRemoved = Task { @MainActor in
            await removedGate.wait()
            return try store.apply(candidate, coverName: "removed.jpg", backgroundName: nil, ticket: removedTicket)
        }
        try store.removeMatch(id)
        await removedGate.release()
        expect(!(try await delayedRemoved.value), "removed match was restored by a delayed completion")
        expect(store.appearance(id).match == nil && !store.appearance(id).automaticLookup,
               "remove match did not disable automatic lookup")
        expect(store.appearance(id).cover == "manual.jpg" && store.appearance(id).background == nil,
               "remove match did not preserve only manual images")
        expect(store.begin(id) == nil, "disabled automatic lookup still began")

        let manualSelection = store.begin(id, automatic: false)!
        expect(try store.apply(candidate, coverName: "automatic.jpg", backgroundName: "automatic-bg.jpg", ticket: manualSelection),
               "explicit match could not replace removed match")
        expect(store.appearance(id).automaticLookup, "explicit match failed to reenable future lookup")
        expect(store.appearance(id).cover == "manual.jpg", "explicit match erased a custom cover")

        // Nil with a custom flag means the user deliberately chose no image.
        try store.update(id) { $0.cover = nil; $0.customCover = true; $0.background = nil; $0.customBackground = true }
        expect(try store.apply(candidate, coverName: "unwanted.jpg", backgroundName: "unwanted-bg.jpg", ticket: store.begin(id)!),
               "valid match could not retain empty manual overrides")
        expect(store.appearance(id).cover == nil && store.appearance(id).background == nil,
               "automatic result filled intentionally empty custom images")

        // Repeated requests supersede old tickets, including across revisions
        // that have never been written. Cancelling an old ticket is harmless.
        let newID = UUID()
        let first = store.begin(newID)!
        let second = store.begin(newID)!
        store.cancel(first)
        expect(!(try store.apply(candidate, coverName: "old.jpg", backgroundName: nil, ticket: first)),
               "older request remained valid")
        expect(try store.apply(candidate, coverName: "new.jpg", backgroundName: nil, ticket: second),
               "cancelling older request cancelled the current one")
        let cancelled = store.begin(newID)!
        store.cancel(cancelled)
        expect(!(try store.apply(candidate, coverName: "cancelled.jpg", backgroundName: nil, ticket: cancelled)),
               "explicitly cancelled request committed")

        let taskGate = CompletionGate()
        let cancelledTaskTicket = store.begin(newID)!
        let cancelledTask = Task { @MainActor in
            await taskGate.wait()
            return try store.apply(candidate, coverName: "cancelled-task.jpg", backgroundName: nil, ticket: cancelledTaskTicket)
        }
        cancelledTask.cancel()
        await taskGate.release()
        expect(!(try await cancelledTask.value), "Task cancellation did not reject completion")
        expect(store.appearance(newID).cover == "new.jpg", "cancelled task changed persisted state")

        let priorRevision = store.appearance(newID).revision
        try store.update(newID) { $0.title = "Edited while waiting" }
        expect(store.appearance(newID).revision != priorRevision, "manual edit failed to replace revision")
        let changedMatch = IridiumArtworkCandidate(id: "other", title: "Other", platform: .gameBoy, source: "fixture")
        expect(try store.apply(changedMatch, coverName: nil, backgroundName: nil, ticket: store.begin(newID, automatic: false)!),
               "new explicit match failed")
        expect(store.appearance(newID).cover == nil, "new match retained unrelated automatic artwork")

        // Failures must not publish partially changed in-memory state or disk.
        let previous = store.entries
        let document = root.appendingPathComponent("appearance.json")
        let previousBytes = try Data(contentsOf: document)
        for name in ["../escape.jpg", "/absolute.jpg", "a/b.jpg", "a\\b.jpg", ".", "..", "", "bad\0.jpg", "appearance.json", "%2f.jpg"] {
            reject("invalid path accepted: \(name)") { try store.update(id) { $0.cover = name } }
            reject("invalid image URL returned: \(name)") { _ = try store.imageURL(name) }
        }
        for y in [-0.1, 1.1, Double.nan, Double.infinity] {
            reject("invalid crop accepted") { try store.update(id) { $0.backgroundY = y } }
        }
        let invalidPathTicket = store.begin(id)!
        reject("invalid completion filename accepted despite a manual override") {
            _ = try store.apply(candidate, coverName: "../escape.jpg", backgroundName: nil, ticket: invalidPathTicket)
        }
        expect(store.entries == previous, "failed edit changed memory")
        expect(try Data(contentsOf: document) == previousBytes, "failed edit changed disk")
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked.jpg"), withDestinationURL: saveFile)
        reject("image symlink accepted") { _ = try store.imageURL("linked.jpg") }
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling.jpg"),
                                  withDestinationURL: temporary.appendingPathComponent("missing.jpg"))
        reject("dangling image symlink accepted") { _ = try store.imageURL("dangling.jpg") }
        try fm.createDirectory(at: root.appendingPathComponent("directory.jpg"), withIntermediateDirectories: true)
        reject("directory accepted as image") { _ = try store.imageURL("directory.jpg") }
        let linkedRoot = temporary.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        reject("symlink root accepted") { _ = try IridiumArtworkStore(root: linkedRoot) }
        reject("regular file accepted as root") { _ = try IridiumArtworkStore(root: saveFile) }

        // Independent stale stores cannot silently replace someone else's edit.
        reject("stale writer overwrote current disk") { try reloaded.update(id) { $0.title = "Stale writer" } }
        expect(try Data(contentsOf: document) == previousBytes, "stale writer changed disk")

        for bytes in [Data("broken json".utf8), Data(#"{"version":99,"futureField":true}"#.utf8)] {
            try bytes.write(to: document, options: .atomic)
            reject("corrupt/future document loaded") { _ = try IridiumArtworkStore(root: root) }
            reject("corrupt/future document overwritten") { try store.update(id) { $0.title = "Overwrite" } }
            reject("corrupt/future document allowed cache write") { _ = try store.prepareImageURL("future.jpg") }
            expect(try Data(contentsOf: document) == bytes, "unreadable document was not preserved")
        }
        try previousBytes.write(to: document, options: .atomic)
        try fm.removeItem(at: document)
        try fm.createSymbolicLink(at: document, withDestinationURL: saveFile)
        reject("metadata symlink accepted") { _ = try IridiumArtworkStore(root: root) }
        expect(try Data(contentsOf: saveFile) == Data("synthetic save".utf8), "metadata symlink changed save")

        func game(_ id: String, _ title: String, _ platform: IridiumPlatform = .gameBoy) -> IridiumArtworkCandidate {
            IridiumArtworkCandidate(id: id, title: title, platform: platform, source: "fixture")
        }
        let us = game("us", "Pokemon - Blue Version (USA, Europe)")
        let jp = game("jp", "Pokemon - Blue Version (Japan)")
        expect(IridiumArtworkMatcher.normalized("Pokemon_-_Blue_Version (USA, Europe) (En,Fr) (Rev 1).GB", platform: .gameBoy)
               == "pokemon blue version", "recognized filename tags were not stripped")
        expect(IridiumArtworkMatcher.exactMatch("Pokemon - Blue Version (USA, Europe).gb", platform: .gameBoy,
                                                candidates: [jp, us]) == us, "full regional match was not preferred")
        expect(IridiumArtworkMatcher.exactMatch("Pokemon - Blue Version.gb", platform: .gameBoy,
                                                candidates: [jp, us]) == nil, "ambiguous regional match picked first result")
        expect(IridiumArtworkMatcher.exactMatch("Pokemon - Blue Version.gb", platform: .gameBoy,
                                                candidates: [game("wrong", "Different"), us]) == us, "unique normalized match failed")
        expect(IridiumArtworkMatcher.exactMatch("Missing.gb", platform: .gameBoy, candidates: [us]) == nil,
               "unrelated first result was accepted")
        expect(IridiumArtworkMatcher.exactMatch("Same.gb", platform: .gameBoy,
                                                candidates: [game("a", "Same"), game("b", "Same")]) == nil,
               "duplicate exact titles were not ambiguous")
        expect(IridiumArtworkMatcher.exactMatch("Same.gb", platform: .gameBoy,
                                                candidates: [game("a", "Same"), game("b", "Same (USA)")]) == nil,
               "unqualified title chose a result despite regional ambiguity")
        expect(IridiumArtworkMatcher.exactMatch("Same.gb", platform: .gameBoy,
                                                candidates: [game("a", "Same", .gameBoyColor)]) == nil,
               "cross-platform candidate matched")
        for suffix in ["(The Lost Levels)", "(Disc 1)", "(Beta)", "(Hack)", "(Rev Speed)", "[!]", "(A+)"] {
            expect(IridiumArtworkMatcher.normalized("Sample \(suffix).gb", platform: .gameBoy)
                   != IridiumArtworkMatcher.normalized("Sample.gb", platform: .gameBoy), "unknown tag stripped: \(suffix)")
        }
        expect(IridiumArtworkMatcher.exactMatch("Sample [!].gb", platform: .gameBoy,
                                                candidates: [game("plain", "Sample")]) == nil,
               "punctuation-only qualifier matched an unqualified game")
        expect(IridiumArtworkMatcher.exactMatch("Sample (A+).gb", platform: .gameBoy,
                                                candidates: [game("edition-a", "Sample (A)")]) == nil,
               "meaningful edition punctuation collapsed")
        expect(IridiumArtworkMatcher.query("Sample.exe.gb", platform: .gameBoy) == "Sample.exe",
               "extension removal was recursive")
        expect(IridiumArtworkMatcher.query("Sample.iso", platform: .gameBoy) == "Sample.iso",
               "another platform's extension was removed")
        expect(IridiumArtworkMatcher.query("C:\\Games\\Sample.EXE", platform: .windows) == "Sample",
               "Windows executable basename was not normalized")
        expect(IridiumArtworkMatcher.query("Sample (Europe) (v1.2).CSO", platform: .psp) == "Sample",
               "PSP extension or recognized revision was not removed")
        expect(IridiumArtworkMatcher.query(" Sample (Europe).gb ", platform: .gameBoy) == "Sample",
               "surrounding whitespace blocked extension handling")
        expect(IridiumArtworkMatcher.exactMatch(String(repeating: "x", count: 2049), platform: .gameBoy,
                                                candidates: [us]) == nil, "oversized title did not fail closed")
        print("Artwork state: persistence, manual overrides, delayed stale/cancelled completions, safe paths, and exact matching passed")
    }
}
'''


class IridiumArtworkStateTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for production artwork state execution')
    def test_production_artwork_state(self):
        with tempfile.TemporaryDirectory(prefix='iridium-artwork-host-') as temporary:
            folder = Path(temporary)
            fixture = folder / 'ArtworkChecks.swift'
            fixture.write_text(CHECKS)
            executable = folder / 'artwork-checks'
            subprocess.run([
                'swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', str(folder / 'module-cache'),
                str(IOS / 'RuntimeSupport/IridiumRuntime.swift'),
                str(IOS / 'MadeiraFrontend/IridiumArtworkState.swift'),
                str(fixture), '-o', str(executable),
            ], check=True, timeout=180)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
