"""Store deletion must not follow unowned links or lose moved game files."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class StoreFileTests(unittest.TestCase):
    def test_game_move_copy_preserves_originals_on_conflict_or_changes(self):
        source = (IOS / 'App/Storage/ExternalDrives.swift').read_text()
        methods = []
        for name in ('copyFile', 'copyVerified'):
            start = source.index('    nonisolated private static func ' + name + '(')
            methods.append(source[start:source.index('\n    }\n', start) + 7].replace('private static', 'static'))
        fixture = r'''import Foundation
import CryptoKit
struct LogStore { static let shared=LogStore(); func log(_ value: String) {} }
extension URL { var freeSpace: Int64? { 1 << 40 }; var fileSystemType: String? { "apfs" } }
enum GameMover {
 struct Failure: LocalizedError { let errorDescription: String? }
METHODS
}
func rejects(_ body: () throws -> Void) { do { try body(); fatalError("unsafe move accepted") } catch {} }
let fm=FileManager.default, root=URL(fileURLWithPath:CommandLine.arguments[1])
let from=root.appendingPathComponent("original"), to=root.appendingPathComponent("copy")
try fm.createDirectory(at:from,withIntermediateDirectories:true)
let saved=Data(repeating:42,count:4096), game=from.appendingPathComponent("game.exe")
try saved.write(to:game)
try GameMover.copyVerified([(from,to)]) { _ in }
precondition((try! Data(contentsOf:to.appendingPathComponent("game.exe"))) == saved)
precondition(fm.fileExists(atPath:game.path))
rejects { try GameMover.copyVerified([(from,to)]) { _ in } }
precondition((try! Data(contentsOf:to.appendingPathComponent("game.exe"))) == saved)
try fm.removeItem(at:to)
var changed=false
rejects {
 try GameMover.copyVerified([(from,to)]) { _ in
  if !changed { changed=true; try! Data("new save".utf8).write(to:from.appendingPathComponent("save.dat")) }
 }
}
precondition(changed && !fm.fileExists(atPath:to.path))
precondition((try! Data(contentsOf:game)) == saved)
precondition(fm.fileExists(atPath:from.appendingPathComponent("save.dat").path))
print("PASS move copy hashes, conflict preservation and changed-source cleanup")
'''.replace('METHODS', '\n'.join(methods))
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch); main=root/'main.swift'; main.write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(main), '-o', str(root/'check')], check=True, timeout=60)
            subprocess.run([str(root/'check'), str(root.resolve()/'files')], check=True, timeout=15)

    def test_itch_setup_cleanup_waits_for_both_saved_records(self):
        from test_steam_cloud_quit import function
        source = (IOS / 'App/Stores/Itch/ItchLibrary.swift').read_text()
        fixture = r'''
import Foundation
enum Setup: String, Codable { case installer }
struct ItchInstalledGame: Codable {
 var folder="Games/Game", title="Game", launchExe="installer.exe"
 var setup: Setup? = .installer
 var setupSince: Date? = Date()
}
enum ItchSetup {
 static let folderName="setup", ranName="ran"
 static func installedElsewhere(drive: URL, title: String, since: Date) -> String? { nil }
}
enum ItchProgram {
 static func find(in folder: URL, title: String) -> String? {
  FileManager.default.fileExists(atPath:folder.appendingPathComponent("game.exe").path) ? "game.exe" : nil
 }
}
enum ItchLog { static func event(_ value: String) {} }
enum IridiumStoreFiles {
 static func url(folder: String, installRoot: String) throws -> URL { ItchLibrary.drive.appendingPathComponent(folder) }
}
@MainActor final class IridiumImportCoordinator {
 static let shared=IridiumImportCoordinator()
 var blocksLaunch=false, held=false, begins=0, ends=0
 func beginLibraryTransfer() throws { precondition(!held); held=true; begins += 1 }
 func endLibraryTransfer() { precondition(held); held=false; ends += 1 }
}
@MainActor final class LibraryModel {
 static let shared=LibraryModel()
 var saveOK=true, calls=0
 func upsertItch(_ game: ItchInstalledGame, cover: URL?, setupFinished: Bool) async -> Bool {
  precondition(IridiumImportCoordinator.shared.held && setupFinished)
  precondition(FileManager.default.fileExists(atPath:ItchLibrary.drive.appendingPathComponent("Games/Game/setup/installer.exe").path))
  calls += 1
  await Task.yield()
  return saveOK
 }
}
@MainActor final class ItchLibrary {
 static let drive=URL(fileURLWithPath:CommandLine.arguments[1])
 static var support: URL { drive.appendingPathComponent("records") }
 static var installedURL: URL { support.appendingPathComponent("installed.json") }
 static let installRoot="Games"
 var installed: [Int:ItchInstalledGame]=[:]
 var finishingSetups=false, sessionRunning=false
 var error: String?
 struct Game { var cover: URL? }
 func game(_ id: Int) -> Game? { nil }
METHODS
}
@main struct Check {
 @MainActor static func main() async throws {
  let fm=FileManager.default, store=ItchLibrary(), gate=IridiumImportCoordinator.shared
  let game=ItchLibrary.drive.appendingPathComponent("Games/Game")
  let setup=game.appendingPathComponent("setup")
  try fm.createDirectory(at:setup,withIntermediateDirectories:true)
  for name in ["setup/installer.exe","setup/ran","game.exe","save.dat"] {
   try Data(name.utf8).write(to:game.appendingPathComponent(name))
  }
  try store.setInstalled(ItchInstalledGame(),for:7)
  func retained() {
   precondition(store.installed[7]?.setup != nil)
   precondition(fm.fileExists(atPath:setup.appendingPathComponent("installer.exe").path))
   precondition(!gate.held && gate.begins == gate.ends)
  }
  store.sessionRunning=true; store.finishSetups(); precondition(gate.begins == 0)
  store.sessionRunning=false; gate.blocksLaunch=true; store.finishSetups(); precondition(gate.begins == 0)
  gate.blocksLaunch=false
  LibraryModel.shared.saveOK=false
  store.finishSetups(); store.finishSetups()
  while store.finishingSetups { await Task.yield() }
  retained(); precondition(LibraryModel.shared.calls == 1)
  LibraryModel.shared.saveOK=true
  try fm.removeItem(at:ItchLibrary.support)
  try Data("blocked".utf8).write(to:ItchLibrary.support)
  store.finishSetups()
  while store.finishingSetups { await Task.yield() }
  retained(); precondition(store.error != nil)
  try fm.removeItem(at:ItchLibrary.support)
  store.finishSetups()
  while store.finishingSetups { await Task.yield() }
  precondition(store.installed[7]?.setup == nil && store.installed[7]?.launchExe == "game.exe")
  precondition(!fm.fileExists(atPath:setup.path))
  precondition(fm.fileExists(atPath:game.appendingPathComponent("save.dat").path))
  precondition(fm.fileExists(atPath:game.appendingPathComponent("game.exe").path))
  precondition(!gate.held && gate.begins == gate.ends)
  print("PASS installer retained on either save failure; cleanup follows durable records")
 }
}
'''.replace('METHODS', '\n'.join(function(source, name) for name in ('setInstalled', 'finishSetups')))
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); main = root / 'check.swift'; main.write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', module_cache('macosx'),
                            str(main), '-o', str(root / 'check')], check=True, timeout=60)
            subprocess.run([str(root / 'check'), str(root / 'drive')], check=True, timeout=15)

    def test_store_paths_and_named_games_preserve_unrelated_files(self):
        fixture = r'''
import Foundation
final class LibraryModel {
 static let documents = URL(fileURLWithPath: CommandLine.arguments[1])
 static let drive = documents.appendingPathComponent("wine/drive_c")
}
enum ExternalDrives {
 static func nativeURL(_ path: String, write: Bool) throws -> URL { throw CocoaError(.fileNoSuchFile) }
}
func rejects(_ body: () throws -> Void) { do { try body(); fatalError("unsafe path accepted") } catch {} }
let fm=FileManager.default, docs=LibraryModel.documents, drive=LibraryModel.drive
try fm.createDirectory(at: drive.appendingPathComponent("Games/Game"), withIntermediateDirectories: true)
let keep=docs.appendingPathComponent("keep.dat")
try Data("user data".utf8).write(to: keep)
let alias=drive.appendingPathComponent("Games/foreign")
try fm.createSymbolicLink(at: alias, withDestinationURL: docs)
for path in ["../keep.dat", "Games/../keep.dat", "Games", "Other/Game", "Games/foreign"] {
 rejects { try IridiumStoreFiles.remove(folder:path,installRoot:"Games",metadata:[]) }
}
rejects { _ = try IridiumStoreFiles.url(folder:"External/Disconnected/Game",installRoot:"Games") }
rejects { _ = try IridiumStoreFiles.settingsFile("Games/foreign/keep.ini") }
rejects { _ = try IridiumStoreFiles.settingsFile("../keep.ini") }
rejects { _ = try IridiumStoreFiles.settingsFile("External/Missing/game.ini") }
let kept1 = try Data(contentsOf:keep); precondition(kept1 == Data("user data".utf8))
let game=UUID(), storage=IridiumGameStorage(documents:docs)
let payload=drive.appendingPathComponent("Games/Game/save.dat")
try Data("progress".utf8).write(to:payload)
try storage.migrateWindows([(game,"Games/Game/game.exe",false)],titles:[game:"Game"])
let folder=try storage.gameFolder(game)
precondition(fm.fileExists(atPath:folder.appendingPathComponent("save.dat").path))
try IridiumStoreFiles.remove(folder:"Games/Game",installRoot:"Games",metadata:[])
precondition(!fm.fileExists(atPath:folder.path))
precondition((try? fm.destinationOfSymbolicLink(atPath:drive.appendingPathComponent("Games/Game").path)) == nil)
let gone=UUID(), original=drive.appendingPathComponent("Games/Gone")
try fm.createDirectory(at:original,withIntermediateDirectories:true)
try Data("game".utf8).write(to:original.appendingPathComponent("game.exe"))
try storage.migrateWindows([(gone,"Games/Gone/game.exe",false)],titles:[gone:"Gone"])
let missing = try storage.gameFolder(gone)
try fm.removeItem(at:missing)
precondition(IridiumGameStorage.movedWindowsFolder(original,drive:drive) == missing)
precondition(IridiumStoreFiles.isDeleted(folder:"Games/Gone",installRoot:"Games"))
precondition(!IridiumStoreFiles.isDeleted(folder:"Games/foreign",installRoot:"Games"))
precondition(!IridiumStoreFiles.isDeleted(folder:"External/Disconnected/Game",installRoot:"Games"))
let metadata=docs.appendingPathComponent("gone-record.json")
try Data("record".utf8).write(to:metadata)
try IridiumStoreFiles.remove(folder:"Games/Gone",installRoot:"Games",metadata:[metadata])
precondition(!fm.fileExists(atPath:metadata.path))
precondition((try? fm.destinationOfSymbolicLink(atPath:original.path)) == nil)
let kept2 = try Data(contentsOf:keep); precondition(kept2 == Data("user data".utf8))
print("PASS store traversal, foreign links, missing drives and journaled game deletion")
'''
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch)
            main = path / 'main.swift'; main.write_text(fixture)
            files = [IOS / 'RuntimeSupport/IridiumRuntime.swift', IOS / 'RuntimeSupport/IridiumGameStorage.swift',
                     IOS / 'App/Storage/ExternalStorage.swift', IOS / 'App/Steam/SteamKeyValues.swift',
                     IOS / 'App/Stores/IridiumStoreFiles.swift', main]
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            *map(str, files), '-o', str(path / 'check')], check=True, timeout=90)
            subprocess.run([str(path / 'check'), str(path / 'Documents')], check=True, timeout=15)

    def test_install_records_publish_only_after_a_successful_atomic_write(self):
        from test_steam_cloud_quit import function
        types = [('Epic', 'String', '"game"', 'EpicInstalledGame'),
                 ('EA', 'String', '"game"', 'EAInstalledGame'), ('Itch', 'Int', '7', 'ItchInstalledGame')]
        fixture = 'import Foundation\n'
        for store, key, _, record in types:
            source = (IOS / f'App/Stores/{store}/{store}Library.swift').read_text()
            fixture += f'struct {record}: Codable {{ var offerID = "game"; var folder = "old" }}\n'
            fixture += f'class {store}Library {{\n'
            fixture += f'static var support: URL {{ URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("{store}") }}\n'
            fixture += 'static var installedURL: URL { support.appendingPathComponent("installed.json") }\n'
            fixture += f'var installed: [{key}: {record}] = [:]\n'
            fixture += function(source, 'setInstalled').replace('private func', 'func') + '\n}\n'
        fixture += '''func rejects(_ body: () throws -> Void) { do { try body(); fatalError("save should fail") } catch {} }
let fm = FileManager.default
'''
        for store, _, key, record in types:
            fixture += f'''do {{
 let library = {store}Library(), id = {key}
 try library.setInstalled({record}(), for: id)
 let before = try Data(contentsOf: {store}Library.installedURL)
 let moved = {store}Library.support.appendingPathExtension("kept")
 try fm.moveItem(at: {store}Library.support, to: moved)
 try Data("blocking file".utf8).write(to: {store}Library.support)
 rejects {{ try library.setInstalled(nil, for: id) }}
 precondition(library.installed[id]?.folder == "old")
 let after = try Data(contentsOf: moved.appendingPathComponent("installed.json"))
 precondition(before == after)
 try fm.removeItem(at: {store}Library.support)
 try fm.moveItem(at: moved, to: {store}Library.support)
 try library.setInstalled(nil, for: id)
 precondition(library.installed.isEmpty)
}}
'''
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); source = root / 'main.swift'; source.write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-module-cache-path', module_cache('macosx'),
                            str(source), '-o', str(root / 'check')], check=True, timeout=60)
            subprocess.run([str(root / 'check'), str(root)], check=True, timeout=15)

    def test_shared_setup_decompression_has_a_fixed_memory_limit(self):
        from test_steam_cloud_quit import function
        source = (IOS / 'App/Library/GameSetupShare.swift').read_text()
        fixture = '''import Foundation
import Compression
enum GameSetup {
 enum ReadError: Error { case notASetup }
UNPACK
}
func rejects(_ bytes: Data) { do { _ = try GameSetup.unpack(bytes); fatalError("Invalid setup accepted") } catch {} }
let sample = Data(String(repeating: "settings", count: 1000).utf8)
let packed = try (sample as NSData).compressed(using: .zlib) as Data
let decoded = try GameSetup.unpack(packed)
precondition(decoded == sample)
rejects(Data()); rejects(Data([0, 1, 2]))
let large = Data(repeating: 0, count: 9 << 20)
rejects(try (large as NSData).compressed(using: .zlib) as Data)
'''.replace('UNPACK', function(source.replace('    static func unpack(', '    func unpack('), 'unpack').replace('    func unpack(', '    static func unpack('))
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); source = root / 'main.swift'; source.write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-module-cache-path', module_cache('macosx'),
                            str(source), '-o', str(root / 'check')], check=True, timeout=60)
            subprocess.run([str(root / 'check')], check=True, timeout=15)

    def test_cancelled_ea_launch_cannot_commit_a_licence(self):
        from test_steam_cloud_quit import function
        source = (IOS / 'App/Stores/EA/Transport/EALicense.swift').read_text()
        normalized = source.replace('    @MainActor static func ', '    func ').replace('    static func ', '    func ')
        methods = '\n'.join(function(normalized, name).replace('    func ', '    static func ', 1)
                            for name in ('validContentID', 'folder', 'save'))
        methods += function(normalized, 'renew').replace('    func ', '    @MainActor static func ', 1)
        fixture = '''import Foundation
struct EALicenseInfo { var gameToken: String?; init?(xml: String) {} }
struct EAHardwareProfile { func machineHash(version: Int) -> (String, String) { ("hash", "input") } }
enum EALog { static func event(_ line: String) {} }
enum EAAPIError: Error { case license(String) }
enum EALicenseFile { static func pack(xml: String, signature: String, decodeSignature: Bool) -> Data? { Data("licence".utf8) } }
@MainActor class EAAPI {
 var completed: () -> Void = {}
 func license(contentID: String, machineHash: String) async throws -> (String, String) { completed(); return ("xml", "signature") }
}
enum EALicense {
 static let relativeFolder = "ProgramData/Electronic Arts/EA Services/License"
 struct Activation { var hashVersion = 1; var decodeSignature = false }
METHODS
}
@main struct Check {
 @MainActor static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1]), api = EAAPI()
  var allowed = true
  api.completed = { allowed = false }
  do {
   _ = try await EALicense.renew(api: api, contentID: "game", profile: EAHardwareProfile(), activation: .init(), drive: root, shouldCommit: { allowed })
   fatalError("Cancelled licence write was allowed")
  } catch is CancellationError {}
  precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(EALicense.relativeFolder).path))
  api.completed = {}; allowed = true
  _ = try await EALicense.renew(api: api, contentID: "game", profile: EAHardwareProfile(), activation: .init(), drive: root, shouldCommit: { allowed })
  precondition(FileManager.default.fileExists(atPath: EALicense.folder(drive: root).appendingPathComponent("game_cached.dlf").path))
  for id in ["../private", "/outside", "", "game/other", "game\\\\other"] {
   precondition(!EALicense.validContentID(id))
  }
 }
}
'''.replace('METHODS', methods)
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); source = root / 'Check.swift'; source.write_text(fixture)
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors',
                '-module-cache-path', module_cache('macosx'), str(IOS / 'App/Storage/ExternalStorage.swift'), str(IOS / 'App/Steam/SteamKeyValues.swift'),
                str(source), '-o', str(root / 'check')], check=True, timeout=60)
            subprocess.run([str(root / 'check'), str(root / 'drive')], check=True, timeout=15)
