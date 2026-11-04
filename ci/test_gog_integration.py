"""Exercise the imported GOG protocols and setup against shipping source."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'
APP = IOS / 'App'
GOG = APP / 'Stores/GOG/Transport'
HOST = ROOT / 'vendor/Madeira/tests/host'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class GOGIntegrationTests(unittest.TestCase):
    def test_token_update_failure_never_deletes_the_saved_session(self):
        source = (GOG / 'GOGAPI.swift').read_text()
        token = source[source.index('enum GOGTokenStore {'):source.index('\nactor GOGAPI')]
        for name in ('SecItemUpdate', 'SecItemAdd', 'SecItemDelete', 'SecItemCopyMatching'):
            token = token.replace(name, 'Mock' + name)
        fixture = r'''import Foundation
import Security
struct GOGSession: Codable { var value: String }
var updateStatus = errSecSuccess, addStatus = errSecSuccess
var updates = 0, adds = 0, deletes = 0
func MockSecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
 updates += 1
 precondition((query as NSDictionary)[kSecAttrService] as? String == "madeira.gog.tokens")
 precondition((query as NSDictionary)[kSecAttrAccount] as? String == "session")
 precondition((attributes as NSDictionary)[kSecValueData] is Data)
 return updateStatus
}
func MockSecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 adds += 1
 precondition((query as NSDictionary)[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
 precondition((query as NSDictionary)[kSecAttrSynchronizable] as? Bool == false)
 return addStatus
}
func MockSecItemDelete(_ query: CFDictionary) -> OSStatus { deletes += 1; return errSecSuccess }
func MockSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 fatalError("The test must never read a Keychain")
}
TOKEN
let session = GOGSession(value: "synthetic-session")
precondition(GOGTokenStore.save(session) && updates == 1 && adds == 0 && deletes == 0)
updateStatus = errSecInteractionNotAllowed
precondition(!GOGTokenStore.save(session) && adds == 0 && deletes == 0)
updateStatus = errSecItemNotFound
precondition(GOGTokenStore.save(session) && adds == 1 && deletes == 0)
addStatus = errSecNotAvailable
precondition(!GOGTokenStore.save(session) && adds == 2 && deletes == 0)
print("PASS GOG token update, locked item, missing item and failed insert; no saved token deleted")
'''.replace('TOKEN', token)
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            main = root / 'main.swift'
            main.write_text(fixture)
            result = subprocess.run(['swiftc', '-module-cache-path', module_cache(), str(main),
                '-o', str(root / 'check')], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr[-5000:])
            result = subprocess.run([str(root / 'check')], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_resident_registry_is_never_edited_and_missing_settings_request_restart(self):
        from test_steam_cloud_quit import function
        method = function((APP / 'Stores/GOG/GOGLibrary.swift').read_text(), 'writeInstallScriptRegistry')
        fixture = r'''import Foundation
var server: Int32 = 0, process: Int32 = 0
func wineserver_is_running() -> Int32 { server }
func wine_process_is_running() -> Int32 { process }
struct LibraryEntry { var desktop: Bool? = false }
struct Record { let productID = "7", folder = "GOG Games/Fixture", language = "en-US" }
enum GOGLog { static func event(_ text: String) {} }
enum SteamInstallRun { enum Hive { case machine, user } }
struct SteamInstallValue {
 enum Content { case string(String), dword(UInt32) }
 var hive: SteamInstallRun.Hive, key: String, name: String, data: Content, followsInstall: Bool
}
enum SteamInstallRegistry {
 static var writes = 0, failWrite = false
 static func write(_ values: [SteamInstallValue], in text: String, now: Int) -> (text: String, changed: Int) {
  (text, text == "ready" ? 0 : values.count)
 }
 static func write(_ values: [SteamInstallValue], prefix: URL) throws -> Int {
  writes += 1
  if failWrite { throw CocoaError(.fileWriteNoPermission) }
  return values.count
 }
}
enum IridiumStoreFiles {
 static func url(folder: String, installRoot: String) throws -> URL { GOGLibrary.drive.appendingPathComponent(folder) }
}
final class GOGLibrary {
 static let drive = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("drive_c")
 static let installRoot = "GOG Games"
 func installedGame(for entry: LibraryEntry) -> Record? { Record() }
METHOD
}
let fm = FileManager.default, library = GOGLibrary(), entry = LibraryEntry()
let folder = GOGLibrary.drive.appendingPathComponent("GOG Games/Fixture")
try fm.createDirectory(at: folder, withIntermediateDirectories: true)
let script = #"{"productId":"7","actions":[{"install":{"action":"setRegistry","arguments":{"root":"HKLM","subkey":"Software/Fixture","valueName":"InstallFolder","valueData":"{app}","valueType":"string"}}}]}"#
try Data(script.utf8).write(to: folder.appendingPathComponent("goggame-7.script"))
SteamInstallRegistry.failWrite = true
precondition(!library.writeInstallScriptRegistry(for: entry))
SteamInstallRegistry.failWrite = false
precondition(library.writeInstallScriptRegistry(for: entry))
let writes = SteamInstallRegistry.writes
let registry = GOGLibrary.drive.deletingLastPathComponent().appendingPathComponent("system.reg")
try Data("stale".utf8).write(to: registry)
server = 1
precondition(!library.writeInstallScriptRegistry(for: entry))
precondition(SteamInstallRegistry.writes == writes)
try Data("ready".utf8).write(to: registry)
precondition(library.writeInstallScriptRegistry(for: entry))
precondition(SteamInstallRegistry.writes == writes)
server = 0; process = 1
try Data("stale".utf8).write(to: registry)
precondition(!library.writeInstallScriptRegistry(for: entry))
precondition(SteamInstallRegistry.writes == writes)
print("PASS GOG registry write failures, cold writes and resident restart admission")
'''.replace('METHOD', method)
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            main = root / 'main.swift'
            main.write_text(fixture)
            result = subprocess.run(['swiftc', '-module-cache-path', module_cache(),
                str(GOG / 'GOGInstallScript.swift'), str(main), '-o', str(root / 'check')],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr[-5000:])
            result = subprocess.run([str(root / 'check'), str(root / 'prefix')],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_install_script_registry_values_and_language_filters(self):
        with tempfile.TemporaryDirectory() as scratch:
            exe = Path(scratch) / 'check'
            result = subprocess.run(['swiftc', '-module-cache-path', module_cache(),
                str(GOG / 'GOGInstallScript.swift'), str(HOST / 'gog-script/main.swift'),
                '-o', str(exe)], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr[-5000:])
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_setup_outcomes_and_safe_game_paths(self):
        storage = (APP / 'Storage/ExternalStorage.swift').read_text()
        storage = storage[:storage.index('enum ExternalStorageIdentity')]
        stubs = (HOST / 'gog-setup/Stubs.swift').read_text() + '''
enum GOGLibrary { static let installRoot = "GOG Games" }
final class LibraryModel {
 static let documents = URL(fileURLWithPath: CommandLine.arguments[1])
 static let drive = documents.appendingPathComponent("wine/drive_c")
}
enum ExternalDrives {
 static func nativeURL(_ path: String, write: Bool) throws -> URL { throw ExternalStorageError.unavailable }
}
'''
        main = (HOST / 'gog-setup/main.swift').read_text()
        start = main.index('let drive = URL(')
        end = main.index('\n', start)
        main = main[:start] + 'let drive = LibraryModel.drive' + main[end:]
        main += r'''
precondition(GOGSetup.hostURL("C:\\..\\outside", drive: drive) == nil)
let folder = drive.appendingPathComponent("GOG Games/Fixture")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try Data("game".utf8).write(to: folder.appendingPathComponent("game.exe"))
let game = UUID(), storage = IridiumGameStorage(documents: LibraryModel.documents)
try storage.migrateWindows([(game,"GOG Games/Fixture/game.exe",false)])
let expected = try storage.gameFolder(game).appendingPathComponent("game.exe")
let resolved = GOGSetup.hostURL("C:\\GOG Games\\Fixture\\game.exe", drive: drive)
precondition(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path, "resolved=\(String(describing: resolved)) expected=\(expected)")
let foreign = drive.appendingPathComponent("GOG Games/Foreign")
try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: LibraryModel.documents)
precondition(GOGSetup.hostURL("C:\\GOG Games\\Foreign\\private.exe", drive: drive) == nil)
'''
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            files = [GOG / 'GOGSetup.swift', APP / 'Stores/IridiumStoreFiles.swift',
                     IOS / 'RuntimeSupport/IridiumGameStorage.swift', IOS / 'RuntimeSupport/IridiumRuntime.swift']
            for name, value in [('Stubs.swift', stubs), ('Storage.swift', storage), ('main.swift', main)]:
                path = root / name
                path.write_text(value)
                files.append(path)
            result = subprocess.run(['swiftc', '-module-cache-path', module_cache(),
                *map(str, files), '-o', str(root / 'check')], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr[-5000:])
            result = subprocess.run([str(root / 'check'), str(root / 'Documents')],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_galaxy_wire_service_and_listener(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            sources = root / 'Sources/G'
            tests = root / 'Tests/GTests'
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            for source in (GOG / 'Galaxy').glob('*.swift'):
                shutil.copy2(source, sources / source.name)
            shutil.copy2(HOST / 'gog-galaxy/Stub.swift', sources / 'Stub.swift')
            shutil.copy2(HOST / 'gog-galaxy/GalaxyTests.swift', tests / 'GalaxyTests.swift')
            (root / 'Package.swift').write_text('// swift-tools-version:5.9\nimport PackageDescription\n'
                'let package = Package(name: "G", targets: [.target(name: "G"), '
                '.testTarget(name: "GTests", dependencies: ["G"])])\n')
            result = subprocess.run(['swift', 'test', '--jobs', '2'], cwd=root,
                capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-7000:])
