"""Execute generated console persistence methods with Foundation-only fixtures.

UIKit and SwiftUI are not simulated. The shipping adapter supplies every method
under test; the fixture supplies only their stored model fields and JSON inputs.
"""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'vendor/Madeira/app/Madeira/ContentView.swift'


def production_fragment():
    spec = importlib.util.spec_from_file_location('console_persistence_frontend', ROOT / 'ci/madeira-frontend.py')
    frontend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(frontend)
    generated = frontend.overlay('ContentView.swift', SOURCE.read_text())
    start = generated.index('    var iridiumConsoleScope: UUID?')
    end = generated.index('    private static var url: URL {', start)
    return generated[start:end]


STUBS = r'''
import Foundation

enum ControlAction: Codable, Equatable {
    case pad(String)
    case mouseLeft
    var padName: String? { if case .pad(let name) = self { return name }; return nil }
}
struct TouchControl: Codable, Equatable {
    var id = UUID()
    var nx = 0.5
    var ny = 0.5
    var scale = 1.0
    var action: ControlAction = .pad("A")
}
final class Model {
    // Match the shipping model's eager save observers, including callbacks
    // during begin/resize/end transactions guarded by loading.
    var controls: [TouchControl] = [] { didSet { iridiumSaveConsole() } }
    var visible = true { didSet { iridiumSaveConsole() } }
    var sizeScale = 1.0
    var layoutID: String? { didSet { iridiumSaveConsole() } }
    var selected: UUID?
    var editing = false
'''

