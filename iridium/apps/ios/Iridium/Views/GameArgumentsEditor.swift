import IridiumCore
import SwiftUI

struct GameArgumentsEditor: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var cloud = SteamCloudCoordinator.shared
    @ObservedObject private var steam = SteamLibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GameArgumentDraft
    @State private var saving = false
    @State private var failure: String?

    init(game: GameRecord, viewModel: AppViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: GameArgumentDraft(game: viewModel.games.first(where: { $0.id == game.id }) ?? game))
    }

    private var current: GameRecord? { viewModel.games.first(where: { $0.id == draft.gameID }) }
    private var editable: Bool {
        !saving && !cloud.busy && !steam.gameFilesBusy && viewModel.canEditGameArguments(draft.gameID)
            && current.map { draft.isCurrent(for: $0) } == true
    }

    var body: some View {
        List {
            Section {
                ForEach($draft.rows) { row in argumentRow(row) }
                MenuButton("Add Argument", systemImage: "plus") { draft.rows.append(.init(value: "")) }
            } header: { Text("Custom Arguments") } footer: {
                Text("Each row is one argument. Spaces, quotes and backslashes are literal. An empty row passes an empty argument; remove the row to omit it.")
            }
            .disabled(!editable)
            Section("Automatic Compatibility Arguments") {
                Text("Iridium may add graphics arguments or use this game's compatibility defaults when custom arguments are empty. These rules still apply at launch.")
                    .font(.footnote)
            }
            if current == nil {
                Section { Text("This game is no longer in the library. Cancel to close the editor.") }
            } else if let current, !draft.isCurrent(for: current) {
                Section { Text("The game's launch settings changed. Cancel and reopen the editor.") }
            } else if !editable && !saving {
                Section { Text("Stop the game and finish pending game operations before saving arguments.") }
            }
            if let failure { Section("Could Not Save") { Text(failure) } }
            Section {
                MenuButton(saving ? "Saving…" : "Save") { save() }.disabled(!editable)
                MenuButton("Cancel", role: .cancel) { dismiss() }.disabled(saving)
            }
        }
        .iridiumListChrome()
        .navigationTitle("Custom Arguments")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
        .interactiveDismissDisabled(saving)
        .controllerMenuScope(onBack: { if !saving { dismiss() } })
    }

    private func argumentRow(_ row: Binding<GameArgumentDraft.Row>) -> some View {
        let id = row.wrappedValue.id
        let index = draft.rows.firstIndex(where: { $0.id == id }) ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Argument \(index + 1)").font(.caption).foregroundStyle(.secondary)
            MenuTextField("Empty argument", text: row.value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Argument \(index + 1)")
            HStack {
                MenuButton("Move Up", systemImage: "arrow.up") { move(id, by: -1) }.disabled(index == 0)
                MenuButton("Move Down", systemImage: "arrow.down") { move(id, by: 1) }.disabled(index + 1 >= draft.rows.count)
                Spacer()
                MenuButton("Remove", role: .destructive) { draft.rows.removeAll { $0.id == id } }
            }.buttonStyle(.borderless)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.rows.firstIndex(where: { $0.id == id }), draft.rows.indices.contains(index + offset) else { return }
        draft.rows.swapAt(index, index + offset)
    }

    private func save() {
        guard editable else { return }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do { try await viewModel.saveGameArguments(draft); dismiss() }
            catch { failure = error.localizedDescription }
        }
    }
}
