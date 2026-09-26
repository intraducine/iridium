#!/usr/bin/env python3
"""Protect the touch-controller layout, XInput merge, and input settings wiring."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "Iridium"
assets = app / "Assets.xcassets"

layout = (app / "Input/TouchControllerLayout.swift").read_text()
overlay = (app / "Input/TouchControllerOverlay.swift").read_text()
editor = (app / "Input/TouchControllerLayoutEditorView.swift").read_text()
settings = (app / "Input/InputSettingsViews.swift").read_text()
player = (app / "Views/RuntimePlayerView.swift").read_text()
app_settings = (app / "Views/SettingsView.swift").read_text()
game_detail = (app / "Views/GameDetailView.swift").read_text()
controller = (root / "MadeiraSupport/MadeiraController.swift").read_text()
runtime = (root / "MadeiraSupport/MadeiraRuntimeAdapter.swift").read_text()

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

for token in [
    "TouchControllerButton", "TouchControllerTrigger", "TouchControllerStick",
    "TouchControllerDPad", "source: control.id", "@MainActor",
    "setTouchButton", "setTouchTrigger", "setTouchStick",
    "MoonlightTouchArea(round: true", "MoonlightTouchArea(round: false",
    "override func touchesBegan(_ touches: Set<UITouch>",
    "override func touchesMoved(_ touches: Set<UITouch>",
    "override func touchesEnded(_ touches: Set<UITouch>",
    "override func touchesCancelled(_ touches: Set<UITouch>",
    "onEvent?(.began, touch.location(in: self))",
    "onEvent?(.ended, touch.location(in: self))",
    "0.10 - (ProcessInfo.processInfo.systemUptime - pressedAt)",
    "touchControllerRenderedSize(control, minimumDimension: minimumDimension)",
    "func touchControllerRenderedSize",
]:
    assert token in overlay, token
assert "private func controlSize(" not in overlay
assert "editorControlSize" not in editor
assert "touchControllerRenderedSize(" in editor
assert "MoonlightStickArtwork(size: renderedSize" in editor
assert "MoonlightDPadArtwork(size: renderedSize)" in editor
assert "DragGesture(minimumDistance: 0, coordinateSpace: .local)" not in overlay
for image in [
    "AButton", "BButton", "XButton", "YButton", "UpButton", "DownButton",
    "LeftButton", "RightButton", "L1", "L2", "L3", "R1", "R2", "R3",
    "StartButton", "SelectButton", "StickInner", "StickOuter",
]:
    assert (assets / f"{image}.imageset/Contents.json").is_file(), image
    assert f'"{image}"' in overlay, image

# Touch-controller players get a real right-edge menu hit target. A tap opens the
# player menu; a drag repositions it vertically so it can be moved off a game control.
for token in [
    "IridiumTouchControllerPlayerMenuRequested", "playerMenuRequested",
    '@AppStorage("IridiumPlayerMenuHandleYFraction")',
    ".frame(width: 44, height: 72)", ".contentShape(Rectangle())",
    ".zIndex(10_000)",
    'DragGesture(minimumDistance: 0, coordinateSpace: .named("touch-controller-overlay"))',
    "distance <= 8", "menuHandleYFraction = Double",
    "NotificationCenter.default.post(name: Self.playerMenuRequested",
    'accessibilityLabel("Player Menu")',
]:
    assert token in overlay, token
for obsolete in ["startedAtEdge", "movedInward", "mostlyHorizontal", "Swipe inward from the right edge"]:
    assert obsolete not in overlay, obsolete

for token in [
    'Label("Add Control"', 'Button("Reset"', 'Button("Delete"',
    'Text("Size")', 'Text("Opacity")', 'Toggle("Hidden"',
    'DragGesture(minimumDistance: 0',
]:
    assert token in editor, token

for token in [
    "private struct TouchState", "buttonSources: [UInt16: Set<UUID>]",
    "leftTriggerSources: [UUID: Float]", "leftStickSources: [UUID: StickSample]",
    "touchConnected = index == 0", "touchInput = touchConnected && touch.active && inputActive",
    "touch.setButton(source:",
    "touch.setTrigger(source:", "touch.setStick(source:",
    "max(physicalLT, touchInput ? touch.leftTrigger : 0)",
    "max(physicalRT, touchInput ? touch.rightTrigger : 0)",
    "let touchLeft = touchInput ? touch.leftStick : nil",
    "let touchRight = touchInput ? touch.rightStick : nil",
]:
    assert token in controller, token

assert "if !acceptingInput" in controller
assert "touch.releaseInputs()" in controller
assert "IridiumTouchControllerInputReset" in controller
assert "UIScene.willDeactivateNotification" in controller
assert 'reason: "scene-deactivated"' in controller
assert "touch.active = touchControlsEnabled" in controller
assert "[Input] Touch button received:" in controller
assert "[Input] Touch stick received:" in controller
assert "touchControlsEnabled: TouchControllerLayoutStore.isEnabled(for: gameID)" in runtime
assert runtime.index("MadeiraController.start(") < runtime.index("wine_process_start(prefix.path)")
assert "IridiumTouchControllerInputReset" in overlay
assert ".id(resetGeneration)" in overlay
assert "resetGeneration &+= 1" in overlay

assert 'Button("Input Settings", systemImage: "gamecontroller")' in player
assert 'TouchControllerOverlay(gameID: session.gameID)' in player
assert 'TouchControllerOverlay.playerMenuRequested' in player
assert 'if !touchControlsEnabled || controlsVisible' in player
assert '@State private var showPerformance = false' in player
assert 'Toggle("Pin Performance HUD", isOn: $showPerformance)' in player
assert 'runtimePlayer: madeiraPresentStalled' in player
assert 'runtimePlayer: madeiraPresentResumed' in player
assert ".sheet(isPresented: $isShowingControls, onDismiss:" in player
assert "showKeyboardAfterControlsDismiss" in player
assert "DispatchQueue.main.async { [weak self] in self?.applyResponderOwnership() }" in player
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

print("PASS touch-controller source wiring; game input still needs a device test")