CASES = r'''
}
struct Fixture: Codable {
    var version = 1
    var controls: [TouchControl]
    var visible: Bool
    var size: Double
    var automatic: Bool?
}
func bytes(_ controls: [TouchControl], version: Int = 1, visible: Bool = false, size: Double = 1.25) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(Fixture(version: version, controls: controls, visible: visible, size: size))
}
func key(_ game: UUID) -> String { "IridiumConsoleControlLayout." + game.uuidString }
let games = (0..<20).map { _ in UUID() }
let defaults = UserDefaults.standard
let unrelated = "IridiumPersistenceTest.Unrelated." + UUID().uuidString
let sentinel = Data("unrelated settings must survive".utf8)
defaults.set(sentinel, forKey: unrelated)
defer {
    for game in games { defaults.removeObject(forKey: key(game)) }
    defaults.removeObject(forKey: unrelated)
}
let windows = [TouchControl(nx: 0.2, ny: 0.3, action: .mouseLeft)]
let initial = [TouchControl(action: .pad("A")), TouchControl(action: .pad("B"))]
let model = Model()
model.controls = windows; model.visible = false; model.sizeScale = 1.75; model.layoutID = "windows-custom"
func assertWindows() {
    precondition(model.controls == windows && !model.visible)
    precondition(model.sizeScale == 1.75 && model.layoutID == "windows-custom")
    precondition(model.iridiumConsoleScope == nil && model.selected == nil && !model.editing)
    precondition(defaults.data(forKey: unrelated) == sentinel)
}
func untouched(_ index: Int, _ original: Data?) {
    let game = games[index]
    if let original { defaults.set(original, forKey: key(game)) }
    model.iridiumBeginConsole(game, defaults: initial, visible: true)
    model.iridiumSaveConsole()
    model.iridiumEndConsole()
    precondition(defaults.data(forKey: key(game)) == original, "No-edit bytes changed: \(index)")
    assertWindows()
}
// Absent, corrupt, future-version and valid (noncanonical whitespace) records
// remain byte-for-byte unchanged when the user only enters and leaves a session.
untouched(0, nil)
untouched(1, Data("not JSON".utf8))
untouched(2, try bytes(initial, version: 2))
let valid = try bytes(initial, visible: false, size: 1.4)
untouched(3, valid)
model.iridiumBeginConsole(games[3], defaults: initial, visible: true)
precondition(model.controls == initial && !model.visible && model.sizeScale == 1.4)
// A second begin cannot discard the Windows snapshot or switch persistence key.
model.iridiumBeginConsole(games[4], defaults: [], visible: true)
precondition(model.iridiumConsoleScope == games[3])
model.iridiumEndConsole(); assertWindows()

// An explicit change also replaces a future-version record with this version's
// valid layout, while merely opening that same record above preserved its bytes.
model.iridiumBeginConsole(games[2], defaults: initial, visible: true)
model.controls[0].nx = 0.65
model.iridiumEndConsole(); assertWindows()
let repairedFuture = try JSONDecoder().decode(Fixture.self, from: defaults.data(forKey: key(games[2]))!)
precondition(repairedFuture.version == 1 && repairedFuture.controls[0].nx == 0.65)

// Explicit edits repair corrupt data and survive independent game sessions.
model.iridiumBeginConsole(games[1], defaults: initial, visible: true)
model.controls[0].nx = 0.75; model.visible = false; model.sizeScale = 1.6
let edited = model.controls
model.iridiumSaveConsole()
let savedOne = defaults.data(forKey: key(games[1]))!
precondition(savedOne != Data("not JSON".utf8))
model.iridiumEndConsole(); assertWindows()
model.iridiumBeginConsole(games[4], defaults: initial, visible: true)
model.controls[1].ny = 0.9
let other = model.controls
model.iridiumEndConsole(); assertWindows()
precondition(defaults.data(forKey: key(games[1])) == savedOne)
model.iridiumBeginConsole(games[1], defaults: initial, visible: true)
precondition(model.controls == edited && !model.visible && model.sizeScale == 1.6)
model.iridiumEndConsole(); assertWindows()
model.iridiumBeginConsole(games[4], defaults: initial, visible: true)
precondition(model.controls == other)
model.iridiumEndConsole(); assertWindows()

// Successful save refreshes the baseline. A later no-edit save must not write
// again: preserving differently formatted equivalent bytes makes it observable.
model.iridiumBeginConsole(games[5], defaults: initial, visible: true)
model.controls[0].ny = 0.8
model.iridiumSaveConsole()
let formatted = try bytes(model.controls, visible: model.visible, size: model.sizeScale)
defaults.set(formatted, forKey: key(games[5]))
model.iridiumSaveConsole(); model.iridiumEndConsole()
precondition(defaults.data(forKey: key(games[5])) == formatted)
assertWindows()

// Invalid persisted layouts fall back without destroying the rejected bytes.
var outOfBounds = initial; outOfBounds[0].nx = 1.1
var invalidScale = initial; invalidScale[0].scale = 0.1
var invalidAction = initial; invalidAction[0].action = .mouseLeft
let duplicate = [initial[0], initial[0]]
let excessive = (0..<129).map { _ in TouchControl() }
for (offset, controls) in [outOfBounds, invalidScale, invalidAction, duplicate, excessive].enumerated() {
    let game = games[6 + offset]
    let rejected = try bytes(controls)
    defaults.set(rejected, forKey: key(game))
    model.iridiumBeginConsole(game, defaults: initial, visible: true)
    precondition(model.controls == initial && model.visible && model.sizeScale == 1)
    model.iridiumEndConsole()
    precondition(defaults.data(forKey: key(game)) == rejected)
    assertWindows()
}
// Ending twice is harmless and cannot overwrite the restored Windows model.
model.iridiumEndConsole(); assertWindows()

// Rotation refreshes untouched defaults, keeping selection identities stable
// without overwriting absent, corrupt or future-version records.
let landscape = [TouchControl(nx: 0.12, ny: 0.55, action: .pad("A")),
                 TouchControl(nx: 0.88, ny: 0.55, action: .pad("B"))]
for (offset, original) in [nil, Data("unreadable".utf8), try bytes(initial, version: 2)].enumerated() {
    let game = games[11 + offset]
    if let original { defaults.set(original, forKey: key(game)) }
    model.iridiumBeginConsole(game, defaults: initial, visible: true)
    model.selected = initial[0].id; model.editing = true
    model.iridiumResizeConsole(defaults: landscape)
    precondition(model.controls.map(\.id) == initial.map(\.id))
    precondition(model.controls.map(\.nx) == landscape.map(\.nx))
    precondition(model.selected == initial[0].id && model.editing)
    precondition(defaults.data(forKey: key(game)) == original)
    model.editing = false
    model.iridiumResizeConsole(defaults: initial)
    precondition(model.controls == initial)
    model.iridiumEndConsole(); assertWindows()
    precondition(defaults.data(forKey: key(game)) == original)
}

// Legacy/custom records never acquire automatic behavior from a resize.
model.iridiumBeginConsole(games[3], defaults: landscape, visible: true)
model.iridiumResizeConsole(defaults: landscape)
precondition(model.controls == initial)
model.iridiumEndConsole(); assertWindows()
precondition(defaults.data(forKey: key(games[3])) == valid)

// A preference-only save preserves responsive defaults across relaunches.
model.iridiumBeginConsole(games[14], defaults: initial, visible: true)
model.visible = false
model.sizeScale = 1.25; model.iridiumSaveConsole()
let preferenceBytes = defaults.data(forKey: key(games[14]))!
let preferenceRecord = try JSONDecoder().decode(Fixture.self, from: preferenceBytes)
precondition(preferenceRecord.automatic == true)
model.iridiumResizeConsole(defaults: landscape)
precondition(model.controls.map(\.nx) == landscape.map(\.nx))
precondition(!model.visible && model.sizeScale == 1.25)
model.iridiumEndConsole(); assertWindows()
precondition(defaults.data(forKey: key(games[14])) == preferenceBytes)
model.iridiumBeginConsole(games[14], defaults: landscape, visible: true)
precondition(model.controls.map(\.nx) == landscape.map(\.nx))
precondition(!model.visible && model.sizeScale == 1.25)
model.iridiumResizeConsole(defaults: initial)
model.iridiumEndConsole(); assertWindows()
precondition(defaults.data(forKey: key(games[14])) == preferenceBytes)

// An explicit control edit opts out before the next resize and survives it.
model.iridiumBeginConsole(games[14], defaults: initial, visible: true)
model.controls[0].nx = 0.7
let custom = model.controls
let customBytes = defaults.data(forKey: key(games[14]))!
let customRecord = try JSONDecoder().decode(Fixture.self, from: customBytes)
precondition(customRecord.automatic != true)
model.iridiumResizeConsole(defaults: landscape)
precondition(model.controls == custom)
model.iridiumEndConsole(); assertWindows()
model.iridiumBeginConsole(games[14], defaults: landscape, visible: true)
precondition(model.controls == custom)
model.iridiumResizeConsole(defaults: initial)
model.iridiumEndConsole(); assertWindows()
precondition(defaults.data(forKey: key(games[14])) == customBytes)
print("PASS: console persistence preserves Windows, per-game edits and no-edit bytes across repeated rotation")
'''


