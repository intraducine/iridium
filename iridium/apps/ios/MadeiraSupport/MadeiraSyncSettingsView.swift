import SwiftUI

@MainActor struct MadeiraSyncSettingsSection: View {
    @State private var snapshot: MadeiraSyncConfiguration.Snapshot?
    @State private var startup: MadeiraSyncConfiguration.Snapshot?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Section("Sync engine") {
            ForEach(MadeiraSyncEngine.allCases, id: \.self) { engine in
                MenuButton { select(engine) } label: {
                    HStack {
                        Text(engine.title)
                        Spacer()
                        if snapshot?.engine == engine { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .accessibilityValue(snapshot?.engine == engine ? "Selected" : "")
                .disabled(snapshot == nil || saving)
            }
            if saving { ProgressView("Saving sync setting…") }
            if let error { Text(error).foregroundStyle(.orange) }
            if snapshot?.hasUnknownValue == true {
                Text("An unrecognized saved sync value was kept. Selecting a mode replaces that value.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Fastsync is the default. Madsync is an alternative for games with synchronization problems. Wine standard sync uses the server for synchronization. Compatibility varies by game.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("This is the saved selection. Close Iridium from the app switcher and reopen it after changing modes. Sessions that run prerequisite installers can use Wine standard sync.")
                .font(.footnote).foregroundStyle(.secondary)
            if let snapshot, let startup, snapshot.requiresRestart(from: startup) {
                Label("Restart Iridium to use the saved mode", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
        }
        .listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2))
        .listRowSeparator(.hidden)
        .task {
            if case let .success(value) = await MadeiraSyncSession.startup.value { startup = value }
            apply(await MadeiraSyncSession.read())
        }
    }

    private func select(_ engine: MadeiraSyncEngine) {
        guard let work = MadeiraSyncSession.save(engine) else { return }
        saving = true
        Task {
            apply(await work.value)
            saving = false
        }
    }

    private func apply(_ result: MadeiraSyncConfiguration.ReadResult) {
        switch result {
        case let .success(value): snapshot = value; error = nil
        case let .failure(failure): snapshot = nil; error = failure.localizedDescription
        }
    }
}
