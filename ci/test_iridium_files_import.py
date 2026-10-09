# SPDX-License-Identifier: AGPL-3.0-only
"""Execute the Foundation-only shipping Files importer with synthetic PE files.

No Wine, game data, signing, device state, or Apple UI framework is needed.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "iridium/apps/ios/MadeiraFrontend/IridiumFilesImport.swift"

HARNESS = r'''
import Foundation

typealias Importer = IridiumFilesImport

// Suspend cooperatively: no executor thread is blocked while the test holds
// the worker between filesystem publication and its UI continuation.
actor PublicationSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@main struct FilesImportChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        precondition(try! condition(), message)
    }

    static func rejects(_ expected: Importer.Failure, _ operation: () throws -> Void) throws {
        do {
            try operation()
            preconditionFailure("Expected \(expected)")
        } catch let error as Importer.Failure {
            require(error == expected, "Expected \(expected), received \(error)")
        }
    }

    static func cancelled(_ operation: () throws -> Void) throws {
        do {
            try operation()
            preconditionFailure("Expected cancellation")
        } catch is CancellationError { }
    }

    static func pe(_ bits: Int = 64, machine: UInt16? = nil) -> Data {
        var data = Data(repeating: 0, count: 512)
        data[0] = 0x4d; data[1] = 0x5a; data[60] = 0x80
        data[128] = 0x50; data[129] = 0x45
        let value = machine ?? (bits == 32 ? 0x14c : 0x8664)
        data[132] = UInt8(value & 255); data[133] = UInt8(value >> 8)
        data[134] = 1 // One section.
        data[148] = bits == 32 ? 224 : 240 // Optional-header size.
        data[150] = 2 // Executable image, not a DLL.
        data[152] = 0x0b; data[153] = bits == 32 ? 1 : 2
        return data
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("iridium-files-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Selected Game")
        let drive = root.appendingPathComponent("drive_c")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        func put(_ relative: String, _ data: Data = Data("dependency".utf8), in folder: URL? = nil) throws -> URL {
            let url = (folder ?? source).appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func children(_ folder: URL) throws -> [String] {
            if !fm.fileExists(atPath: folder.path) { return [] }
            return try fm.contentsOfDirectory(atPath: folder.path).sorted()
        }
        func noStaging() throws {
            require(try children(drive).filter { $0.hasPrefix(".iridium-files-import-") }.isEmpty, "Staging must be removed")
        }
        func staging() -> URL? {
            let name = (try? fm.contentsOfDirectory(atPath: drive.path))?.first { $0.hasPrefix(".iridium-files-import-") }
            return name.map { drive.appendingPathComponent($0) }
        }

        switch CommandLine.arguments[1] {
        case "folder":
            let executable = try put("bin/My_Game.exe", pe())
            let library = try put("bin/runtime.dll")
            let asset = try put("data/level.dat", Data([1, 2, 3]))
            let save = try put("saves/slot1.sav", Data("original save".utf8))
            let saveDate = Date(timeIntervalSince1970: 1_600_000_000)
            try fm.setAttributes([.modificationDate: saveDate], ofItemAtPath: save.path)
            let existing = try put("users/madeira/Saved Games/Existing/slot1.sav", Data("existing save".utf8), in: drive)
            let existingImport = try put("Imported/existing/game.exe", pe(32), in: drive)
            let result = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: source)
            require(result.bits == 64 && result.title == "My Game", "PE bits and display title")
            require(result.copiedContainingFolder, "Explicit folder retains dependencies")
            require(result.importID != nil, "New copied import has an ID")
            let copied = drive.appendingPathComponent("Imported/" + result.importID!.uuidString)
            require(result.relativePath == "Imported/" + result.importID!.uuidString + "/bin/My_Game.exe", "Nested EXE path preserved")
            for (original, relative) in [(executable, "bin/My_Game.exe"), (library, "bin/runtime.dll"), (asset, "data/level.dat"), (save, "saves/slot1.sav")] {
                require(try Data(contentsOf: original) == Data(contentsOf: copied.appendingPathComponent(relative)), "Original and copied bytes differ")
            }
            require(try Data(contentsOf: existing) == Data("existing save".utf8), "Existing save was changed")
            require(try Data(contentsOf: existingImport) == pe(32), "Existing import was changed")
            require(try fm.attributesOfItem(atPath: save.path)[.modificationDate] as? Date == saveDate, "Source save date changed")
            require(try fm.attributesOfItem(atPath: copied.appendingPathComponent("saves/slot1.sav").path)[.modificationDate] as? Date == saveDate, "Copied save was incorrectly dated as new")
            require(try children(source) == ["bin", "data", "saves"], "Source tree was modified")
            try noStaging()

        case "standalone":
            let executable = try put("Only.exe", pe(32))
            let sibling = try put("private.txt", Data("unrelated".utf8))
            let result = try Importer.importExecutable(at: executable, drive: drive)
            require(result.bits == 32 && !result.copiedContainingFolder, "Standalone result")
            let copied = drive.appendingPathComponent(result.relativePath).deletingLastPathComponent()
            require(try children(copied) == ["Only.exe"], "File grant must not copy siblings")
            require(try Data(contentsOf: sibling) == Data("unrelated".utf8), "Sibling changed")
            let folder = root.appendingPathComponent("drive_c_other")
            let outside = try put("outside.exe", pe(), in: folder)
            let other = try Importer.importExecutable(at: outside, drive: drive)
            require(other.importID != nil, "Path-prefix sibling must be copied, not treated as in-drive")
            try noStaging()

        case "identity":
            let relative = "Games/Nested/Café Game.EXE"
            let executable = try put(relative, pe(), in: drive)
            for _ in 0..<2 {
                let result = try Importer.importExecutable(at: executable, drive: drive)
                require(result.relativePath == relative && result.importID == nil, "In-drive identity and spelling preserved")
                require(!result.copiedContainingFolder && result.bits == 64, "In-drive result")
            }
            require(try children(drive) == ["Games"], "In-drive selection must not create imports or staging")
            require(try Data(contentsOf: executable) == pe(), "In-drive file changed")

        case "candidates":
            let a = try put("a.exe", pe(32))
            let b = try put("bin/z.EXE", pe())
            _ = try put("not-pe.exe", Data("not PE".utf8))
            _ = try put("arm.exe", pe(machine: 0xaa64))
            _ = try put("unrelated.rom")
            let found = try Importer.executableCandidates(in: source)
            require(found == [a, b], "Only supported PE files, sorted by relative path")
            require(!fm.fileExists(atPath: drive.path), "Candidate enumeration does not create library files")
            try cancelled { _ = try Importer.executableCandidates(in: source, isCancelled: { true }) }

        case "invalid":
            let executable = try put("game.exe", Data("not PE".utf8))
            try rejects(.invalidExecutable) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            try pe(machine: 0xaa64).write(to: executable)
            try rejects(.unsupportedArchitecture) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            var malformed = pe(); malformed[153] = 1
            try malformed.write(to: executable)
            try rejects(.invalidExecutable) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            malformed = pe(); malformed[151] = 0x20
            try malformed.write(to: executable)
            try rejects(.invalidExecutable) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            malformed = pe(); malformed[63] = 0xff
            try malformed.write(to: executable)
            try rejects(.invalidExecutable) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            try pe().prefix(154).write(to: executable)
            try rejects(.invalidExecutable) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            let directory = source.appendingPathComponent("folder.exe")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try rejects(.notRegularFile) { _ = try Importer.importExecutable(at: directory, drive: drive) }
            try pe().write(to: executable)
            let elsewhere = root.appendingPathComponent("Other Folder")
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try rejects(.outsideFolder) { _ = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: elsewhere) }
            try rejects(.outsideFolder) { _ = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: root) }
            for name in ["bad\\name.exe", "bad:name.exe", "NUL.exe"] {
                let invalid = try put(name, pe())
                try rejects(.invalidPath) { _ = try Importer.importExecutable(at: invalid, drive: drive) }
            }
            require(!fm.fileExists(atPath: drive.path), "Rejected inputs must not publish or create folders")

        case "symlinks":
            let executable = try put("real/game.exe", pe())
            let link = source.appendingPathComponent("linked.exe")
            try fm.createSymbolicLink(at: link, withDestinationURL: executable)
            try rejects(.symbolicLink) { _ = try Importer.importExecutable(at: link, drive: drive) }
            let ancestor = source.appendingPathComponent("linked-folder")
            try fm.createSymbolicLink(at: ancestor, withDestinationURL: executable.deletingLastPathComponent())
            try rejects(.symbolicLink) { _ = try Importer.importExecutable(at: ancestor.appendingPathComponent("game.exe"), drive: drive) }
            try rejects(.symbolicLink) { _ = try Importer.executableCandidates(in: source) }
            try rejects(.symbolicLink) { _ = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: source) }
            let dangling = source.appendingPathComponent("missing.exe")
            try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
            try rejects(.symbolicLink) { _ = try Importer.importExecutable(at: dangling, drive: drive) }
            let outside = root.appendingPathComponent("untouched")
            try fm.createDirectory(at: outside, withIntermediateDirectories: false)
            try fm.createDirectory(at: drive, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: drive.appendingPathComponent("Imported"), withDestinationURL: outside)
            try rejects(.symbolicLink) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            require(try children(outside).isEmpty, "Destination link must not redirect writes")
            require(try Data(contentsOf: executable) == pe(), "Symlink rejection changed source")
            try fm.removeItem(at: drive.appendingPathComponent("Imported")) // Remove this fixture's link only.
            let conflicting = drive.appendingPathComponent("Imported")
            try Data("do not replace".utf8).write(to: conflicting)
            try rejects(.conflictingPath) { _ = try Importer.importExecutable(at: executable, drive: drive) }
            require(try Data(contentsOf: conflicting) == Data("do not replace".utf8), "An existing file was replaced by a directory")
            try noStaging()

        case "limits":
            let executable = try put("game.exe", pe())
            _ = try put("data/level.dat", Data(repeating: 3, count: 4096))
            var limits = Importer.Limits()
            limits.maximumEntries = 1
            try rejects(.tooManyFiles) { _ = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: source, limits: limits) }
            limits = .init(); limits.maximumBytes = 511
            try rejects(.tooLarge) { _ = try Importer.importExecutable(at: executable, drive: drive, limits: limits) }
            try rejects(.tooLarge) { _ = try Importer.executableCandidates(in: source, limits: limits) }
            limits = .init(); limits.maximumExecutables = 0
            try rejects(.tooManyExecutables) { _ = try Importer.executableCandidates(in: source, limits: limits) }
            limits = .init(); limits.maximumEntries = 0
            try rejects(.tooManyFiles) { _ = try Importer.importExecutable(at: executable, drive: drive, limits: limits) }
            require(!fm.fileExists(atPath: drive.path), "Limits are checked before writing")

        case "cancel":
            let executable = try put("game.exe", pe())
            let dependency = try put("a-large.dat", Data(repeating: 7, count: 4 * 1024 * 1024))
            let existing = try put("Imported/existing/keep.sav", Data("keep".utf8), in: drive)
            try cancelled { _ = try Importer.importExecutable(at: executable, drive: drive, isCancelled: { true }) }
            var didCancelCopy = false
            try cancelled {
                _ = try Importer.importExecutable(at: executable, drive: drive, sourceRoot: source, isCancelled: {
                    guard let folder = staging(),
                          let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("a-large.dat").path),
                          let bytes = attrs[.size] as? NSNumber, bytes.intValue >= 1024 * 1024 else { return false }
                    didCancelCopy = true
                    return true
                })
            }
            require(didCancelCopy, "Cancellation was exercised within one large file")
            try noStaging()
            require(try children(drive.appendingPathComponent("Imported")) == ["existing"], "Cancelled import was published")
            require(try Data(contentsOf: existing) == Data("keep".utf8), "Cancellation deleted existing import")
            require(try Data(contentsOf: dependency) == Data(repeating: 7, count: 4 * 1024 * 1024), "Cancellation altered source")
            var completeReads = 0
            try cancelled {
                _ = try Importer.importExecutable(at: executable, drive: drive, isCancelled: {
                    guard let folder = staging(),
                          let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("game.exe").path),
                          (attrs[.size] as? NSNumber)?.intValue == 512 else { return false }
                    completeReads += 1
                    return completeReads == 2 // EOF has been read; final publication check.
                })
            }
            require(completeReads == 2, "Cancellation at publication boundary was exercised")
            try noStaging()
            require(try children(drive.appendingPathComponent("Imported")) == ["existing"], "Final cancellation published import")

        case "changed":
            let executable = try put("game.exe", pe())
            var changed = false
            try rejects(.sourceChanged) {
                _ = try Importer.importExecutable(at: executable, drive: drive, isCancelled: {
                    if !changed, staging() != nil {
                        changed = true
                        try! Data(repeating: 1, count: 600).write(to: executable)
                    }
                    return false
                })
            }
            require(changed, "Source mutation was exercised")
            require(try children(drive.appendingPathComponent("Imported")).isEmpty, "Changed input was published")
            try noStaging()

        case "publication":
            let executable = try put("game.exe", pe())
            let originalSave = try put("keep.sav", Data("original save".utf8))
            let existing = try put("Imported/existing/keep.sav", Data("existing save".utf8), in: drive)
            let pending = Importer.Publication()
            require(pending.cancel(), "Cancellation should win before acceptance")
            try cancelled {
                _ = try Importer.importExecutable(at: executable, drive: drive, publication: pending)
            }
            require(!pending.isAccepted, "Cancelled gate was accepted")
            require(try children(drive.appendingPathComponent("Imported")) == ["existing"], "Pre-commit cancellation published files")

            let beforeMove = Importer.Publication()
            var cancellationWon = false
            try cancelled {
                _ = try Importer.importExecutable(at: executable, drive: drive, publication: beforeMove, isCancelled: {
                    if !cancellationWon, let folder = staging(),
                       let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("game.exe").path),
                       (attrs[.size] as? NSNumber)?.intValue == 512 {
                        cancellationWon = beforeMove.cancel()
                    }
                    return false // Gate cancellation must work independently.
                })
            }
            require(cancellationWon && !beforeMove.isAccepted, "Cancellation must win while files are still staged")
            require(try children(drive.appendingPathComponent("Imported")) == ["existing"], "Cancelled gate published a staged copy")
            try noStaging()

            // Hold a real worker after its move but before its awaited result
            // can reach the publication continuation, then cancel that task.
            let accepted = Importer.Publication()
            let moved = PublicationSignal()
            let resume = PublicationSignal()
            let record = root.appendingPathComponent("synthetic-library-entry.txt")
            let continuation = Task.detached {
                let worker = Task.detached {
                    let result = try Importer.importExecutable(at: executable, drive: drive,
                        publication: accepted, isCancelled: { Task.isCancelled })
                    await moved.signal()
                    await resume.wait()
                    return result
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { if accepted.cancel() { worker.cancel() } }
                // This mirrors the UI handoff: accepted publication is saved
                // without a post-result cancellation check or deletion.
                try Data(result.relativePath.utf8).write(to: record, options: .atomic)
                return result
            }
            await moved.wait() // The subprocess has a bounded 30-second timeout.
            require(accepted.isAccepted, "Move must have an accepted commit")
            continuation.cancel()
            require(!accepted.cancel(), "Cancellation must not discard an accepted move")
            await resume.signal()
            let result = try await continuation.value
            require(continuation.isCancelled, "The cancelled continuation race was not exercised")
            let originalPresentation = UUID(), newerPresentation = UUID()
            var presented: UUID? = newerPresentation
            var selected: UUID?
            // Persistence above completes even though a newer picker has taken
            // ownership. The old UI callback must neither select nor dismiss it.
            if Importer.shouldPresentCompletion(of: originalPresentation, currentSourceID: presented) {
                selected = result.importID; presented = nil
            }
            require(presented == newerPresentation && selected == nil, "Stale import dismissed a newer Files sheet")
            require(!Importer.shouldPresentCompletion(of: originalPresentation, currentSourceID: nil),
                    "A closed Files sheet regained presentation ownership")
            if Importer.shouldPresentCompletion(of: newerPresentation, currentSourceID: presented) {
                selected = result.importID; presented = nil
            }
            require(presented == nil && selected == result.importID, "Current Files sheet could not finish")
            require(try String(contentsOf: record, encoding: .utf8) == result.relativePath, "Published copy was silently orphaned")
            require(try Data(contentsOf: drive.appendingPathComponent(result.relativePath)) == pe(), "Published EXE was removed")
            require(try Data(contentsOf: executable) == pe(), "Original EXE was changed")
            require(try Data(contentsOf: originalSave) == Data("original save".utf8), "Original save was changed")
            require(try Data(contentsOf: existing) == Data("existing save".utf8), "Existing import was changed")
            try noStaging()

        default:
            preconditionFailure("Unknown test case")
        }
        print("Files import \(CommandLine.arguments[1]) passed")
    }
}
'''


@unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
class IridiumFilesImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="iridium-files-import-checks-")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        harness = directory / "Check.swift"
        harness.write_text(HARNESS)
        cls.executable = directory / "check"
        build = subprocess.run([
            "swiftc", "-swift-version", "6", "-warnings-as-errors",
            "-module-cache-path", str(directory / "module-cache"),
            str(SOURCE), str(harness), "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def check(self, scenario):
        result = subprocess.run([str(self.executable), scenario], capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_folder_keeps_dependencies_and_original_saves(self):
        self.check("folder")

    def test_single_file_scope_does_not_copy_siblings(self):
        self.check("standalone")

    def test_in_drive_relative_path_and_identity_are_preserved(self):
        self.check("identity")

    def test_folder_candidates_are_sorted_supported_executables(self):
        self.check("candidates")

    def test_malformed_pe_and_unsafe_relative_paths_are_rejected(self):
        self.check("invalid")

    def test_source_and_destination_symlinks_are_rejected(self):
        self.check("symlinks")

    def test_file_count_size_and_candidate_limits_are_enforced(self):
        self.check("limits")

    def test_mid_file_and_pre_publication_cancel_remove_only_staging(self):
        self.check("cancel")

    def test_source_changes_abort_before_publication(self):
        self.check("changed")

    def test_cancelled_continuation_finishes_an_accepted_publication(self):
        self.check("publication")


if __name__ == "__main__":
    unittest.main()
