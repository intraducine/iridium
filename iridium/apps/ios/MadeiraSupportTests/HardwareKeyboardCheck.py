#!/usr/bin/env python3
"""Exercise the production keyboard gate with a recorded Wine event sink."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with (root / "Iridium/Info.plist").open("rb") as plist:
    assert plistlib.load(plist).get("UIApplicationSupportsIndirectInputEvents") is True
assert "UIApplicationSupportsIndirectInputEvents: true" in (root / "project.yml").read_text()
source = (root / "MadeiraSupport/MadeiraHardwareInput.swift").read_text()
start = source.index("    static var acceptingInput")
end = source.index("    private static var observers")
code = """
import Foundation
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, inactive }
    var applicationState = State.active
}
@MainActor enum UIAccessibility { static var isAssistiveTouchRunning = false }
@MainActor var events: [(Int32, Int32)] = []
@MainActor func winios_post_key(_ key: Int32, _ down: Int32) { events.append((key, down)) }
@MainActor var mouseEvents: [UInt32] = []
@MainActor func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) { mouseEvents.append(flags) }
@MainActor enum MadeiraHardwareInput {
    private static var held = Set<Int32>()
    private static var heldMouse = Set<UInt32>()
""" + source[start:end] + """
}
@main struct Check {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        let savedScroll = defaults.object(forKey: "IridiumScrollSensitivity")
        defer { defaults.set(savedScroll, forKey: "IridiumScrollSensitivity") }
        defaults.set(0.25, forKey: "IridiumScrollSensitivity")
        MadeiraHardwareInput.pointerCaptured = false
        let scroll = (0..<4).map { _ in MadeiraHardwareInput.scaledScrollDelta(0.125) }
        precondition(scroll.reduce(0, +) == 15)
        defaults.set(2.0, forKey: "IridiumScrollSensitivity")
        precondition(MadeiraHardwareInput.scaledScrollDelta(-1) == -240)
        precondition(MadeiraHardwareInput.scaledScrollDelta(.infinity) == 0)
        let saved = defaults.object(forKey: "IridiumMouseSensitivity")
        defer { defaults.set(saved, forKey: "IridiumMouseSensitivity") }
        defaults.set(0.25, forKey: "IridiumMouseSensitivity")
        MadeiraHardwareInput.pointerCaptured = false
        for _ in 0..<3 { precondition(MadeiraHardwareInput.scaledMouseDelta(x: 1, y: 1) == (0, 0)) }
        precondition(MadeiraHardwareInput.scaledMouseDelta(x: 1, y: 1) == (1, -1))
        defaults.set(2.0, forKey: "IridiumMouseSensitivity")
        precondition(MadeiraHardwareInput.scaledMouseDelta(x: -3, y: 4) == (-6, -8))
        precondition(MadeiraHardwareInput.scaledMouseDelta(x: .nan, y: 1) == (0, 0))
        defaults.set(100.0, forKey: "IridiumMouseSensitivity")
        precondition(MadeiraHardwareInput.scaledMouseDelta(x: 1, y: 1) == (4, -4))
        MadeiraHardwareInput.key(hid: 26, pressed: true)
        precondition(events.isEmpty)
        MadeiraHardwareInput.acceptingInput = true
        for flag: UInt32 in [0x0002, 0x0008] {
            MadeiraHardwareInput.mouseButton(flag: flag, pressed: true)
            MadeiraHardwareInput.mouseButton(flag: flag, pressed: true)
            MadeiraHardwareInput.mouseButton(flag: flag, pressed: false)
            MadeiraHardwareInput.mouseButton(flag: flag, pressed: false)
        }
        precondition(mouseEvents == [0x0002, 0x0004, 0x0008, 0x0010])
        MadeiraHardwareInput.key(hid: 26, pressed: true)
        MadeiraHardwareInput.key(hid: 26, pressed: true)
        precondition(events.count == 1 && events[0].0 == 0x57 && events[0].1 == 1)
        MadeiraHardwareInput.key(hid: 26, pressed: false)
        MadeiraHardwareInput.key(hid: 26, pressed: false)
        precondition(events.count == 2 && events[1].1 == 0)
        precondition(!MadeiraHardwareInput.usesRawMouse)
        MadeiraHardwareInput.pointerCaptured = true
        precondition(MadeiraHardwareInput.usesRawMouse)
        UIAccessibility.isAssistiveTouchRunning = true
        precondition(!MadeiraHardwareInput.usesRawMouse)
        UIAccessibility.isAssistiveTouchRunning = false
        MadeiraHardwareInput.key(hid: 225, pressed: true)
        MadeiraHardwareInput.acceptingInput = false
        precondition(events.count == 4 && events[3].0 == 0xa0 && events[3].1 == 0)
        MadeiraHardwareInput.acceptingInput = true
        UIApplication.shared.applicationState = .inactive
        MadeiraHardwareInput.key(hid: 26, pressed: true)
        precondition(events.count == 4)
        precondition(!MadeiraHardwareInput.usesRawMouse)

        UIApplication.shared.applicationState = .active
        events.removeAll()
        MadeiraHardwareInput.insertText("aA!")
        MadeiraHardwareInput.deleteBackward()
        let typed: [(Int32, Int32)] = [
            (0x41, 1), (0x41, 0),
            (0x10, 1), (0x41, 1), (0x41, 0), (0x10, 0),
            (0x10, 1), (0x31, 1), (0x31, 0), (0x10, 0),
            (0x08, 1), (0x08, 0),
        ]
        precondition(events.count == typed.count)
        for index in typed.indices {
            precondition(events[index].0 == typed[index].0 && events[index].1 == typed[index].1)
        }

        events.removeAll()
        MadeiraHardwareInput.key(hid: 225, pressed: true)
        MadeiraHardwareInput.insertText("A")
        precondition(events.count == 3)
        precondition(events[0].0 == 0xa0 && events[0].1 == 1)
        precondition(events[1].0 == 0x41 && events[1].1 == 1)
        precondition(events[2].0 == 0x41 && events[2].1 == 0)
        MadeiraHardwareInput.key(hid: 225, pressed: false)

        print("PASS keyboard fallback deduplication, software text input, menu release, inactive rejection")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="iridium-keyboard-") as directory:
    harness = Path(directory) / "Check.swift"
    harness.write_text(code)
    binary = Path(directory) / "check"
    subprocess.run(["xcrun", "swiftc", str(root / "MadeiraSupport/MadeiraKeys.swift"), str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
