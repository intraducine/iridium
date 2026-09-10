import GameController
import IridiumCore
import IridiumRuntime
import SwiftUI

struct GameControlsView: View {
    let game: GameRecord
    @State private var controllerCount = GCController.controllers().count
    @State private var keyboardConnected = GCKeyboard.coalesced != nil
    @State private var mouseCount = GCMouse.mice().count

    var body: some View {
        List {
            Section("Connected Devices") {
                MenuValue("Controllers", value: controllerCount == 0 ? "None detected" : "\(controllerCount) connected")
                MenuValue("Keyboard", value: keyboardConnected ? "Connected" : "None detected")
                MenuValue("Mouse", value: mouseCount == 0 ? "None detected" : "\(mouseCount) connected")
            }
            Section("Playing with a Controller") {
                Text("Use the game's own controls menu to choose its button layout. A connected device does not confirm that a game supports it.")
            }
            Section("Touch, Keyboard & Mouse") {
                Text("Touch can select controls in Iridium. In-game touch and pointer behavior depends on the game and runtime. A full virtual gamepad is not provided here.")
                Text("Check input events in the player diagnostics if a connected device does not respond in the game.")
            }
        }
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in refreshDevices() }
        .onAppear { refreshDevices() }
    }
    private func refreshDevices() {
        controllerCount = GCController.controllers().count
        keyboardConnected = GCKeyboard.coalesced != nil
        mouseCount = GCMouse.mice().count
    }
}

struct GameEnvironmentView: View {
    let game: GameRecord
    @ObservedObject var viewModel: AppViewModel
    @State private var isConfirmingRebuild = false

    private var prefix: PrefixRecord? {
        viewModel.prefixes.first(where: { $0.id == game.launchProfile.prefixID })
    }

    var body: some View {
        List {
            if let prefix {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Windows environment", systemImage: "shippingbox.fill")
                                .font(.headline)
                            Spacer()
                            environmentStatus(prefix.state)
                        }
                        Text("This isolated environment contains the Windows files and runtime configuration used only by \(game.title).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

                Section("Details") {
                    MenuValue("Runtime", value: prefix.runtimeName)
                    MenuValue("Storage", value: prefix.storageFootprint)
                    if let lastBootstrapStatus = prefix.lastBootstrapStatus {
                        MenuValue("Last preparation", value: lastBootstrapStatus)
                    }
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

                Section("Maintenance") {
                    MenuButton {
                        viewModel.repairPrefix(prefix)
                    } label: {
                        Label("Repair Environment", systemImage: "wrench.and.screwdriver")
                    }

                    Text("Repair keeps the environment and rechecks its required files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    MenuButton {
                        viewModel.clonePrefix(prefix)
                    } label: {
                        Label("Create Backup Copy", systemImage: "square.on.square")
                    }

                    MenuButton(role: .destructive) {
                        isConfirmingRebuild = true
                    } label: {
                        Label("Rebuild Environment", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }

                    Text("Rebuild recreates the Windows environment. Imported game and save folders are not removed, but custom environment changes may be lost.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            } else {
                ContentUnavailableView(
                    "Environment Missing",
                    systemImage: "shippingbox.and.arrow.backward",
                    description: Text("Run a compatibility check to recreate the environment assignment for this game.")
                )
            }
        }
        .navigationTitle("Windows Environment")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .confirmationDialog(
            "Rebuild \(game.title)'s environment?",
            isPresented: $isConfirmingRebuild,
            titleVisibility: .visible
        ) {
            if let prefix {
                Button("Rebuild Environment", role: .destructive) {
                    viewModel.rebuildPrefix(prefix)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Custom changes inside this Windows environment may be lost. The imported game and mapped save folder are kept.")
        }
    }

    @ViewBuilder
    private func environmentStatus(_ state: PrefixState) -> some View {
        switch state {
        case .clean, .customized:
            IridiumStatusPill(title: state.displayName, systemImage: "checkmark.circle.fill", tone: .green)
        case .rebuilding:
            IridiumStatusPill(title: state.displayName, systemImage: "arrow.clockwise.circle.fill", tone: .orange)
        case .verificationFailed:
            IridiumStatusPill(title: state.displayName, systemImage: "xmark.octagon.fill", tone: .red)
        }
    }
}

struct GameCompatibilityView: View {
    let game: GameRecord
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let readiness = viewModel.readinessReport(for: game)

        List {
            Section {
                Text(readiness.overallStatus.displayName)
                    .font(.headline).foregroundStyle(color(for: readiness.overallStatus))
                Text(readiness.summary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MenuButton("Run Check Again") { viewModel.verifyGameRegistration(game) }
            }

            Section {
                Text("These checks confirm that required files are present. They do not test gameplay, audio, controls, or cutscenes.")
            }
            Section("Checks") {
                ForEach(readiness.checks) { check in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(check.title)
                            Spacer()
                            status(check.status)
                        }
                        Text(check.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            if !viewModel.usesMadeiraRuntime {
            Section("Legacy Runtime Preset") {
                MenuValue("Preset", value: game.compatibilityProfileName)
                MenuValue("Renderer", value: game.rendererPreset.displayName)
                if let profile = viewModel.compatibilityProfile(for: game) {
                    ForEach(profile.knownIssues, id: \.self) { issue in
                        Label(issue, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Launch Checks")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }

    @ViewBuilder
    private func status(_ value: VerificationGateStatus) -> some View {
        switch value {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize()
        case .warning:
            Label("Warning", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize()
        case .blocked:
            Label("Blocked", systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize()
        }
    }

    private func color(for value: VerificationGateStatus) -> Color {
        switch value {
        case .ready: .green
        case .warning: .orange
        case .blocked: .red
        }
    }
}

struct GameStorageView: View {
    let game: GameRecord
    var usesMadeiraRuntime = false

    var body: some View {
        List {
            Section("Usage") {
                MenuValue(
                    "Game",
                    value: game.installedSizeGB.map {
                        "\($0.formatted(.number.precision(.fractionLength(1)))) GB"
                    } ?? "Unknown"
                )
                if !usesMadeiraRuntime { MenuValue("Environment", value: game.prefixState.displayName) }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("Game Folder") {
                pathRow(game.installPath)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            if usesMadeiraRuntime {
                Section("Saves") {
                    Text("Save locations depend on the game. This screen does not yet report the active runtime's save folder or verify save persistence.")
                }
            } else {
            Section("Save Mapping") {
                pathRow(game.savePathMapping)
                Text("Iridium keeps this mapping separate from environment maintenance so repairs do not intentionally delete the mapped save folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Files & Saves")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }

    private func pathRow(_ path: String) -> some View {
        Text(path.isEmpty ? "Not configured" : path)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(path.isEmpty ? "Not configured" : path.replacingOccurrences(of: "/", with: ", "))
    }
}
