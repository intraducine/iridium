import GameController
import IridiumCore
import SwiftUI

struct InputSettingsView: View {
    @AppStorage(TouchControllerLayoutStore.defaultEnabledKey) private var touchControlsDefaultEnabled = false
    @AppStorage("IridiumMouseSensitivity") private var mouseSensitivity = 1.0
    @AppStorage("IridiumScrollSensitivity") private var scrollSensitivity = 1.0

    var body: some View {
        List {
            Section("On-Screen Controller") {
                Toggle("Enable for New Games", isOn: $touchControlsDefaultEnabled)
                Text("Games without their own override use this setting. Each game can still enable or disable its touch controller separately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse") {
                Stepper(value: $mouseSensitivity, in: 0.25...4, step: 0.25) {
                    sensitivityLabel("Mouse sensitivity", value: mouseSensitivity)
                }
                .accessibilityIdentifier("mouseSensitivity")

                Stepper(value: $scrollSensitivity, in: 0.25...4, step: 0.25) {
                    sensitivityLabel("Scroll sensitivity", value: scrollSensitivity)
                }
                .accessibilityIdentifier("scrollSensitivity")
            }

            Section("About Input") {
                Text("Physical controllers and the on-screen controller share Iridium's XInput bridge. Touch layouts are configured per game from Game Options → Controls or from the player menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Input")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }

    @ViewBuilder
    private func sensitivityLabel(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value.formatted(.number.precision(.fractionLength(2))) + "×")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct GameInputSettingsView: View {
    let game: GameRecord
    private let deviceKeyboardVisible: Binding<Bool>?

    @State private var touchControlsEnabled: Bool
    @State private var controllerCount = GCController.controllers().count
    @State private var keyboardConnected = GCKeyboard.coalesced != nil
    @State private var mouseCount = GCMouse.mice().count
    @State private var confirmingReset = false
    @AppStorage("IridiumMouseSensitivity") private var mouseSensitivity = 1.0
    @AppStorage("IridiumScrollSensitivity") private var scrollSensitivity = 1.0

    init(game: GameRecord, deviceKeyboardVisible: Binding<Bool>? = nil) {
        self.game = game
        self.deviceKeyboardVisible = deviceKeyboardVisible
        _touchControlsEnabled = State(initialValue: TouchControllerLayoutStore.isEnabled(for: game.id))
    }

    var body: some View {
        List {
            Section("On-Screen Controller") {
                Toggle("Show On-Screen Controller", isOn: $touchControlsEnabled)
                    .accessibilityIdentifier("touchControllerEnabled")

                MenuNavigationLink {
                    TouchControllerLayoutEditorView(gameID: game.id, gameTitle: game.title)
                } label: {
                    Label("Customize Layout", systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("touchControllerCustomize")

                MenuButton(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Reset Layout", systemImage: "arrow.counterclockwise")
                }

                Text("Move, resize, hide, remap, or add Xbox-style controls. This layout is saved only for \(game.title).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let deviceKeyboardVisible {
                Section("Device Keyboard") {
                    Toggle("Show Device Keyboard", isOn: deviceKeyboardVisible)
                        .accessibilityIdentifier("deviceKeyboard")
                    Text("Use this when a Windows text field needs input and no hardware keyboard is connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mouse") {
                Stepper(value: $mouseSensitivity, in: 0.25...4, step: 0.25) {
                    sensitivityLabel("Mouse sensitivity", value: mouseSensitivity)
                }
                .accessibilityIdentifier("mouseSensitivity")

                Stepper(value: $scrollSensitivity, in: 0.25...4, step: 0.25) {
                    sensitivityLabel("Scroll sensitivity", value: scrollSensitivity)
                }
                .accessibilityIdentifier("scrollSensitivity")
            }

            Section("Connected Devices") {
                MenuValue("Controllers", value: controllerCount == 0 ? "None detected" : "\(controllerCount) connected")
                MenuValue("Keyboard", value: keyboardConnected ? "Connected" : "None detected")
                MenuValue("Mouse", value: mouseCount == 0 ? "None detected" : "\(mouseCount) connected")
            }
        }
        .navigationTitle("Input Settings")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .onChange(of: touchControlsEnabled) { _, enabled in
            TouchControllerLayoutStore.setEnabled(enabled, for: game.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in refreshDevices() }
        .onAppear {
            touchControlsEnabled = TouchControllerLayoutStore.isEnabled(for: game.id)
            refreshDevices()
        }
        .confirmationDialog(
            "Reset on-screen controls?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Layout", role: .destructive) {
                TouchControllerLayoutStore.resetLayout(for: game.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The layout will return to Iridium's default Xbox-style controller.")
        }
    }

    @ViewBuilder
    private func sensitivityLabel(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value.formatted(.number.precision(.fractionLength(2))) + "×")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func refreshDevices() {
        controllerCount = GCController.controllers().count
        keyboardConnected = GCKeyboard.coalesced != nil
        mouseCount = GCMouse.mice().count
    }
}
