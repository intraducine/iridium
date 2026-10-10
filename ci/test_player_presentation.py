"""Execute app-owned layout/state logic and exercise the shipping Windows generator."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('player_frontend', ROOT / 'ci/madeira-frontend.py')
FRONTEND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FRONTEND)
UPSTREAM = Path(os.environ.get('IRIDIUM_MADEIRA_SOURCE', ROOT / 'vendor/Madeira/app/Madeira'))


class PlayerPresentationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable player geometry and state tests')
    def test_executable_layout_and_visual_state(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / 'player-test'
            subprocess.run(['swiftc', str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift'),
                            str(ROOT / 'iridium/apps/ios/PlayerTests/main.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=20)

    @unittest.skipUnless((UPSTREAM / 'ContentView.swift').is_file(), 'Pinned Madeira source required')
    def test_shipping_windows_adopts_shared_faces_without_replacing_input(self):
        before = (UPSTREAM / 'ContentView.swift').read_text()
        result = FRONTEND.overlay('ContentView.swift', before)
        self.assertIn('IridiumControlFace(label: label, symbol: console.isActive ? IridiumConsoleControlMapping.symbol', result)
        self.assertIn('IridiumDPadFace(vector: padVector, pressed: isDown)', result)
        self.assertIn('IridiumControlFace(label: control.action.label', result)
        self.assertIn('m.visible && !(GamepadInput.enabled && iridiumController.hidesTouchControls)', result)
        self.assertIn('guard visible && !(GamepadInput.enabled && IridiumPhysicalController.shared.hidesTouchControls)', result)
        self.assertIn('onChange(of: iridiumController.hidesTouchControls)', result)
        # The real native delivery and editable saved layout stay upstream.
        start = '    /// 8-way snap. Screen y grows downward'
        end = 'struct MappingPanel: View'
        original_input = before[before.index(start):before.index(end)]
        actual_input = result[result.index(start):result.index(end)]
        # Feedback now obeys the shared setting, while native key/mouse state
        # transitions remain byte-for-byte identical.
        original_input = original_input.replace('UIImpactFeedbackGenerator(style: .light).impactOccurred()',
                                                'IridiumControlHaptics.press()')
        self.assertEqual(original_input, actual_input)
        self.assertIn('TouchPadSurface(control: control.id, action: action)', result)
        self.assertIn('onDisappear {\n            if let keys = control.action.stickKeys { applyStick(-1, keys) }', result)
        with self.assertRaisesRegex(ValueError, 'presentation changed'):
            FRONTEND.overlay('ContentView.swift', before.replace('let ids = landscape && m.visible', 'let ids = false'))

    @unittest.skipUnless((UPSTREAM / 'Library.swift').is_file(), 'Pinned Madeira source required')
    def test_windows_menu_uses_same_app_components(self):
        result = FRONTEND.overlay('Library.swift', (UPSTREAM / 'Library.swift').read_text())
        for component in ['IridiumPlayerMenuHeader', 'IridiumPlayerMenuRow', 'IridiumPlayerMenuNavigation.next']:
            self.assertIn(component, result)
        self.assertIn('model.requestQuit()', result)
        self.assertNotIn('.confirmationDialog("Close this game?"', result)
        self.assertIn('IridiumPlayerCloseConfirmation(selection:', result)
        self.assertIn('switch closeConfirmation.receive(command)', result)
        self.assertIn('if confirmClose { iridiumMenuNavigate(command) }', result)
        self.assertIn('controller: GamepadInput.enabled && iridiumController.isActive', result)
        self.assertIn('if menuPage == "Control Settings" {', result)
        self.assertIn('includeSettings: true', result)
        self.assertIn('if !open { bindsPage = false; menuPage = "Session"; menuFocus = "Resume"; confirmClose = false }', result)
        self.assertIn('guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage)', result)
        self.assertIn('.onKeyPress(.escape, phases: .down)', result)
        self.assertIn('.onKeyPress(.return, phases: .down)', result)
        router = result[result.index('    private func iridiumMenuNavigate('):]
        self.assertLess(router.index('if menuPage == "Controls" {'), router.index('guard menuPage == "Session"'))
        self.assertIn('LibraryController.shared.configure(enabled: model.enabled, ownsInput: open)', result)

    def test_shipping_source_inventory_includes_shared_implementation(self):
        names = {p.name for p in [*FRONTEND.FRONTEND.glob('*.swift'), *FRONTEND.RUNTIME_SUPPORT.glob('*.swift')]}
        for name in ['IridiumPlayerControls.swift', 'IridiumPlayerMenu.swift', 'IridiumPlayerLayout.swift']:
            self.assertIn(name, names)
        player = (FRONTEND.FRONTEND / 'IridiumConsolePlayer.swift').read_text()
        self.assertIn('TouchControlsOverlay(iridiumEmbedded: true).id(inputGeneration)', player)
        self.assertIn('controls.iridiumBeginConsole(game.id', player)
        self.assertIn('controls.iridiumEndConsole()', player)
        self.assertIn('controls.editing = true', player)
        self.assertIn('session.resetInput()', player)
        console = (FRONTEND.FRONTEND / 'IridiumConsoleControls.swift').read_text()
        self.assertIn('IridiumControlTouchSurface', console)
        self.assertIn('source: "touch.layout." + control.uuidString', console)
        self.assertIn('session.setButton(bit, pressed: false, source: source)', console)
        controls = (FRONTEND.FRONTEND / 'IridiumPlayerControls.swift').read_text()
        self.assertIn('if let next = state.update(enabled ? value : 0) {', controls)
        self.assertIn('if !wasEngaged && next != 0 { IridiumControlHaptics.press() }', controls)
        self.assertIn('input(next)', controls)
        self.assertIn('onChange(of: controller.hidesTouchControls)', player)
        self.assertIn('let source = "accessibility.layout." + control.uuidString', console)
        self.assertNotIn('landscapePSP', player)
        self.assertNotIn('.confirmationDialog(', player)
        self.assertIn('switch closeConfirmation.receive(value)', player)
        self.assertIn('IridiumPlayerCloseConfirmation(selection:', player)
        self.assertIn('.onKeyPress(.escape, phases: .down)', player)
        # Help and menu are overlays; they never participate in viewport layout.
        self.assertLess(player.index('let layout = IridiumPlayerLayout'), player.index('if menuVisible { menu'))


if __name__ == '__main__':
    unittest.main()
