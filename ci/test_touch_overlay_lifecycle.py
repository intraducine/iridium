"""Run shipping overlay registration and touch state across session transitions."""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TouchOverlayLifecycleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_generated_registration_keeps_same_id_a_and_stick_controls_working(self):
        spec = importlib.util.spec_from_file_location('overlay_lifecycle_frontend', ROOT/'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        text = frontend.overlay('ContentView.swift', (frontend.UPSTREAM/'app/Madeira/ContentView.swift').read_text())
        self.assertIn('@Published var iridiumConsoleScope: UUID?', text)
        self.assertIn('.onChange(of: m.iridiumConsoleScope) { _, _ in configureGamepad(landscape: landscape) }', text)
        self.assertIn('.onChange(of: iridiumController.hidesTouchControls)', text)
        physical = (ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumPlayerControls.swift').read_text()
        self.assertIn('UIApplication.didBecomeActiveNotification', physical)
        model = text[text.index('enum ControlAction:'):text.index('final class TouchControlsModel:')]
        start = text.index('    private func configureGamepad(landscape: Bool) {')
        method = text[start:text.index('\n    /// ml1970:', start)].replace('private func', 'func')
        touch = (frontend.UPSTREAM/'app/Madeira/TouchGamepad.swift').read_text()
        touch = touch[touch.index('struct GamepadSample:'):touch.index('// MARK: - UIKit touch lifetime')]
        fixture = r'''
enum TouchMouseGate { static var padOverlay = false }
final class GamepadInput {
    static let shared = GamepadInput(); static let enabled = true
    var state = TouchGamepadState()
    func configureTouch(controls: Set<UUID>, acceptingInput: Bool = true) {
        state.configure(controls, acceptingInput: acceptingInput)
    }
}
final class Model {
    var controls = [TouchControl(action: .pad("A")), TouchControl(action: .pad("LS"))]
    var visible = true, editing = false
    var iridiumConsoleScope: UUID?
    var iridiumSettingsContext: UUID?
}
final class Console { var isActive = false }
final class Library { var blocksGameplayTouch = true }
final class Controller { var hidesTouchControls = false }
final class Overlay {
    let m = Model(), console = Console(), library = Library(), iridiumController = Controller()
    var iridiumEmbedded = false
'''
        cases = r'''
}
let overlay = Overlay(), pad = GamepadInput.shared
let ids = overlay.m.controls.map(\.id), owners = [UUID(), UUID()]
func press(_ expected: Bool) {
    pad.state.update(owner: owners[0], control: ids[0], value: TouchPadAction.sample("A"))
    pad.state.update(owner: owners[1], control: ids[1], value: TouchPadAction.sample("LS", x: 1))
    precondition(pad.state.sample.buttons == (expected ? 0x1000 : 0))
    precondition(pad.state.sample.lx == (expected ? 32767 : 0))
}
func refresh() { overlay.configureGamepad(landscape: true) }
refresh(); press(false); precondition(!pad.state.connected)
pad.state.reserved = true // The unchanged upstream runtime owns session reservation.
overlay.library.blocksGameplayTouch = false; refresh(); press(true)
precondition(pad.state.connected && TouchMouseGate.padOverlay)
overlay.library.blocksGameplayTouch = true; refresh(); press(false)
precondition(pad.state.connected && !TouchMouseGate.padOverlay)
overlay.library.blocksGameplayTouch = false; refresh(); press(true)
overlay.iridiumController.hidesTouchControls = true; refresh(); press(false)
precondition(pad.state.connected && !TouchMouseGate.padOverlay)
overlay.iridiumController.hidesTouchControls = false; refresh(); press(true) // Use touch controls.
overlay.m.editing = true; refresh(); press(false)
overlay.m.editing = false; refresh(); press(true)
overlay.m.iridiumSettingsContext = UUID(); refresh(); press(false)
overlay.m.iridiumSettingsContext = nil; refresh(); press(true)
overlay.console.isActive = true; overlay.m.iridiumConsoleScope = UUID(); refresh(); press(false)
overlay.console.isActive = false; refresh(); press(false) // Retained scope still owns controls.
overlay.m.iridiumConsoleScope = nil; refresh(); press(true) // Published scope hook refreshes unchanged IDs.
precondition(overlay.m.controls.map(\.id) == ids)
overlay.m.controls[0].opacity = 0.15; refresh(); press(true)
precondition(IridiumControlOpacity.visual(control: 0.15, layout: 0.78, pressed: true) >= 0.55)
overlay.m.visible = false; refresh(); press(false)
overlay.m.visible = true; refresh(); press(true)
overlay.configureGamepad(landscape: false); press(false)
refresh(); press(true)
print("PASS shipping registration/state: A+LS, launch, running, menu/resume, physical auto-hide/Use touch, editor, console/retained scope to Windows with identical IDs, opacity and rotation")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root/'main.swift'; binary = root/'check'
            main.write_text('import Foundation\n' + model + touch + fixture + method + cases)
            result = subprocess.run(['swiftc', '-module-cache-path', str(root/'cache'),
                                     str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift'),
                                     str(main), '-o', str(binary)], text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__': unittest.main()
