"""Shipping pointer adapter: contact ownership and cancellation boundaries."""
from pathlib import Path
import unittest
import madeira_player_presentation as presentation

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'vendor/Madeira/app/Madeira/ContentView.swift'


@unittest.skipUnless(SOURCE.is_file(), 'Pinned Madeira source required')
class TouchMouseOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = presentation.touch_mouse(SOURCE.read_text())

    def method(self, name, following):
        start = self.text.index('    override func ' + name, self.text.index('private var tmgSwallowed'))
        return self.text[start:self.text.index(following, start)]

    def test_admission_is_scoped_to_surface_and_content(self):
        body = self.method('touchesBegan', '    override func touchesMoved')
        self.assertIn('$0.view === self && $0.type != .indirectPointer && gameRect().contains', body)
        self.assertIn('touches.subtracting(eligibleTouches)', body)
        self.assertIn('iridiumPointerContacts[ObjectIdentifier(touch)] = touch', body)
        self.assertLess(body.index('HardwareInput.shared.interceptTouches'), body.index('eligibleTouches'))

    def test_movement_and_release_require_admitted_contact(self):
        for name, following in [('touchesMoved', '    override func touchesEnded'),
                                ('touchesEnded', '    override func touchesCancelled')]:
            body = self.method(name, following)
            self.assertIn('let touches = Set(filteredTouches.filter { iridiumPointerContacts[ObjectIdentifier($0)] != nil })', body)
            self.assertIn('guard !touches.isEmpty else { return }', body)
        ended = self.method('touchesEnded', '    override func touchesCancelled')
        self.assertIn('iridiumPointerContacts.removeValue(forKey: ObjectIdentifier(touch))', ended)

    def test_multitouch_excludes_controls_letterbox_and_revoked_contacts(self):
        start = self.text.index('    private func activeTouches(')
        body = self.text[start:self.text.index('\n    }', start)]
        self.assertIn('iridiumPointerContacts.values.filter', body)
        self.assertNotIn('event?.allTouches', body)

    def test_explicit_disabled_override_remains_honored(self):
        self.assertIn('guard TouchMouseGate.mode == .off || LibraryModel.shared.blocksGameplayTouch', self.text)

    def test_revoke_releases_buttons_and_swallows_until_lift(self):
        start = self.text.index('    func iridiumReleasePointer()')
        body = self.text[start:self.text.index('\n    }', start)]
        self.assertIn('tmgSwallowed.formUnion(iridiumPointerContacts.keys)', body)
        self.assertIn('iridiumPointerContacts.removeAll()', body)
        self.assertIn('winios_post_touch_up', body)
        self.assertIn('if dragActive { postPointer(F_LUP) }', body)
        self.assertIn('tmResetGesture()', body)
        self.assertIn('touchGeneration += 1', body)
        self.assertIn('if window == nil { iridiumReleasePointer() }', self.text)
        self.assertIn('if editing { MetalBackedView.keyboardTarget?.iridiumReleasePointer() }', self.text)

    def test_trackpad_drag_owner_releases_before_multitouch_return(self):
        began = self.method('touchesBegan', '    override func touchesMoved')
        ended = self.method('touchesEnded', '    override func touchesCancelled')
        self.assertIn('self.dragActive = true\n            self.iridiumTrackpadHadDrag = true', began)
        release = 'if twoFingerActive, dragActive, let owner = dragTouch, touches.contains(owner) {'
        self.assertIn(release, ended)
        release_start = ended.index(release)
        multitouch_start = ended.index('        if twoFingerActive {', release_start)
        block = ended[release_start:multitouch_start]
        self.assertEqual(block.count('postPointer(F_LUP)'), 1)
        self.assertIn('dragActive = false; dragTouch = nil', block)
        # History lasts until all contacts lift, including when the owner lifts
        # first or another finger joins after the owner was released.
        self.assertIn('if !iridiumTrackpadHadDrag && !twoFingerMoved', ended)
        self.assertIn('if iridiumPointerContacts.isEmpty { iridiumTouchMode = nil; iridiumMotion.reset(); iridiumTrackpadHadDrag = false }', ended)
        self.assertNotIn('iridiumTrackpadHadDrag = false', began)

    def test_console_suspends_separate_windows_overlay(self):
        text = presentation.shared_console(presentation.controls(SOURCE.read_text()))
        self.assertIn('if (landscape || iridiumConsole) && !iridiumSuspended {', text)
        self.assertIn('!iridiumEmbedded && (console.isActive || m.iridiumConsoleScope != nil)', text)
        self.assertIn('guard !iridiumEmbedded else { return }', text)
        self.assertIn('guard !console.isActive, m.iridiumConsoleScope == nil else {', text)
        self.assertIn('guard !iridiumEmbedded, !console.isActive, m.iridiumConsoleScope == nil, m.needsDefaultLayout', text)
        self.assertIn('.onChange(of: console.isActive) { _, _ in configureGamepad(landscape: landscape) }', text)
        self.assertIn('if !iridiumEmbedded { GamepadInput.shared.configureTouch(controls: [])', text)

    def test_cancel_any_owned_finger_releases_whole_gesture(self):
        body = self.method('touchesCancelled', '\n}\n\n/// Arrow-key button')
        self.assertIn('touches.contains(where: { iridiumPointerContacts[ObjectIdentifier($0)] != nil })', body)
        self.assertIn('iridiumReleasePointer()', body)
        self.assertIn('tmgSwallowed.remove(ObjectIdentifier(touch))', body)
        self.assertLess(body.index('HardwareInput.shared.interceptTouches'), body.index('iridiumReleasePointer()'))


if __name__ == '__main__':
    unittest.main()
