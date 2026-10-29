# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise Steam discovery and launch validation against real filesystem changes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
STEAM = ROOT / 'iridium/apps/ios/App/Steam'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class SteamInstallPresenceTests(unittest.TestCase):
    def test_stale_install_record_does_not_make_missing_files_ready(self):
        source = (STEAM / 'MadeiraDock.swift').read_text().split('    // MARK: Sign-in transfer')[0] + '}\n'
        with tempfile.TemporaryDirectory(prefix='iridium-steam-presence-') as directory:
            root = Path(directory)
            (root / 'Dock.swift').write_text(source)
            (root / 'Check.swift').write_text(r'''import Foundation
enum SteamSignIn { static func flag(_ key: String, default value: Bool) -> Bool { value } }
enum SteamRuntimeFiles { static let relativeRoot = "SteamClient" }
@main struct Check {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let drive = root.appendingPathComponent("Documents/wine/drive_c")
        let apps = drive.appendingPathComponent("SteamClient/steamapps")
        let install = apps.appendingPathComponent("common/Half-Life 2")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let record = apps.appendingPathComponent("appmanifest_220.acf")
        let manifest = Data(#"""
        "AppState" { "appid" "220" "name" "Half-Life 2" "StateFlags" "4" "installdir" "Half-Life 2" }
        """#.utf8)
        try manifest.write(to: record)
        func game() -> DockGame { MadeiraDock.games(drive: drive).first! }
        precondition(!game().installed && game().filesMissing == true)
        try fm.createDirectory(at: install, withIntermediateDirectories: true)
        precondition(!game().installed && game().filesMissing == true)
        try Data("game file".utf8).write(to: install.appendingPathComponent("hl2.exe"))
        precondition(game().installed && game().filesMissing == false)
        let moved = root.appendingPathComponent("Documents/Games/Half-Life 2 - " + UUID().uuidString)
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: install, to: moved)
        try fm.createSymbolicLink(at: install, withDestinationURL: moved)
        precondition(game().installed)
        let client = drive.appendingPathComponent("SteamClient/steamclient64.dll")
        try Data("client fixture".utf8).write(to: client)
        let captured = game()
        try MadeiraDock.validate(captured, drive: drive, bundled: true)
        let partial = apps.appendingPathComponent("downloading/220")
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        precondition(!game().installed)
        do { try MadeiraDock.validate(captured, drive: drive, bundled: true); preconditionFailure("An unfinished repair cannot launch") }
        catch { }
        try fm.removeItem(at: partial)
        try fm.removeItem(at: moved)
        precondition(!game().installed && game().filesMissing == true)
        do {
            try MadeiraDock.validate(captured, drive: drive, bundled: true)
            preconditionFailure("Launch must recheck files after discovery")
        } catch { precondition(error.localizedDescription.contains("Repair")) }
        let kept = try Data(contentsOf: record)
        precondition(kept == manifest)
        let old = #"{"id":220,"name":"Half-Life 2","installDir":"Half-Life 2","library":"SteamClient/steamapps","installed":true,"customExecutables":false}"#
        let decoded = try JSONDecoder().decode(DockGame.self, from: Data(old.utf8))
        precondition(decoded.filesMissing == nil)
        let owner = apps.appendingPathComponent("appmanifest_380.acf")
        try Data(#"""
        "AppState" { "appid" "220" "name" "Half-Life 2" "StateFlags" "4" "installdir" "Half-Life 2"
        "InstalledDepots" { "221" { "manifest" "1" } } "SharedDepots" { "380" "380" } }
        """#.utf8).write(to: record)
        try Data(#"""
        "AppState" { "appid" "380" "name" "Episode One" "StateFlags" "4" "installdir" "Half-Life 2"
        "InstalledDepots" { "380" { "manifest" "2" } } }
        """#.utf8).write(to: owner)
        precondition(MadeiraDock.games(drive: drive).map(\.id) == [220])
        precondition(MadeiraDock.games(drive: drive, includeSharedOnly: true).first { $0.id == 380 }?.sharedOnly == true)
        precondition(!SteamInstallFiles.delete(appID: 380, folderName: "Half-Life 2", steamApps: apps))
        precondition(fm.fileExists(atPath: owner.path))
        try fm.removeItem(at: install)
        let save = root.appendingPathComponent("keep-save.dat")
        try Data("saved progress".utf8).write(to: save)
        precondition(SteamInstallFiles.delete(appID: 220, folderName: "Half-Life 2", steamApps: apps))
        precondition(!fm.fileExists(atPath: record.path) && !fm.fileExists(atPath: owner.path))
        let saved = try Data(contentsOf: save)
        precondition(saved == Data("saved progress".utf8))
        try fm.createDirectory(at: install, withIntermediateDirectories: true)
        try Data("game".utf8).write(to: install.appendingPathComponent("hl2.exe"))
        precondition(SteamInstallFiles.delete(appID: 220, folderName: "Half-Life 2", steamApps: apps))
        precondition(!fm.fileExists(atPath: install.path))
        try fm.createSymbolicLink(at: install, withDestinationURL: save)
        precondition(!SteamInstallFiles.delete(appID: 220, folderName: "Half-Life 2", steamApps: apps))
        precondition(fm.fileExists(atPath: save.path))
        precondition(!SteamInstallFiles.delete(appID: 220, folderName: "../keep-save.dat", steamApps: apps))
        let generic = apps.appendingPathComponent("appmanifest_9000.acf")
        let tools = apps.appendingPathComponent("appmanifest_7000.acf")
        try Data(#"""
        "AppState" { "appid" "9000" "name" "Any Game" "StateFlags" "4" "installdir" "Any Game"
        "InstalledDepots" { "9001" { "manifest" "1" } } "SharedDepots" { "7001" "7000" } }
        """#.utf8).write(to: generic)
        try Data(#"""
        "AppState" { "appid" "7000" "name" "Shared Content" "StateFlags" "4" "installdir" "Shared Content"
        "InstalledDepots" { "7001" { "manifest" "2" } } }
        """#.utf8).write(to: tools)
        precondition(MadeiraDock.games(drive: drive).map(\.id) == [9000])
        try Data(#"""
        "AppState" { "appid" "7000" "name" "Independent Game" "StateFlags" "4" "installdir" "Independent Game"
        "InstalledDepots" { "7001" { "manifest" "2" } "7002" { "manifest" "3" } } }
        """#.utf8).write(to: tools)
        precondition(Set(MadeiraDock.games(drive: drive).map(\.id)) == [7000,9000])
    }
}
''')
            binary = root / 'check'
            built = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-module-cache-path', module_cache('macosx'), str(STEAM.parent.parent / 'RuntimeSupport/IridiumRuntime.swift'),
                str(STEAM.parent.parent / 'RuntimeSupport/IridiumGameStorage.swift'), str(STEAM / 'SteamInstall.swift'), str(STEAM / 'SteamKeyValues.swift'),
                str(root / 'Dock.swift'), str(root / 'Check.swift'), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)

    def test_library_removal_survives_refresh_and_restart_and_can_be_reversed(self):
        service = (STEAM.parent / 'Adapters/Madeira/IridiumWindowsLibraryService.swift').read_text()
        methods = service[service.index('    func save(_ entry:'):service.index('    /// Install size and graphics API')]
        document = next(line.strip().replace('private struct', 'struct') for line in service.splitlines() if 'private struct Document:' in line)
        detail = (STEAM.parent / 'Library/IridiumWindowsScreens.swift').read_text().split('struct LibraryDetail: View {', 1)[1]
        navigation = detail[detail.index('    private func iridiumNavigate('):detail.index('    var play:')].replace('private func', 'func')
        dock = (STEAM / 'MadeiraDock.swift').read_text().split('    // MARK: Sign-in transfer')[0] + '}\n'
        fixture = r'''import Foundation
struct LibraryEntry: Codable {
    var id = UUID(), steamAppID: Int? = nil
    var title: String, relativePath: String, bits: Int
    var folderBytes: Int64? = nil, graphicsAPI: String? = nil, steamMetadataInstall: String? = nil
    var metadataChecked: Date? = nil, metadataRevision: Int? = nil
    var desktop: Bool? = nil
}
enum GameRecommendations { static func prepare(_ entry: inout LibraryEntry, new: Bool) {} }
enum SteamSignIn { static func flag(_ key: String, default value: Bool) -> Bool { value } }
enum SteamRuntimeFiles { static let relativeRoot = "SteamClient" }
enum SteamInstallPaths { static let libraryRelative = "Program Files (x86)/Steam/steamapps" }
enum SteamInstallFiles { static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? { nil } }
@MainActor final class SteamGamesModel {
    static let shared = SteamGamesModel()
    var games: [DockGame] = [], sharedOnlyApps: Set<Int> = []
}
@MainActor final class IridiumImportCoordinator {
    static let shared = IridiumImportCoordinator(); var blocksLaunch = false
}
enum IridiumFavoriteButton { static func toggle(_ entry: LibraryEntry) {} }
@MainActor final class LibraryModel {
    DOCUMENT
    static var drive: URL { FileManager.default.temporaryDirectory }
    var readOnly = false, entries: [LibraryEntry] = [], hiddenSteamApps: Set<Int> = [], error: String?
    var current: UUID?; var launching = false
    let file: URL
    init(_ file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            entries = doc.entries; hiddenSteamApps = Set(doc.hiddenSteamApps ?? [])
        }
    }
    METHODS
}
@MainActor final class Navigation {
    var entry: LibraryEntry, model: LibraryModel
    var iridiumPages: [String] = [], iridiumFocus = "Controls", iridiumGuided = false, remove = false
    init(_ entry: LibraryEntry, model: LibraryModel) { self.entry = entry; self.model = model }
    func dismiss() {}
    NAVIGATION
}
@main @MainActor struct Check {
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        try Data(#"{"version":1,"entries":[]}"#.utf8).write(to: file)
        let model = try LibraryModel(file)
        var entry = LibraryEntry(title: "HL2", relativePath: SteamInstallPaths.libraryRelative + "/common/Half-Life 2", bits: 64)
        entry.steamAppID = 220; entry.graphicsAPI = "D3D9"
        model.save(entry); model.remove(entry.id)
        precondition(model.hiddenSteamApps == [220] && model.entries.first?.id == entry.id)
        model.save(entry)
        let reopened = try LibraryModel(file)
        precondition(reopened.hiddenSteamApps == [220] && reopened.entries.first?.graphicsAPI == "D3D9")
        let missing = reopened.steamInstall(entry)!
        precondition(missing.id == 220 && !missing.installed)
        reopened.upsertSteam(missing, title: entry.title)
        precondition(reopened.hiddenSteamApps.isEmpty && reopened.entries.first?.id == entry.id)
        let navigation = Navigation(entry, model: reopened)
        navigation.iridiumNavigate("up")
        precondition(navigation.iridiumFocus == "Library Entry")
        navigation.iridiumNavigate("accept")
        precondition(navigation.remove && navigation.iridiumPages.isEmpty)
        reopened.remove(entry.id); navigation.remove = false
        navigation.iridiumNavigate("accept")
        precondition(reopened.hiddenSteamApps.isEmpty && !navigation.remove)
        IridiumImportCoordinator.shared.blocksLaunch = true
        navigation.iridiumNavigate("accept")
        precondition(!navigation.remove)
        IridiumImportCoordinator.shared.blocksLaunch = false
        var plain = LibraryEntry(title: "Other", relativePath: "Imported/game.exe", bits: 64)
        plain.graphicsAPI = "Vulkan"; reopened.save(plain); reopened.remove(plain.id)
        precondition(!reopened.entries.contains { $0.id == plain.id })
        SteamGamesModel.shared.sharedOnlyApps = [220]
        precondition(reopened.steamInstall(entry) == nil)
        SteamGamesModel.shared.sharedOnlyApps = []
        reopened.hideSteam([340, 380, 420])
        let rescanned = try LibraryModel(file)
        precondition(rescanned.hiddenSteamApps == [340, 380, 420])
        var support = entry; support.steamAppID = 380; support.id = UUID()
        rescanned.save(support)
        precondition(rescanned.entries.count == 1)
        var unsafe = entry; unsafe.relativePath = "../../Other"
        precondition(reopened.steamInstall(unsafe) == nil)
        reopened.removeSteam(appID: 220)
        let removed = try LibraryModel(file)
        precondition(removed.entries.first?.id == entry.id && removed.hiddenSteamApps == [220, 340, 380, 420])
        removed.save(entry)
        precondition(removed.entries.count == 1 && removed.hiddenSteamApps == [220, 340, 380, 420])
        let failed = try LibraryModel(root.appendingPathComponent("missing/library.json"))
        failed.entries = [entry]; failed.remove(entry.id)
        precondition(failed.hiddenSteamApps.isEmpty && failed.entries.count == 1 && failed.error != nil)
    }
}
'''.replace('DOCUMENT', document).replace('METHODS', methods).replace('NAVIGATION', navigation)
        with tempfile.TemporaryDirectory(prefix='iridium-library-removal-') as directory:
            root = Path(directory)
            (root / 'Dock.swift').write_text(dock)
            (root / 'Check.swift').write_text(fixture)
            built = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-module-cache-path', module_cache('macosx'), str(STEAM / 'SteamKeyValues.swift'),
                str(root / 'Dock.swift'), str(root / 'Check.swift'), '-o', str(root / 'check')],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(root / 'check')], capture_output=True, text=True, timeout=30)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)

    def test_uninstall_waits_for_the_writer_and_locks_runtime_admission(self):
        source = (STEAM / 'SteamOwnedLibrary.swift').read_text()
        pause = source[source.index('    func pause(_ appID:'):source.index('    /// Stops a download.')]
        uninstall = source[source.index('    func uninstall(_ game:'):source.index('    func resumeDownloadsAfterImport()')]
        dock = (STEAM / 'MadeiraDock.swift').read_text().split('    // MARK: Sign-in transfer')[0] + '}\n'
        fixture = r'''import Foundation
enum SteamSignIn { static func flag(_ key: String, default value: Bool) -> Bool { value } }
enum SteamRuntimeFiles { static let relativeRoot = "SteamClient" }
enum SteamLog { static func event(_ value: String) {} }
enum DockInstallers { static func setRunsNext(_ id: Int, _ value: Bool, prefix: URL) {} }
@MainActor final class LibraryModel {
    static let shared = LibraryModel()
    var writerFinished = false, failSave = false, removed: [Int] = []
    func removeSteam(appID: Int) -> Bool {
        precondition(writerFinished && IridiumImportCoordinator.shared.blocksLaunch)
        if failSave { return false }
        removed.append(appID); return true
    }
}
@MainActor final class SteamGamesModel {
    static let shared = SteamGamesModel()
    func refresh() {}
}
@MainActor final class IridiumImportCoordinator {
    static let shared = IridiumImportCoordinator()
    var blocksLaunch = false, launchMessage = "Busy"
    func beginLibraryTransfer() throws {
        precondition(LibraryModel.shared.writerFinished)
        blocksLaunch = true
    }
    func endLibraryTransfer() { blocksLaunch = false }
}
@MainActor final class Host {
    struct Download { enum State { case paused, active }; var state: State }
    static var steamApps = URL(fileURLWithPath: "/unused")
    var active: (id: Int, task: Task<Void, Never>)?
    var downloads: [Int: Download] = [:], queue: [Int] = [], resumeAfterSession: Set<Int> = []
    var inSession = false, error: String?
    PAUSE
    UNINSTALL
}
@main @MainActor struct Check {
    static func main() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        Host.steamApps = root.appendingPathComponent("Documents/wine/drive_c/" + SteamInstallPaths.libraryRelative)
        let gameFolder = Host.steamApps.appendingPathComponent("common/Test")
        try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        let game = DockGame(id: 9000, name: "Test", installDir: "Test", library: SteamInstallPaths.libraryRelative, installed: true, customExecutables: false)
        let model = Host()
        model.active = (9000, Task {
            while !Task.isCancelled { await Task.yield() }
            await Task.yield()
            try! Data("last write".utf8).write(to: gameFolder.appendingPathComponent("game.exe"))
            LibraryModel.shared.writerFinished = true
        })
        model.downloads[9000] = .init(state: .active)
        let removed = await model.uninstall(game)
        precondition(removed && LibraryModel.shared.removed == [9000])
        precondition(!fm.fileExists(atPath: gameFolder.path) && !IridiumImportCoordinator.shared.blocksLaunch)
        try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        IridiumImportCoordinator.shared.blocksLaunch = true
        let blocked = await model.uninstall(game)
        precondition(!blocked && fm.fileExists(atPath: gameFolder.path))
        IridiumImportCoordinator.shared.blocksLaunch = false
        model.inSession = true
        let inSession = await model.uninstall(game)
        precondition(!inSession && fm.fileExists(atPath: gameFolder.path))
        model.inSession = false; LibraryModel.shared.failSave = true
        let failedSave = await model.uninstall(game)
        precondition(!failedSave && model.error?.contains("library") == true && !IridiumImportCoordinator.shared.blocksLaunch)
    }
}
'''.replace('PAUSE', pause).replace('UNINSTALL', uninstall)
        with tempfile.TemporaryDirectory(prefix='iridium-uninstall-writer-') as directory:
            root = Path(directory)
            (root / 'Dock.swift').write_text(dock)
            (root / 'Check.swift').write_text(fixture)
            ios = STEAM.parent.parent
            built = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-module-cache-path', module_cache('macosx'), str(STEAM / 'SteamKeyValues.swift'),
                str(STEAM / 'SteamInstall.swift'), str(ios / 'RuntimeSupport/IridiumRuntime.swift'),
                str(ios / 'RuntimeSupport/IridiumGameStorage.swift'), str(root / 'Dock.swift'),
                str(root / 'Check.swift'), '-o', str(root / 'check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(root / 'check')], capture_output=True, text=True, timeout=30)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
