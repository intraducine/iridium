"""Exercise the shipping adapter ports without an engine, network, or real saves."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LibraryServicePortsTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_existing_state_owners_and_errors_are_preserved_by_adapters(self):
        app = ROOT / 'iridium/apps/ios/App'
        code = (app / 'Services/IridiumLibraryServices.swift').read_text() + (app / 'Adapters/Madeira/IridiumMadeiraServices.swift').read_text()
        fixture = r'''
import Foundation
struct LibraryEntry { let title: String }
struct DockGame { let id: Int }
enum IridiumPlatform { case windows, psp }
struct IridiumControlLayoutState { let marker: Int }
enum Fault: Error { case busy, save }
@MainActor final class SteamGamesModel {
 static let shared = SteamGamesModel(); var refreshes = 0
 func refresh() { refreshes += 1 }
}
@MainActor final class SteamOwnedLibrary {
 static let shared = SteamOwnedLibrary(); static var enabled = false
 var starts = 0, reconciles = 0
 func start() { starts += 1 }
 func reconcileSession() { reconciles += 1 }
}
@MainActor final class LibraryModel {
 static let shared = LibraryModel(); var current: LibraryEntry?; var launching = false
}
@MainActor final class IridiumConsoleSession { static let shared = IridiumConsoleSession(); var isActive = false }
@MainActor final class JITCoordinator { static let shared = JITCoordinator(); var busy = false }
@MainActor var nativeRunning = false
@MainActor func wine_process_is_running() -> Int { nativeRunning ? 1 : 0 }
@MainActor func wineserver_is_running() -> Int { 0 }
@MainActor final class TouchControlsModel {
 static let shared = TouchControlsModel(); var owner: UUID?; var marker: Int?
 func iridiumBeginSettings(owner: UUID, platform: IridiumPlatform, state: IridiumControlLayoutState, admission: Bool) throws {
  guard admission, self.owner == nil else { throw Fault.busy }
  self.owner = owner; marker = state.marker
 }
 func iridiumEndSettings(owner: UUID) { if self.owner == owner { self.owner = nil } }
}
enum SaveBackup {
 struct BackupResult { let files: Int }
 static func backup() throws -> BackupResult { .init(files: 7) }
 static func restore(from url: URL) throws -> Int {
  guard url.lastPathComponent == "approved.zip" else { throw Fault.save }; return 9
 }
}
'''
        cases = r'''
@main struct Check {
 @MainActor static func main() throws {
  var title = "", dock: (Int, Bool)?, jitCalls = 0
  let services = IridiumLibraryServices(
   windows: IridiumMadeiraLaunchAdapter(start: { title = $0.title }, startDock: { dock = ($0.id, $1) }),
   jit: IridiumMadeiraJITAdapter(enable: { jitCalls += 1 }), steam: IridiumMadeiraSteamAdapter())
  services.windows.launch(.init(title: "Existing profile")); precondition(title == "Existing profile")
  services.windows.launchSteam(.init(id: 42), compactPool: true); precondition(dock!.0 == 42 && dock!.1)
  services.jit.enableForPlaying(); precondition(jitCalls == 1)
  services.steam.refreshInstalledGames(); precondition(SteamGamesModel.shared.refreshes == 1)
  services.steam.connectAndReconcile(); services.steam.reconcileIfEnabled()
  precondition(SteamOwnedLibrary.shared.starts == 0 && SteamOwnedLibrary.shared.reconciles == 0)
  SteamOwnedLibrary.enabled = true; services.steam.connectAndReconcile(); services.steam.reconcileIfEnabled()
  precondition(SteamOwnedLibrary.shared.starts == 1 && SteamOwnedLibrary.shared.reconciles == 2)
  let editor: any IridiumControlEditing = IridiumMadeiraControlAdapter(), owner = UUID()
  nativeRunning = true
  do { try editor.begin(owner: owner, platform: .psp, layout: .init(marker: 3)); preconditionFailure("native process must block settings") } catch Fault.busy {}
  nativeRunning = false
  try editor.begin(owner: owner, platform: .psp, layout: .init(marker: 3))
  precondition(TouchControlsModel.shared.marker == 3)
  editor.end(owner: UUID()); precondition(TouchControlsModel.shared.owner == owner)
  editor.end(owner: owner); precondition(TouchControlsModel.shared.owner == nil)
  let saves: any IridiumSaveServicing = IridiumMadeiraSaveAdapter()
  let backup = try saves.backup(); precondition(backup.files == 7)
  let restored = try saves.restore(from: URL(fileURLWithPath: "/approved.zip")); precondition(restored == 9)
  do { _ = try saves.restore(from: URL(fileURLWithPath: "/bad.zip")); preconditionFailure("save error lost") } catch Fault.save {}
  print("PASS: ports retain callback arguments, shared service state, native admission, edit ownership and save errors")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); source = folder / 'check.swift'; binary = folder / 'check'
            source.write_text(fixture + code + cases)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'cache'), str(source), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)
