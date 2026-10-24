"""Exercise the shipped control schema and visual math, without changing input."""
from host_tests import module_cache
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('opacity_frontend', ROOT / 'ci/madeira-frontend.py')
FRONTEND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FRONTEND)


class ControlOpacityTests(unittest.TestCase):
    def generated(self):
        return FRONTEND.overlay('ContentView.swift', (ROOT / 'ci/fixtures/madeira-build43/app/Madeira/ContentView.swift').read_text())

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_shipping_schema_legacy_presets_and_visual_state(self):
        generated = self.generated()
        model = generated[generated.index('enum ControlAction:'):generated.index('final class TouchControlsModel:')]
        presets = (ROOT / 'iridium/apps/ios/App/Controls/TouchControlPresets.swift').read_text()
        preset = presets[presets.index('struct ControlPreset:'):presets.index('struct ControlPresetScreen:')]
        fixture = r'''
let encoder = JSONEncoder(), decoder = JSONDecoder()
var control = TouchControl(action: .pad("A"))
let legacy = try encoder.encode(control)
let legacyObject = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
precondition(!legacyObject.keys.contains("opacity"))
let old = try decoder.decode(TouchControl.self, from: legacy)
precondition(old.opacity == nil && IridiumControlOpacity.normalized(old.opacity) == 1)
precondition(IridiumControlOpacity.visual(control: nil, layout: 0.78, pressed: false) == 0.78)
precondition(IridiumControlOpacity.visual(control: nil, layout: 0.78, pressed: true) == 0.78)
let oldSize = control.action.controlSize(diameter: 64 * control.scale)
control.opacity = 0.25
let saved = try decoder.decode(TouchControl.self, from: encoder.encode(control))
precondition(saved == control && saved.opacity == 0.25)
let preset = ControlPreset(id: "fixture", name: "Fixture", controls: [saved])
let loaded = try decoder.decode(ControlPreset.self, from: encoder.encode(preset))
precondition(loaded.controls == [control])
for value in [0.0, 0.15, 0.25, 0.75, 1.0, 2.0, Double.nan, Double.infinity] {
    control.opacity = value
    precondition(control.action.controlSize(diameter: 64 * control.scale) == oldSize)
    for layout in [0.0, 0.15, 0.78, 1.0, Double.nan] {
        let idle = IridiumControlOpacity.visual(control: value, layout: layout, pressed: false)
        let pressed = IridiumControlOpacity.visual(control: value, layout: layout, pressed: true)
        precondition(idle.isFinite && idle >= 0.15 && idle <= 1)
        precondition(pressed >= max(0.55, idle) && pressed <= 1)
    }
}
print("PASS shipping optional opacity schema, legacy default, preset round-trip, visible floor, pressed feedback and unchanged geometry")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.swift'; main.write_text('import Foundation\n' + model + preset + fixture)
            executable = root / 'check'
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'),
                            str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift'), str(main), '-o', str(executable)], check=True)
            result = subprocess.run([str(executable)], text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())

    def test_actual_editor_and_visual_layer_keep_native_hit_surfaces_opaque(self):
        text = self.generated()
        self.assertEqual(text.count('accessibilityIdentifier("controlOpacitySlider")'), 1)
        self.assertIn('LabeledContent("Button opacity"', text)
        self.assertIn('m.controls[i].opacity = IridiumControlOpacity.normalized(value)', text)
        self.assertNotIn('.opacity(session && !m.editing', text)
        self.assertIn('iridiumLayoutOpacity: iridiumSettings ? m.iridiumSettingsOpacity : session && !m.editing', text)
        button = text[text.index('struct TouchControlButton:'):text.index('    /// 8-way snap. Screen y grows downward')]
        alpha = button.index('.opacity(IridiumControlOpacity.visual(')
        self.assertLess(alpha, button.index('.overlay(outline.stroke'))
        self.assertLess(alpha, button.index('TouchPadSurface(control:'))
        self.assertLess(alpha, button.index('IridiumConsoleControlSurface(control:'))
        self.assertIn('layout: iridiumLayoutOpacity, pressed: isDown', button)
        geometry = text[text.index('func hitsInteractive('):text.index('/// Click-through')]
        self.assertNotIn('opacity', geometry)


if __name__ == '__main__': unittest.main()
