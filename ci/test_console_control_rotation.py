"""Check the shipping console adapter, including actual Madeira control sizes."""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/Madeira/app/Madeira/ContentView.swift'
PLAYER = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsolePlayer.swift'
CONTROLS = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleControls.swift'


def production_geometry():
    upstream = UPSTREAM.read_text()
    # Use the actual normalized model and action-specific dimensions rather
    # than a parallel reimplementation of the buttons' displayed geometry.
    start = upstream.index('enum ControlAction:')
    end = upstream.index('final class TouchControlsModel:', start)
    controls = CONTROLS.read_text()
    return ('import Foundation\n' + upstream[start:end]
            + '\nenum TouchControlsModel { static let baseDiameter: CGFloat = 64 }\n'
            + controls[controls.index('enum IridiumConsoleControlLayout {'):])


CASES = r'''
func frame(_ control: TouchControl, screen: CGSize, scale: Double) -> CGRect {
    let size = control.action.controlSize(diameter: 64 * CGFloat(control.scale * scale))
    return CGRect(x: CGFloat(control.nx) * screen.width - size.width / 2,
                  y: CGFloat(control.ny) * screen.height - size.height / 2,
                  width: size.width, height: size.height)
}
let screens = [CGSize(width: 375, height: 647), CGSize(width: 667, height: 375),
               CGSize(width: 320, height: 548), CGSize(width: 724, height: 354),
               CGSize(width: 393, height: 759), CGSize(width: 734, height: 372),
               CGSize(width: 1024, height: 722)]
for profile in [IridiumPlayerProfile.psp, .gameBoy] {
    for screen in screens {
        let bounds = CGRect(origin: .zero, size: screen)
        let controls = IridiumConsoleControlLayout.defaults(profile: profile, bounds: bounds)
        for editing in [false, true] {
            let frames = controls.map {
                frame(IridiumConsoleControlLayout.fitted($0, screen: screen, sizeScale: 1, editing: editing),
                      screen: screen, scale: 1)
            }
            for (index, target) in frames.enumerated() {
                precondition(bounds.contains(target), "Actual default face must fit after rotation")
                for other in frames.dropFirst(index + 1) {
                    let overlap = target.intersection(other)
                    precondition(overlap.isNull || overlap.width == 0 || overlap.height == 0,
                                 "Actual default faces must not overlap, including in the editor")
                }
            }
        }
        let translated = IridiumConsoleControlLayout.defaults(profile: profile,
            bounds: CGRect(origin: CGPoint(x: 44, y: 24), size: screen))
        precondition(zip(controls, translated).allSatisfy {
            abs($0.nx - $1.nx) < 0.0001 && abs($0.ny - $1.ny) < 0.0001 && $0.scale == $1.scale
        }, "Safe-area origin must not leak into normalized control positions")
    }
}

// Arbitrary saved controls are fitted only for presentation, including large
// global/control scales and positions at every edge. Repeated rotation must
// neither rewrite custom values nor clip the selected control's delete handle.
for action in ["DPad", "LS", "A", "LB", "Menu"] {
    for position in [0.0, 0.03, 0.5, 0.97, 1.0] {
        for scale in [0.5, 1.0, 3.0] {
            let saved = TouchControl(nx: position, ny: position, scale: scale, action: .pad(action))
            let original = saved
            for screen in screens + [CGSize(width: 240, height: 160)] {
                for global in [0.5, 1.0, 2.0] {
                    for editing in [false, true] {
                        let projected = IridiumConsoleControlLayout.fitted(saved, screen: screen,
                                                                         sizeScale: global, editing: editing)
                        let visible = frame(projected, screen: screen, scale: global)
                        let bounds = CGRect(origin: .zero, size: screen).insetBy(dx: -0.0001, dy: -0.0001)
                        precondition(bounds.contains(visible), "Custom face must stay fully on-screen")
                        if editing {
                            let handle = CGRect(x: visible.maxX - 14, y: visible.minY - 8, width: 22, height: 22)
                            precondition(bounds.contains(handle), "Editor delete handle must remain reachable")
                        }
                        precondition(saved == original && projected.id == saved.id && projected.action == saved.action,
                                     "Render fitting must not mutate custom layout identity or data")
                    }
                }
            }
        }
    }
}
print("PASS: shipping console defaults and custom control projection fit portrait, landscape and editor bounds")
'''


@unittest.skipUnless(UPSTREAM.is_file(), 'Pinned Madeira source required')
class ConsoleControlRotationTests(unittest.TestCase):
    def test_rotation_releases_inputs_before_refreshing_defaults(self):
        source = PLAYER.read_text()
        start = source.index('.onChange(of: geometry.size)')
        callback = source[start:source.index('.onAppear', start)]
        self.assertLess(callback.index('releaseInput()'), callback.index('controls.iridiumResizeConsole'))
        release = source[source.index('    private func releaseInput()'):]
        self.assertIn('inputGeneration &+= 1', release)
        self.assertIn('session.resetInput()', release)
        self.assertIn('TouchControlsOverlay(iridiumEmbedded: true).id(inputGeneration)', source)

    def test_projection_and_editor_hit_surface_use_shipping_canvas(self):
        spec = importlib.util.spec_from_file_location('rotation_frontend', ROOT / 'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(frontend)
        generated = frontend.overlay('ContentView.swift', UPSTREAM.read_text())
        self.assertIn('TouchControlButton(control: iridiumConsole\n', generated)
        self.assertIn('IridiumConsoleControlLayout.fitted(c, screen: screen, sizeScale: m.sizeScale, editing: m.editing)', generated)
        self.assertIn('.background { if m.editing { Color.clear.contentShape(Rectangle()) } }', generated)
        self.assertIn('TouchPadSurface(control: control.id, action: action)', generated)
        self.assertIn('IridiumConsoleControlSurface(control: control.id, action: action)', generated)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable console rotation geometry')
    def test_actual_control_dimensions_fit_rotated_bounds(self):
        with tempfile.TemporaryDirectory(prefix='iridium-console-rotation-') as directory:
            root = Path(directory)
            source = root / 'main.swift'
            source.write_text(production_geometry() + CASES)
            executable = root / 'ConsoleRotation'
            subprocess.run(['swiftc', '-swift-version', '5',
                            str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift'),
                            str(source), '-o', str(executable)], check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
