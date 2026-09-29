import IridiumCore
import IridiumRuntime
import SwiftUI

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

                    Text("Rebuild recreates the Windows environment and keeps imported game and mapped save folders. Custom environment settings may be lost.")
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
                Text("Checks cover the files and settings needed to launch. Game compatibility requires a play test.")
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
    @ObservedObject var viewModel: AppViewModel
    var usesMadeiraRuntime = false
    @State private var confirmDelete = false
    @State private var deleteError: String?

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

            if canDeleteImportedFiles {
                Section {
                    MenuButton("Delete Imported Game Files", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deletes this folder and removes the game from the library. Separate Windows profile saves remain.")
                }
            }

            if usesMadeiraRuntime {
                Section("Saves") {
                    Text("Save locations vary by game. Check the game’s documentation for its save location before backing up files.")
                }
            } else {
            Section("Save Mapping") {
                pathRow(game.savePathMapping)
                Text("This folder is kept when you repair or rebuild the Windows environment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Files & Saves")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .confirmationDialog("Delete imported game files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Game Files", role: .destructive) {
                Task {
                    do { try await viewModel.deleteImportedGameFiles(game) }
                    catch { deleteError = error.localizedDescription }
                }
            }
            Button("Keep Files", role: .cancel) {}
        } message: {
            Text("This deletes the game folder, including files saved inside it. Separate Windows profile saves remain. The action cannot be undone.")
        }
        .alert("Could Not Delete Game Files", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private var canDeleteImportedFiles: Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let root = documents.appendingPathComponent("Games", isDirectory: true).standardizedFileURL
        let folder = URL(fileURLWithPath: game.installPath).standardizedFileURL
        return folder.deletingLastPathComponent() == root && FileManager.default.fileExists(atPath: folder.path)
    }

    private func pathRow(_ path: String) -> some View {
        Text(path.isEmpty ? "Not configured" : path)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(path.isEmpty ? "Not configured" : path.replacingOccurrences(of: "/", with: ", "))
    }
}
