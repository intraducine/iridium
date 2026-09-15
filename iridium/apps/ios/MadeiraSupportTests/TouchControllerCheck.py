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

# Runtime controls cover digital buttons, analog triggers/sticks, and dpad. Each
# control sends its UUID so duplicate/remapped controls do not release each other.
for token in [
    "TouchControllerButton", "TouchControllerTrigger", "TouchControllerStick",
    "TouchControllerDPad", "source: control.id", "@MainActor",
    "setTouchButton", "setTouchTrigger", "setTouchStick",
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
# guest protocol. Sources are tracked independently so duplicate A buttons,
# triggers, dpads, or sticks can be held at the same time safely.
for token in [
    "private struct TouchState", "buttonSources: [UInt16: Set<UUID>]",
    "leftTriggerSources: [UUID: Float]", "leftStickSources: [UUID: StickSample]",
    "touchConnected = index == 0 && touch.active", "touch.setButton(source:",
    "touch.setTrigger(source:", "touch.setStick(source:",
    "max(physicalLT, touchInput ? touch.leftTrigger : 0)",
    "max(physicalRT, touchInput ? touch.rightTrigger : 0)",
    "let touchLeft = touchInput ? touch.leftStick : nil",
    "let touchRight = touchInput ? touch.rightStick : nil",
]:
    assert token in controller, token

# Interrupted touch gestures must never come back as stale XInput after opening
# a menu or backgrounding the player scene.
assert "if !acceptingInput { touch.releaseInputs() }" in controller
assert "UIScene.willDeactivateNotification" in controller
assert 'reason: "scene-deactivated"' in controller

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

print("PASS customizable touch controller layout, source-safe XInput merge, lifecycle release, and input settings wiring")
