import IridiumCore
import SwiftUI

struct SteamCloudView: View {
    let target: SteamCloudTarget
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var steam = SteamLibraryModel.shared
    @ObservedObject private var cloud = SteamCloudCoordinator.shared
    @State private var consent = false
    @State private var choice: SteamCloudChoice?
    @State private var restoreID: String?
    @Environment(\.menuController) private var controller

    private var game: GameRecord? { viewModel.games.first(where: { $0.id == target.gameID }) }
    private var status: SteamCloudStatus? { steam.cloudByGame[target.gameID] }
    private var idle: Bool {
        cloud.runtimeIdle(viewModel) && !cloud.busy
    }
    private var available: Bool { idle && !steam.busy && steam.state.signedIn && viewModel.usesMadeiraRuntime }

    var body: some View {
        List {
            summarySection
            mappedSavesSection
            backupsSection
        }
        .iridiumListChrome().navigationTitle("Steam Cloud")
        .task { if available { run("check") } }
        .confirmationDialog("Enable Steam Cloud for this game?", isPresented: $consent, titleVisibility: .visible) {
            Button("Enable for This Game and Account") { run("enable") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Iridium to download and upload saves for this game with \(steam.state.accountName ?? "the signed-in Steam account"). Before Play, Iridium can download one-sided changes. Uploads run after a normal confirmed game exit or when you choose Sync Changes. Closed or cancelled sessions need a manual sync. First saves and conflicts need your choice. Backups are kept on this device. Enabling compares saves; it does not transfer them yet.")
        }
        .confirmationDialog("Use the selected save copy?", isPresented: Binding(
            get: { choice != nil }, set: { if !$0 { choice = nil } }
        ), titleVisibility: .visible) {
            Button("Use This Copy and Keep Backup") {
                guard let selected = choice else { return }
                choice = nil
                run("resolve", choice: selected)
            }
            Button("Cancel", role: .cancel) { choice = nil }
        } message: {
            Text("The other existing copy will be backed up before replacement. Keeping a missing device save leaves the Cloud copy intact. If either save changed since comparison, Iridium will require a new choice.")
        }
        .confirmationDialog("Restore this device backup?", isPresented: Binding(
            get: { restoreID != nil }, set: { if !$0 { restoreID = nil } }
        ), titleVisibility: .visible) {
            Button("Restore and Keep Current Save") {
                guard let id = restoreID else { return }
                restoreID = nil
                run("restore", backupID: id)
            }
            Button("Cancel", role: .cancel) { restoreID = nil }
        } message: {
            Text("Restores the previous device save and keeps the current one as an undo backup. The restored save will require a new choice before it can replace Cloud. Cloud saves stay unchanged.")
        }
        .onChange(of: consent || choice != nil || restoreID != nil) { _, presented in
            controller?.nativeMenuActive = presented
        }
    }

    private var summarySection: some View {
        Section {
            summaryContent
            operationButtons
        } header: {
            Text("Steam Cloud")
        } footer: {
            Text("Only verified Windows Auto-Cloud save paths are supported. Iridium preserves backups before replacements and never deletes Cloud saves. Backups use extra device storage.")
        }
    }

    @ViewBuilder private var summaryContent: some View {
        if let game { Text(game.title).font(.headline) }
        LabeledContent("Steam Account", value: steam.state.accountName ?? "Signed out")
        Text(status?.message ?? "Compare verified save folders for this game and the signed-in Steam account.")
        if let problem = steam.cloudProblems[target.gameID] { Text(problem).foregroundStyle(.orange) }
        if !steam.state.signedIn { Text("Sign in from Downloads to check this account's saves.") }
        if !viewModel.usesMadeiraRuntime { Text("Cloud save mapping is currently available for the Madeira runtime's isolated game prefixes.") }
        if !idle { Text("Save transfers wait until the game has stopped and runtime shutdown is confirmed.") }
    }

    @ViewBuilder private var operationButtons: some View {
        if steam.cloudOperation == target.gameID {
            ProgressView("Comparing or transferring saves…")
            MenuButton("Cancel Sync") { steam.perform(["action": "cancel"]) }
        } else {
            MenuButton("Compare Saves") { run("check") }.disabled(!available)
            if status?.enabled == true {
                MenuButton("Sync Changes") { run("sync") }.disabled(!available || status?.phase == "interrupted")
                MenuButton("Turn Off for This Game") { run("disable") }.disabled(!available)
            } else {
                MenuButton("Enable for This Game…") { consent = true }.disabled(!available)
            }
            if status?.phase == "interrupted" {
                MenuButton("Recheck Interrupted Sync") { run("recover") }.disabled(!available)
            }
        }
    }

    @ViewBuilder private var mappedSavesSection: some View {
        if let status {
            Section("Mapped Saves") {
                if status.entries.isEmpty { Text("No mapped saves found in the Cloud or this game's prepared prefix.") }
                ForEach(status.entries) { entry in saveRow(entry, status: status) }
            }
        }
    }

    private func saveRow(_ entry: SteamCloudEntry, status: SteamCloudStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.name).font(.headline)
            Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Device: \(description(entry.local))")
            Text("Cloud: \(description(entry.remote))")
            if entry.action == "same" { Text("Copies match").foregroundStyle(.secondary) }
            else if entry.action == "keptMissing" { Text("Kept missing on this device; Cloud copy retained").foregroundStyle(.secondary) }
            else { saveChoices(entry, status: status) }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private func saveChoices(_ entry: SteamCloudEntry, status: SteamCloudStatus) -> some View {
        Text(entry.action == "conflict" ? "Choose a save copy" : "Change ready to sync").foregroundStyle(.orange)
        MenuButton(entry.local == nil ? "Keep Missing on Device…" : "Keep Device Save…") {
            choice = SteamCloudChoice(entry, side: "local")
        }.disabled(!available || !status.enabled || status.phase == "interrupted")
        if entry.remote != nil {
            MenuButton("Keep Cloud Save…") { choice = SteamCloudChoice(entry, side: "remote") }
                .disabled(!available || !status.enabled || status.phase == "interrupted")
        }
    }

    @ViewBuilder private var backupsSection: some View {
        if let status, !status.backups.isEmpty {
            Section("Backups") {
                ForEach(status.backups, id: \.self) { id in
                    MenuButton("Restore Device Backup \(id.prefix(8))…") { restoreID = id }
                        .disabled(!available || status.phase == "interrupted")
                }
                Text("Copies are in Files → Iridium → Steam Cloud Backups. Each backup.json records the original mapped path. device.bin is the previous device save; cloud.bin is the previous Cloud save when present. Keep these records with their copies.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ mode: String, choice: SteamCloudChoice? = nil, backupID: String? = nil) {
        guard available else { return }
        guard let game else { return }
        Task { _ = await cloud.synchronize(game, model: viewModel, mode: mode, choice: choice, backupID: backupID) }
    }
    private func description(_ file: SteamCloudFile?) -> String {
        guard let file else { return "Missing" }
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        guard file.time <= UInt64(Int64.max) else { return size }
        return size + ", " + Date(timeIntervalSince1970: TimeInterval(file.time)).formatted(date: .abbreviated, time: .shortened)
    }
}
