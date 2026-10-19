"""Execute the simulator action boundary; no native game code is invoked."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SimulatorLaunchBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_missing_files_offer_location_and_present_files_report_runtime_limit(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumPreviewSupport.swift').read_text()
        code = source[source.index('@MainActor final class IridiumSimulatorLaunch:'):source.index('struct IridiumPreviewRoot:')]
        code = code.replace('@MainActor ', '').replace(': ObservableObject', '').replace('@Published ', '')
        fixture = r'''
import Foundation
struct Platform { let title: String }
struct LibraryEntry {
    let windowsPath: String
    static func hostURL(ofWindowsPath path: String) -> URL? { URL(fileURLWithPath: path) }
}
struct Console { let url: URL }
struct IridiumGame { let windows: LibraryEntry?; let console: Console?; let platform: Platform }
final class LibraryModel { static let shared = LibraryModel(); var error: String? }
struct Store { func rom(_ game: Console) throws -> URL { game.url } }
final class IridiumConsoleLibrary { static let shared = IridiumConsoleLibrary(); let store = Store() }
'''
        cases = r'''
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = directory.appendingPathComponent("game.data")
let boundary = IridiumSimulatorLaunch()
for windows in [true, false] {
    let game = IridiumGame(windows: windows ? LibraryEntry(windowsPath: path.path) : nil,
        console: windows ? nil : Console(url: path), platform: Platform(title: windows ? "Windows" : "PSP"))
    boundary.missingGame = nil; LibraryModel.shared.error = nil
    boundary.attempt(game)
    precondition(boundary.missingGame != nil && LibraryModel.shared.error == nil)
    try Data([0]).write(to: path)
    boundary.missingGame = nil
    boundary.attempt(game)
    precondition(boundary.missingGame == nil)
    precondition(LibraryModel.shared.error == "Playing \(game.platform.title) games requires an iPhone or iPad.")
    try FileManager.default.removeItem(at: path)
}
print("PASS: missing files request location; a present file reports the runtime limit only on attempted Play")
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); main = folder / 'main.swift'; binary = folder / 'check'
            main.write_text(fixture + code + cases)
            subprocess.run(['swiftc', '-module-cache-path', str(folder / 'cache'), str(main), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == '__main__': unittest.main()
