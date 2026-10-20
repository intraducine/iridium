"""Execute Controls' shipping registrations, preference bindings and ownership guards."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def balanced(source, start, opening="(", closing=")"):
    begin = source.index(opening, start)
    depth = 0
    for end in range(begin, len(source)):
        depth += (source[end] == opening) - (source[end] == closing)
        if depth == 0:
            return source[start:end + 1]
    raise ValueError("Unbalanced source fixture")


class ControlsSettingsNavigationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler required")
    def test_live_preferences_full_traversal_and_child_ownership(self):
        front = ROOT / "iridium/apps/ios/MadeiraFrontend"
        controls = (front / "IridiumControlsSettings.swift").read_text()
        windows = (ROOT / "iridium/apps/ios/App/Library/IridiumWindowsScreens.swift").read_text()
        feedback = (front / "IridiumPlayerControls.swift").read_text()
        setup = (front / "IridiumSetupController.swift").read_text()
        layout = (ROOT / "iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift").read_text()
        policy = setup.split("// MARK: - SwiftUI registration", 1)[0]
        enums = "\n".join(balanced(layout, layout.index("enum " + name), "{", "}")
                          for name in ["IridiumTouchMouseMode", "IridiumTouchHaptics"])
        value_method = balanced(setup, setup.index("    func setupControllerValue"), "{", "}")
        value_method = value_method.replace("-> some View", "-> SetupControllerTarget")
        registrations = {}
        for source, ident in [(controls, "games"), (controls, "mapping"),
                              (windows, "mouse.mode"), (windows, "mouse.speed"),
                              (feedback, "haptics")]:
            start = source.index('.setupController', source.index('"controls.' + ident + '"') - 30)
            call = balanced(source, start)
            call = re.sub(r"\b(sensitivity|pickingGame|mapping)\b(?!\")", r"self.\1", call)
            registrations[ident] = "Registration()" + call
        properties = []
        for source, key in [(windows, "IridiumTouchMouseMode.settingsKey"),
                            (windows, '"IridiumMouseSensitivity"'),
                            (feedback, "IridiumTouchHaptics.settingsKey")]:
            line = next(line.strip() for line in source.splitlines() if "@AppStorage(" + key in line)
            properties.append(line.replace("private ", "").replace(") var ", ", store: fixtureDefaults) var "))
        nav = controls[controls.index("private struct IridiumControlsNavigation:"):controls.index("struct IridiumGameControlsButton:")]
        ownership = next(line.strip() for line in nav.splitlines() if "private var ownsCommands:" in line)
        methods = "\n".join(balanced(nav, nav.index("    private func " + name), "{", "}")
                            for name in ["updateTargets", "receive", "key"])
        changes = "\n".join(balanced(source, source.index("    private func " + name), "{", "}")
                            for source, name in [(windows, "changeMode"), (windows, "changeSpeed"), (feedback, "changeFeedback")])
        merger = balanced(controls, controls.index("enum IridiumControlsRows {"), "{", "}")
        game_selection = balanced(controls, controls.index("    private func selectGame(_ id: String)"), "{", "}")
        game_rows = balanced(controls, controls.index("choices.enumerated().map {"), "{", "}")
        game_rows = game_rows.replace("selectGame(", "self.selectGame(").replace("proxy.scrollTo", "self.proxy.scrollTo")
        ancestor = balanced(windows, windows.index("{ [controlsOwnsCommands ="), "{", "}")
        fixture = '''
import SwiftUI
let fixtureName = "Iridium-Controls-" + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureName)!
ENUMS
MERGER
struct Registration {
    func setupControllerTarget(_ id: String, order: Int, action: @escaping () -> Void,
                               adjust: ((Int) -> Void)? = nil) -> SetupControllerTarget {
        SetupControllerTarget(id: id, page: "controls", order: order,
            frame: CGRect(x: 0, y: order, width: 200, height: 44), enabled: true,
            action: action, adjust: adjust)
    }
VALUE_METHOD
}
@MainActor final class Preferences {
PROPERTIES
CHANGES
    var pickingGame = false
    var mapping = false
    func rows() -> [SetupControllerTarget] {
        var rows = [GAMES, MAPPING, MODE]
        if mode == IridiumTouchMouseMode.trackpad.rawValue { rows.append(SPEED) }
        rows.append(HAPTICS)
        return rows
    }
}
final class RoutingFocus {
    var policy = SetupControllerPolicy()
    func update(_ rows: [SetupControllerTarget], page: String) { policy.update(rows, page: page) }
    func receive(_ command: String, page: String, suspended: Bool, back: () -> Void) {
        policy.receive(command, suspended: suspended, back: back)
    }
}
struct Game { var id: String; var title: String }
final class ScrollProxy {
    var revealed: [String] = []
    func scrollTo(_ id: String, anchor: UnitPoint) { revealed.append(id) }
}
final class GamePickerFixture {
    var choices = (0..<300).map { Game(id: String($0), title: "Game \\($0)") }
    var pending: Game?
    var pickingGame = true
    let proxy = ScrollProxy()
GAME_SELECTION
    func rows() -> [SetupControllerTarget] { GAME_ROWS }
}
struct OnboardingFixture { var presented = false }
struct NavigationFixture {
    var page = "controls"
    var visible = false
    var suspended = false
    var scenePhase = ScenePhase.active
    var knownTargets: () -> [SetupControllerTarget] = { [] }
    var rendered: [SetupControllerTarget] = []
    let focus: RoutingFocus
    let back: () -> Void
OWNERSHIP
METHODS
}
@main struct Checks {
    @MainActor static func main() {
        defer { fixtureDefaults.removePersistentDomain(forName: fixtureName) }
        let preferences = Preferences(), focus = RoutingFocus()
        var backCount = 0
        var navigation = NavigationFixture(focus: focus, back: { backCount += 1 })
        navigation.knownTargets = { preferences.rows() }; navigation.updateTargets()
        precondition(focus.policy.available.map(\\.id) == ["controls.games", "controls.mapping", "controls.mouse.mode", "controls.mouse.speed", "controls.haptics"])
        navigation.receive("accept"); precondition(focus.policy.selected == nil)
        navigation.visible = true
        navigation.receive("down"); navigation.receive("accept")
        precondition(preferences.pickingGame)
        navigation.receive("down"); navigation.receive("accept")
        precondition(preferences.mapping)
        navigation.receive("down"); navigation.receive("right")
        precondition(preferences.mode == "direct" && fixtureDefaults.string(forKey: IridiumTouchMouseMode.settingsKey) == "direct")
        navigation.receive("down")
        precondition(!focus.policy.available.contains { $0.id == "controls.mouse.speed" })
        navigation.receive("accept")
        precondition(preferences.feedback == "medium" && fixtureDefaults.string(forKey: IridiumTouchHaptics.settingsKey) == "medium")
        navigation.receive("right"); precondition(preferences.feedback == "off")
        navigation.receive("left"); precondition(preferences.feedback == "medium")
        // A native preference update is observed by the next committed registrations.
        preferences.mode = "trackpad"
        navigation.receive("up"); precondition(focus.policy.selected == "controls.mouse.speed")
        navigation.receive("right"); precondition(preferences.sensitivity == 1.25)
        navigation.receive("accept"); precondition(preferences.sensitivity == 1.5)
        for _ in 0..<30 { navigation.receive("left") }; precondition(preferences.sensitivity == 0.25)
        for _ in 0..<30 { navigation.receive("right") }; precondition(preferences.sensitivity == 4)
        precondition(fixtureDefaults.double(forKey: "IridiumMouseSensitivity") == 4)
        // Background pages, sheets and navigation children cannot move focus or act.
        let selected = focus.policy.selected
        for context in 0..<3 {
            navigation.visible = context != 0
            navigation.suspended = context == 1
            navigation.scenePhase = context == 2 ? .inactive : .active
            for command in ["up", "down", "accept", "left", "right", "back"] { navigation.receive(command) }
            precondition(focus.policy.selected == selected && backCount == 0 && preferences.sensitivity == 4)
            switch navigation.key("down") { case .ignored: break; default: preconditionFailure("Hidden page captured a key") }
        }
        navigation.visible = true; navigation.suspended = false; navigation.scenePhase = .active
        navigation.receive("back"); precondition(backCount == 1)
        // End clamping never drops the lower Haptics target.
        for _ in 0..<20 { navigation.receive("down") }
        precondition(focus.policy.selected == "controls.haptics")
        navigation.receive("accept"); precondition(preferences.feedback == "off")
        // No lazy-row geometry is needed to reach every game before Done.
        let picker = GamePickerFixture()
        var gamePolicy = SetupControllerPolicy()
        let done = SetupControllerTarget(id: "controls.games.done", page: "controlGames", order: Int.max,
            frame: .zero, enabled: true, action: {})
        let allRows = picker.rows() + [done]
        let staleRow = allRows[0]
        let realized = [SetupControllerTarget(id: staleRow.id, page: staleRow.page, order: staleRow.order,
            frame: CGRect(x: 1, y: 2, width: 100, height: 40), enabled: true, action: { preconditionFailure("Stale geometry callback used") })]
        let complete = IridiumControlsRows.merged(known: allRows, rendered: realized + realized, page: "controlGames")
        precondition(complete.count == 301 && complete[0].frame.minX == 1)
        gamePolicy.update(complete, page: "controlGames")
        for index in 0..<300 {
            gamePolicy.receive("down", suspended: false, back: {})
            precondition(gamePolicy.selected == "controls.game.\\(index)")
        }
        precondition(picker.proxy.revealed.last == "controls.game.299")
        picker.choices[299].title = "Renamed after registration"
        gamePolicy.receive("accept", suspended: false, back: {})
        precondition(picker.pending?.title == "Renamed after registration" && !picker.pickingGame)
        picker.pending = nil; picker.pickingGame = true; picker.choices.removeLast()
        gamePolicy.receive("accept", suspended: false, back: {})
        precondition(picker.pending == nil && picker.pickingGame)
        gamePolicy.receive("down", suspended: false, back: {})
        precondition(gamePolicy.selected == "controls.games.done")
        // The ancestor snapshot prevents a Back event being handled twice, whichever subscriber runs first.
        for childFirst in [true, false] {
            var iridiumPages = ["Controls"]
            let selected: Int? = nil, settingsSheet: Int? = nil
            let browser = false, onboarding = OnboardingFixture()
            var ancestorCalls = 0
            func iridiumNavigate(_ command: String) { ancestorCalls += 1 }
            let ancestor: (String) -> Void = ANCESTOR
            if childFirst { iridiumPages.removeLast(); ancestor("back") }
            else { ancestor("back"); iridiumPages.removeLast() }
            precondition(ancestorCalls == 0 && iridiumPages.isEmpty)
        }
        print("PASS Controls registrations: mapping/games, persisted mouse/haptics, conditional speed, bounds, current callbacks and child/scene ownership")
    }
}
'''
        for key, value in {"ENUMS": enums, "VALUE_METHOD": value_method,
                           "PROPERTIES": "\n".join(properties), "OWNERSHIP": ownership,
                           "METHODS": methods, "CHANGES": changes, "MERGER": merger, "GAME_SELECTION": game_selection, "GAME_ROWS": game_rows, "ANCESTOR": ancestor, "GAMES": registrations["games"],
                           "MAPPING": registrations["mapping"], "MODE": registrations["mouse.mode"],
                           "SPEED": registrations["mouse.speed"], "HAPTICS": registrations["haptics"]}.items():
            fixture = fixture.replace(key, value)
        fixture = fixture.replace("private ", "")
        fixture = re.sub(r"(?<![.\w])(changeMode|changeSpeed|changeFeedback)\(", r"self.\1(", fixture)
        fixture = fixture.replace("func self.", "func ")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            swift, binary = folder / "main.swift", folder / "controls-check"
            swift.write_text(policy + fixture)
            subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(folder / "cache"), str(swift), "-o", str(binary)], check=True, timeout=90)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
