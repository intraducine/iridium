"""Exercise the imported runtime adapters using Iridium's shipping sources."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import iridium_app_sources

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/Madeira'


class MadeiraUpdateTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_thermal_pacing_stops_after_a_manual_cap_choice(self):
        source = iridium_app_sources.logical_source('FPSOverlay.swift')
        policy = source[source.index('final class ThermalPacing {'):source.index('/// Small overlay shown')]
        policy = policy.replace('ProcessInfo.', 'TestProcessInfo.')
        fixture = r'''
import Foundation
enum MadeiraConfig { static func flag(_ name: String, fallback: Bool) -> Bool { true } }
final class TestProcessInfo {
    enum State { case nominal, serious, critical }
    static let processInfo = TestProcessInfo()
    static let thermalStateDidChangeNotification = Notification.Name("test.thermal")
    var thermalState = State.nominal
}
enum ProMotionIntent {
    static let has40Cap = true, has30Cap = true
    static func apply(mode: Int32) {}
}
final class LogStore { static let shared = LogStore(); func log(_ text: String) {} }
var mode: Int32 = 1
func madeira_get_vsync_locked() -> Int32 { mode }
func madeira_set_vsync_locked(_ value: Int32) { mode = value }
POLICY
func heat(_ state: TestProcessInfo.State) {
    TestProcessInfo.processInfo.thermalState = state
    NotificationCenter.default.post(name: TestProcessInfo.thermalStateDidChangeNotification, object: nil)
}
let pacing = ThermalPacing.shared
pacing.begin()
heat(.serious); precondition(mode == 4)
heat(.nominal); precondition(mode == 1)
heat(.critical); precondition(mode == 4)
pacing.userChose(); mode = 1
heat(.nominal); heat(.serious); precondition(mode == 1)
pacing.begin(); precondition(mode == 4)
pacing.end(); mode = 1
heat(.critical); precondition(mode == 1)
print("PASS: thermal caps restore, yield to a manual choice and stop at session end")
'''.replace('POLICY', policy)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache(), str(root / 'main.swift'),
                            '-o', str(root / 'check')], check=True, timeout=90)
            subprocess.run([str(root / 'check')], check=True, timeout=15)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_cloud_cache_preserves_device_changes_and_reports_write_failure(self):
        source = iridium_app_sources.logical_source('SteamCloud.swift')
        entry = source[source.index('struct SteamCloudEntry:'):source.index('/// How one app\'s cloud and local save files compare.')]
        cache = source[source.index('enum SteamRemoteCache {'):source.index('// MARK: - What to do with a comparison')]
        start = source.index('    static func split(')
        split = source[start:source.index('\n    }', start) + 6]
        hex_method = next(line for line in source.splitlines() if 'static func hex(' in line)
        fixture = r'''
import Foundation
enum SteamFileError: Error { case invalid(String) }
ENTRY
struct SteamCloudAudit { var changeNumber: UInt64; var entries: [SteamCloudEntry] }
struct SteamCloudPaths {
    var remoteFolder: URL
SPLIT
}
enum SteamCloudPlan {
HEX
}
CACHE
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let paths = SteamCloudPaths(remoteFolder: folder.appendingPathComponent("remote"))
let url = folder.appendingPathComponent("remotecache.vdf")
let localFields: SteamRemoteCache.Fields = [("root", "0"), ("syncstate", "3"), ("sha", "device-change")]
let otherFields: SteamRemoteCache.Fields = [("root", "2"), ("syncstate", "1")]
let existing = SteamRemoteCache.List(appID: "42", header: [("ChangeNumber", "6")], files: [
    ("device.save", localFields), ("stale.save", localFields), ("elsewhere.save", otherFields)])
try Data(SteamRemoteCache.format(existing).utf8).write(to: url)
let audit = SteamCloudAudit(changeNumber: 7, entries: [
    .init(path: "progress.save", kind: .same, cloudTime: 12, localSize: 2, localTime: 10, localSHA: Data([1, 2])),
    .init(path: "device.save", kind: .differ), .init(path: "stale.save", kind: .cloudOnly)])
let written = try SteamRemoteCache.write(appID: 42, audit: audit, paths: paths)!
precondition(written.synced == 1 && written.local == 1 && written.dropped == 1)
let result = SteamRemoteCache.parse(try String(contentsOf: url, encoding: .utf8))!
precondition(result.files.first { $0.name == "progress.save" }?.fields.contains { $0.key == "sha" && $0.value == "0102" } == true)
precondition(result.files.first { $0.name == "device.save" }?.fields.contains { $0.value == "device-change" } == true)
precondition(result.files.contains { $0.name == "elsewhere.save" })
precondition(!result.files.contains { $0.name == "stale.save" })
let unchanged = try SteamRemoteCache.write(appID: 42, audit: audit, paths: paths)
precondition(unchanged == nil)
let escaped = SteamRemoteCache.List(appID: "42", files: [("a\"b\\c.save", localFields)])
precondition(SteamRemoteCache.parse(SteamRemoteCache.format(escaped)) == escaped)
for invalid in ["\"42\" { \"file\" { \"sha\" \"truncated", "\"42\" {} \"extra\" {}", "\"42\" { garbage }", "\"99\" {}"] {
    let bytes = Data(invalid.utf8)
    try bytes.write(to: url)
    do {
        _ = try SteamRemoteCache.write(appID: 42, audit: audit, paths: paths)
        preconditionFailure("A damaged or foreign index must be kept")
    } catch {}
    let preserved = try Data(contentsOf: url)
    precondition(preserved == bytes)
}

try FileManager.default.removeItem(at: url)
try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
do {
    _ = try SteamRemoteCache.write(appID: 42, audit: audit, paths: paths)
    preconditionFailure("An unwritable cache must not be reported as unchanged")
} catch {}
print("PASS: Cloud cache sync, local changes, other roots, escaping, unchanged records and write failures")
'''.replace('ENTRY', entry).replace('SPLIT', split).replace('HEX', hex_method).replace('CACHE', cache)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache(), str(root / 'main.swift'),
                            '-o', str(root / 'check')], check=True, timeout=90)
            subprocess.run([str(root / 'check')], check=True, timeout=15)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_gesture_zone_writer_preserves_global_layout_across_sessions(self):
        source = iridium_app_sources.logical_source('ContentView.swift')
        controls = source[source.index('enum ControlAction:'):source.index('final class TouchControlsModel:')]
        presets = iridium_app_sources.logical_source('TouchControlPresets.swift')
        zones = presets[presets.index('enum GestureZoneKind:'):presets.index('/// The screen a built-in layout')]
        model = iridium_app_sources.logical_source('GestureZones.swift').split('// MARK: - Touch handling', 1)[0]
        model = model.replace('import SwiftUI', '').replace('import UIKit', '')
        model = model.replace(': ObservableObject', '').replace('@Published ', '')
        model = model.replace('FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]', 'fixtureFolder')
        fixture = r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
let fixtureFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureFolder) }
enum GamepadInput { static func flag(_ name: String) -> Bool { true } }
final class TouchControlsModel { static let shared = TouchControlsModel(); var iridiumSettingsContext: UUID? }
final class LibraryModel { static let shared = LibraryModel(); var current: UUID?; var error: String? }
CONTROLS
ZONES
MODEL
let model = GestureZonesModel.shared
var global = GestureZone(); global.x = 0.1
model.zones = [global]
model.flush()
let file = fixtureFolder.appendingPathComponent("madeira-gesture-zones.json")
let saved = try Data(contentsOf: file)
LibraryModel.shared.current = UUID()
var game = global; game.x = 0.6
model.zones = [game]; model.flush()
RunLoop.main.run(until: Date().addingTimeInterval(0.7))
precondition((try? Data(contentsOf: file)) == saved)
model.zones = [global]
LibraryModel.shared.current = nil
TouchControlsModel.shared.iridiumSettingsContext = UUID()
model.zones = [game]; model.flush()
RunLoop.main.run(until: Date().addingTimeInterval(0.7))
precondition((try? Data(contentsOf: file)) == saved)
model.zones = [global]; TouchControlsModel.shared.iridiumSettingsContext = nil
try FileManager.default.removeItem(at: fixtureFolder)
model.flush()
precondition(LibraryModel.shared.error != nil)
print("PASS: delayed zone writes cannot replace global controls during a game or editor; write failures surface")
'''.replace('CONTROLS', controls).replace('ZONES', zones).replace('MODEL', model)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache(), str(root / 'main.swift'),
                            '-o', str(root / 'check')], check=True, timeout=90)
            subprocess.run([str(root / 'check')], check=True, timeout=15)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_fixed_executable_window_scans_real_pe_headers(self):
        source = iridium_app_sources.logical_source('StikJITHelper.swift')
        start = source.index('    static func fixedBaseWindowMB(')
        method = source[start:source.index('\n    }', start) + 6]
        fixture = r'''
import Foundation
enum WindowScan {
METHOD
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func image(_ name: String, megabytes: Int, base: UInt64 = 0x140000000, relocations: Bool = false) throws {
    var bytes = [UInt8](repeating: 0, count: 4096)
    func put(_ offset: Int, _ value: UInt64, _ size: Int) {
        for i in 0..<size { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    put(0, 0x5a4d, 2); put(0x3c, 0x80, 4); put(0x80, 0x4550, 4)
    put(0x80+22, relocations ? 0 : 1, 2)
    let opt = 0x80+24
    put(opt, 0x20b, 2); put(opt+24, base, 8)
    put(opt+56, UInt64(megabytes) << 20, 4)
    put(opt+112+5*8+4, relocations ? 32 : 0, 4)
    try Data(bytes).write(to: folder.appendingPathComponent(name))
}
precondition(WindowScan.fixedBaseWindowMB(in: folder) == nil)
try image("small.exe", megabytes: 117)
try image("relocatable.exe", megabytes: 700, relocations: true)
try image("different-base.exe", megabytes: 700, base: 0x400000)
try Data([0x4d, 0x5a]).write(to: folder.appendingPathComponent("truncated.exe"))
precondition(WindowScan.fixedBaseWindowMB(in: folder) == nil)
try image("maple.EXE", megabytes: 183)
precondition(WindowScan.fixedBaseWindowMB(in: folder)?.mb == 192)
try image("elliot.exe", megabytes: 473)
precondition(WindowScan.fixedBaseWindowMB(in: folder)?.mb == 480)
try image("offset.exe", megabytes: 201, base: 0x150000000)
precondition(WindowScan.fixedBaseWindowMB(in: folder)?.mb == 480)
print("PASS: fixed-base sizing, largest executable, relocation and malformed-file handling")
'''.replace('METHOD', method)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache(), str(root / 'main.swift'),
                            '-o', str(root / 'check')], check=True, timeout=90)
            subprocess.run([str(root / 'check')], check=True, timeout=20)

    @unittest.skipUnless(shutil.which('swiftc') and shutil.which('cc'), 'Host compilers required')
    def test_clipboard_queue_uses_owned_swift_and_pinned_native_driver(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'app/Madeira'
            (app / 'Winios').mkdir(parents=True)
            for name in ('HardwareInput.swift', 'Library.swift', 'ContentView.swift'):
                (app / name).write_text(iridium_app_sources.logical_source(name))
            (app / 'Winios/Winios.m').symlink_to(UPSTREAM / 'app/Madeira/Winios/Winios.m')
            (root / 'build').symlink_to(UPSTREAM / 'build', target_is_directory=True)
            test = root / 'tests/host/check-clipboard-paste.py'
            test.parent.mkdir(parents=True)
            shutil.copy2(UPSTREAM / 'tests/host/check-clipboard-paste.py', test)
            subprocess.run(['python3', '-B', str(test)], check=True, timeout=120)


if __name__ == '__main__':
    unittest.main()
