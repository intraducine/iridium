#!/usr/bin/env python3
"""Protect the touch-controller layout, XInput merge, and input settings wiring."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "Iridium"

layout = (app / "Input/TouchControllerLayout.swift").read_text()
overlay = (app / "Input/TouchControllerOverlay.swift").read_text()
editor = (app / "Input/TouchControllerLayoutEditorView.swift").read_text()
settings = (app / "Input/InputSettingsViews.swift").read_text()
player = (app / "Views/RuntimePlayerView.swift").read_text()
app_settings = (app / "Views/SettingsView.swift").read_text()
game_detail = (app / "Views/GameDetailView.swift").read_text()
controller = (root / "MadeiraSupport/MadeiraController.swift").read_text()

# The persisted model is per game, versioned, normalized, and contains the full
# standard Xbox surface Iridium can currently represent through XInput.
for token in [
    "TouchControllerLayoutStore", "layoutKey(gameID:", "enabledKey(gameID:",
    "centerX", "centerY", "opacity", "isHidden", "xboxDefault",
    "case leftStick", "case rightStick", "case dpad", "case a", "case b",
    "case x", "case y", "case leftBumper", "case rightBumper",
    "case leftTrigger", "case rightTrigger", "case leftStickButton",
    "case rightStickButton", "case menu", "case view",
]:
    assert token in layout, token

for mask in ["0x1000", "0x2000", "0x4000", "0x8000", "0x0100", "0x0200", "0x0040", "0x0080", "0x0010", "0x0020"]:
    assert mask in layout, mask

# Runtime controls must cover digital buttons, analog triggers/sticks, and dpad.
for token in [
    "TouchControllerButton", "TouchControllerTrigger", "TouchControllerStick",
    "TouchControllerDPad", "setTouchButton", "setTouchTrigger", "setTouchStick",
]:
    assert token in overlay, token

# The editor supports the expected customization operations.
for token in [
    'Label("Add Control"', 'Button("Reset"', 'Button("Delete"',
    'Text("Size")', 'Text("Opacity")', 'Toggle("Hidden"',
    'DragGesture(minimumDistance: 0',
]:
    assert token in editor, token

# Touch is merged into existing XInput slot zero rather than introducing a new
# guest protocol. Digital values combine; analog triggers take the stronger input;
# a currently touched stick owns that stick until released.
for token in [
    "private struct TouchState", "touchConnected = index == 0 && touch.active",
    "var buttons: UInt16 = touchInput ? touch.buttons : 0",
    "buttons |= mask", "max(physicalLT, touchInput ? touch.leftTrigger : 0)",
    "max(physicalRT, touchInput ? touch.rightTrigger : 0)",
    "touch.leftStickActive ? touch.leftX", "touch.rightStickActive ? touch.rightX",
]:
    assert token in controller, token

# Player menu is intentionally compact: detailed input controls moved behind one
# submenu, and app/game settings expose the same configuration surfaces.
assert 'Button("Input Settings", systemImage: "gamecontroller")' in player
assert 'TouchControllerOverlay(gameID: session.gameID)' in player
assert 'Stepper(value: $mouseSensitivity' not in player
assert 'Stepper(value: $scrollSensitivity' not in player
assert 'InputSettingsView()' in app_settings
assert 'GameInputSettingsView(game: game)' in game_detail
for token in [
    'Toggle("Show On-Screen Controller"', 'TouchControllerLayoutEditorView(',
    'Toggle("Show Device Keyboard"', 'Stepper(value: $mouseSensitivity',
    'Stepper(value: $scrollSensitivity',
]:
    assert token in settings, token

print("PASS customizable touch controller layout, XInput merge, and input settings wiring")