@unittest.skipUnless(SOURCE.is_file(), 'Pinned Madeira source required')
class ConsoleControlPersistenceTests(unittest.TestCase):
    def test_extracts_shipping_methods_and_validation(self):
        code = production_fragment()
        for name in ('iridiumBeginConsole', 'iridiumSaveConsole', 'iridiumEndConsole'):
            self.assertEqual(code.count('func ' + name + '('), 1)
        self.assertIn('saved.version == 1', code)
        self.assertIn('Set(saved.controls.map { $0.id }).count == saved.controls.count', code)
        self.assertIn('saved.controls.count <= 128', code)
        self.assertIn('controls = saved.controls; visible = saved.visible; sizeScale = saved.size; layoutID = saved.layout', code)

    def test_no_edit_guard_applies_to_all_records(self):
        code = production_fragment()
        self.assertIn('if value == iridiumConsoleBaseline { return }', code)
        save = code[code.index('    func iridiumSaveConsole()'):code.index('    func iridiumEndConsole()')]
        self.assertIn('iridiumConsoleBaseline = value', save)
        self.assertLess(save.index('if value == iridiumConsoleBaseline'), save.index('JSONEncoder().encode'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable; persistence execution requires Apple/Swift CI')
    def test_generated_persistence_execution(self):
        with tempfile.TemporaryDirectory(prefix='iridium-console-persistence-') as directory:
            root = Path(directory)
            source = root / 'main.swift'
            source.write_text(STUBS + production_fragment() + CASES)
            executable = root / ('ConsolePersistence' + root.name.replace('-', ''))
            subprocess.run(['swiftc', '-swift-version', '5', str(source), '-o', str(executable)],
                           check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
