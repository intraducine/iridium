import SwiftUI

struct IridiumLibraryImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var games: [IridiumLibraryImport.Game] = []
    @State private var busy = false
    @State private var error: String?
    @State private var selected = 0
    @State private var guided = false
    @FocusState private var keyboardFocus: Bool
    var added: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Text("Import an existing game and its saves. Original folders stay in place. Different saves with the same name need your choice before import.")
                        .foregroundStyle(.secondary)
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        Button(game.title) { transfer(game) }.disabled(busy).id(index)
                            .foregroundStyle(.primary)
                            .listRowBackground(guided && selected == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                    }
                    if games.isEmpty && error == nil { Text("No games found to import.").foregroundStyle(.secondary) }
                    if busy { ProgressView("Importing game files") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.iridiumRowSurface()
            }.iridiumPageSurface().navigationTitle("Import Existing Games").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
                .task {
                    do {
                        games = try await Task.detached(priority: .utility) {
                            try IridiumLibraryImport.games(applicationSupport: .applicationSupportDirectory)
                        }.value
                    } catch { self.error = error.localizedDescription }
                }
                .focusable().focusEffectDisabled().focused($keyboardFocus)
                .onAppear { keyboardFocus = true }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.return) { select(); return .handled }
                .onKeyPress(.escape) { if !busy { dismiss() }; return .handled }
                .onReceive(LibraryController.shared.commands) { value in
                    guard !busy else { return }
                    if value == "up" || value == "left" { move(-1) }
                    else if value == "down" || value == "right" { move(1) }
                    else if value == "accept" { select() }
                    else if value == "back" { dismiss() }
                }
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }
        .interactiveDismissDisabled(busy)
    }
    private func move(_ step: Int) {
        guard !busy else { return }
        guided = true; selected = min(max(selected + step, 0), max(0, games.count - 1))
    }
    private func select() {
        guard !busy, games.indices.contains(selected) else { return }
        transfer(games[selected])
    }
    private func transfer(_ game: IridiumLibraryImport.Game) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let imported = try await Task.detached(priority: .utility) {
                    try IridiumLibraryImport.transfer(game, documents: LibraryModel.documents)
                }.value
                var entry = try LibraryModel.inspect(LibraryModel.drive.appendingPathComponent(imported.executable))
                entry.id = game.id; entry.title = game.title
                entry.arguments = IridiumLibraryImport.commandLine(game.launchProfile.arguments)
                let (appearance, cover) = try await Task.detached(priority: .utility) {
                    try IridiumImportPreferences.cover(for: game.id)
                }.value
                entry.title = appearance?.title ?? game.title
                entry.steamID = appearance?.matchID
                entry.coverFile = cover
                try IridiumImportPreferences.controls(for: game.id, entry: &entry)
                LibraryModel.shared.save(entry)
                guard LibraryModel.shared.entries.contains(where: { $0.id == game.id }), LibraryModel.shared.error == nil else {
                    error = LibraryModel.shared.error ?? "The library could not be saved. The original files were kept."
                    return
                }
                if appearance?.favorite == true {
                    let key = "iridium.favoriteGames"
                    var ids = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
                    ids.insert(game.id.uuidString)
                    UserDefaults.standard.set(ids.sorted().joined(separator: ","), forKey: key)
                }
                added(game.id); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
