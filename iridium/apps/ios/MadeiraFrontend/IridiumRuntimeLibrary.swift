// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Iridium's frontend model contains either backend's record without moving
/// Windows games, rewriting Madeira models, or inventing Windows paths for ROMs.
struct IridiumGame: Identifiable {
    let windows: LibraryEntry?
    let console: IridiumConsoleGame?
    init(windows: LibraryEntry) { self.windows = windows; console = nil }
    init(console: IridiumConsoleGame) { self.console = console; windows = nil }
    var id: UUID { windows?.id ?? console!.id }
    var title: String { windows?.title ?? console!.title }
    var platform: IridiumPlatform { console?.platform ?? .windows }
    var coverFile: String? { windows?.coverFile }
    var steamID: Int? { windows?.steamID }
    var steamAppID: Int? { windows?.steamAppID }
}

/// Madeira keeps its existing launch/JIT/Steam/session implementation. Driver
/// state is read from Madeira, not a competing "ready" flag in Iridium's UI.
@MainActor struct IridiumWindowsDriver: IridiumRuntimeDriver {
    let start: (LibraryEntry) -> Void
    var descriptor: IridiumRuntimeDescriptor { IridiumRuntimeRegistry.madeira }
    var state: IridiumRuntimeState {
        let library = LibraryModel.shared
        if library.launching { return .starting }
        if library.current != nil { return .running }
        return LibraryModel.sessionsThisRun > 0 ? .restartRequired : .idle
    }
    func launch(gameID: UUID) throws {
        guard !IridiumConsoleSession.shared.isActive else { throw IridiumRuntimeError.busy }
        guard let game = LibraryModel.shared.entries.first(where: { $0.id == gameID }) else { throw IridiumRuntimeError.invalidGame }
        start(game) // Madeira may enable JIT and continue asynchronously.
    }
    func pause() throws { throw IridiumRuntimeError.unsupportedOperation }
    func resume() throws { throw IridiumRuntimeError.unsupportedOperation }
    func stop() { LibraryModel.shared.requestQuit() }
}

@MainActor struct IridiumSameBoyDriver: IridiumRuntimeDriver {
    var descriptor: IridiumRuntimeDescriptor { IridiumRuntimeRegistry.sameBoy }
    var state: IridiumRuntimeState {
        switch IridiumConsoleSession.shared.phase {
        case .idle: return .idle
        case .starting: return .starting
        case .running: return .running
        case .paused: return .paused
        case .stopping: return .stopping
        case .restartRequired: return .restartRequired
        }
    }
    func launch(gameID: UUID) throws {
        let library = IridiumConsoleLibrary.shared
        guard let game = library.games.first(where: { $0.id == gameID }) else { throw IridiumRuntimeError.invalidGame }
        IridiumConsoleSession.shared.start(game, store: library.store)
    }
    func pause() throws { IridiumConsoleSession.shared.pause() }
    func resume() throws { IridiumConsoleSession.shared.resume() }
    func stop() { IridiumConsoleSession.shared.stop() }
}

final class IridiumConsoleLibrary: ObservableObject, @unchecked Sendable {
    static let shared = IridiumConsoleLibrary()
    @Published private(set) var games: [IridiumConsoleGame] = []
    @Published private(set) var working = false
    @Published var error: String?
    let store = IridiumConsoleStore(root: LibraryModel.documents.resolvingSymlinksInPath()
        .appendingPathComponent("IridiumRuntimes", isDirectory: true))
    private let queue = DispatchQueue(label: "software.iridium.runtime-library", qos: .userInitiated)

    private init() { reload() }
    func reload() {
        queue.async {
            do {
                let games = try self.store.load()
                DispatchQueue.main.async { self.games = games }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }

    func importROM(_ url: URL) {
        guard !working else { return }
        working = true
        let scoped = url.startAccessingSecurityScopedResource()
        queue.async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Coordinate Files/iCloud provider reads; do not keep an
                // external security-scoped path as the game's persistent ID.
                var coordinatorError: NSError?
                var result: Result<IridiumConsoleGame, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { source in
                    result = Result { try self.store.importROM(source, into: self.store.load()) }
                }
                if let coordinatorError { throw coordinatorError }
                guard let result else { throw IridiumRuntimeError.invalidGame }
                _ = try result.get()
                let games = try self.store.load()
                DispatchQueue.main.async { self.games = games; self.working = false }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.working = false }
            }
        }
    }

    func update(_ game: IridiumConsoleGame) {
        mutate { values in
            guard let index = values.firstIndex(where: { $0.id == game.id }) else { return }
            values[index] = game
        }
    }
    func remove(_ game: IridiumConsoleGame) {
        mutate { $0.removeAll { $0.id == game.id } }
    }
    private func mutate(_ edit: @escaping @Sendable (inout [IridiumConsoleGame]) -> Void) {
        guard !working, !IridiumConsoleSession.shared.isActive else { return }
        working = true
        queue.async {
            do {
                var games = try self.store.load(); edit(&games); try self.store.save(games)
                DispatchQueue.main.async { self.games = games; self.working = false }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.working = false }
            }
        }
    }
}

struct IridiumGameArtwork: View {
    let game: IridiumGame
    var backdrop = false
    var body: some View {
        if let windows = game.windows {
            LibraryArtwork(entry: windows, backdrop: backdrop)
        } else {
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.7), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller.fill").font(.largeTitle)
                    Text(game.platform.title).font(.headline)
                    Text(game.title).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                }.padding().foregroundStyle(.white)
            }.accessibilityHidden(true)
        }
    }
}

struct IridiumConsoleOptions: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = IridiumConsoleLibrary.shared
    let game: IridiumConsoleGame
    var play: () -> Void
    @State private var removing = false
    @AppStorage("iridium.favoriteGames") private var favorites = ""
    private var isFavorite: Bool { favorites.split(separator: ",").contains(Substring(game.id.uuidString)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Runtime") {
                    LabeledContent("Platform", value: game.platform.title)
                    Picker("Preferred runtime", selection: Binding(get: {
                        library.games.first(where: { $0.id == game.id })?.runtimeID ?? game.runtimeID
                    }, set: { value in var changed = game; changed.runtimeID = value; library.update(changed) })) {
                        ForEach(IridiumRuntimeRegistry.compatible(with: game.platform)) { runtime in
                            Text(runtime.name).tag(runtime.id)
                        }
                    }.disabled(library.working)
                    Text("SameBoy uses an interpreter. JIT is not required.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Play", systemImage: "play.fill") { dismiss(); play() }
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: isFavorite ? "heart.fill" : "heart") {
                        var ids = Set(favorites.split(separator: ",").map(String.init))
                        if !ids.insert(game.id.uuidString).inserted { ids.remove(game.id.uuidString) }
                        favorites = ids.sorted().joined(separator: ",")
                    }
                    Button("Remove from Library", role: .destructive) { removing = true }
                } footer: { Text("Battery saves are stored separately for each game. Removing this entry keeps the ROM and saves in Files → Iridium → IridiumRuntimes.") }
            }.iridiumPageSurface().navigationTitle(game.title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Remove this library entry? Its files and saves will stay on this device.", isPresented: $removing) {
                    Button("Remove Entry", role: .destructive) { library.remove(game); dismiss() }
                }
        }
    }
}
