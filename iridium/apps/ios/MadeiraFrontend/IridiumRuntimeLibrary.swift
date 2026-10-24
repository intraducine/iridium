// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

/// Iridium's unified model preserves each platform's owned record and storage.
/// Console records never invent Windows paths or migrate existing game files.
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

/// The owned Windows adapter retains the established launch/JIT/Steam lifecycle.
/// Driver state comes from its shared service, without a competing ready flag.
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
        guard TouchControlsModel.shared.iridiumSettingsContext == nil else { throw IridiumRuntimeError.busy }
        guard !IridiumConsoleSession.shared.isActive, !IridiumConsoleSession.shared.dolphinMaintenance else { throw IridiumRuntimeError.busy }
        guard IridiumConsoleSession.shared.phase != .restartRequired else { throw IridiumRuntimeError.restartRequired }
        guard let game = LibraryModel.shared.entries.first(where: { $0.id == gameID }) else { throw IridiumRuntimeError.invalidGame }
        start(game) // Madeira may enable JIT and continue asynchronously.
    }
    func pause() throws { throw IridiumRuntimeError.unsupportedOperation }
    func resume() throws { throw IridiumRuntimeError.unsupportedOperation }
    func stop() { LibraryModel.shared.requestQuit() }
}

@MainActor struct IridiumConsoleDriver: IridiumRuntimeDriver {
    let descriptor: IridiumRuntimeDescriptor
    init(game: IridiumConsoleGame) throws {
        descriptor = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)
    }
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
        let runtime = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)
        guard runtime.id == descriptor.id else { throw IridiumRuntimeError.unavailable }
        IridiumConsoleSession.shared.start(game, store: library.store)
    }
    func pause() throws { IridiumConsoleSession.shared.pause() }
    func resume() throws { IridiumConsoleSession.shared.resume() }
    func stop() { IridiumConsoleSession.shared.stop() }
}

final class IridiumConsoleLibrary: ObservableObject, @unchecked Sendable {
    static let shared = IridiumConsoleLibrary()
    static var supportsPSP: Bool {
        IridiumRuntimeRegistry.compatible(with: .psp).contains { $0.id == "ppsspp" }
    }
    static var importExtensions: [String] {
        var seen = Set<String>()
        return IridiumConsoleSystem.all.flatMap(\.extensions).filter { seen.insert($0).inserted }
    }
    static var importContentTypes: [UTType] {
        importExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }
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

    func importROM(_ url: URL, preferredPlatform: IridiumPlatform? = nil, selectedFiles: [URL] = [],
                   failed: ((String) -> Void)? = nil, imported: @escaping (IridiumConsoleGame) -> Void = { _ in }) {
        guard !working else { return }
        guard Self.importExtensions.contains(url.pathExtension.lowercased()) else {
            let message = IridiumRuntimeError.invalidGame.localizedDescription
            if let failed { failed(message) } else { error = message }
            return
        }
        working = true
        let inputs = selectedFiles.isEmpty ? [url] : selectedFiles
        let scopes = inputs.filter { $0.startAccessingSecurityScopedResource() }
        queue.async {
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                // Coordinate Files/iCloud provider reads; do not keep an
                // external security-scoped path as the game's persistent ID.
                let game = try IridiumFilesAccess.readGame(url, selectedFiles: inputs) { source, selected in
                    try self.store.importROM(source, into: self.store.load(), preferredPlatform: preferredPlatform, selectedFiles: selected)
                }
                let games = try self.store.load()
                DispatchQueue.main.async { self.games = games; self.working = false; imported(game) }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    if let failed { failed(error.localizedDescription) } else { self.error = error.localizedDescription }
                }
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
    var featured = false
    var forceCrop = false
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            IridiumArtworkImage(image: image,
                position: backdrop ? artwork.appearance(game.id).backgroundY : artwork.appearance(game.id).coverY,
                fit: !backdrop && !forceCrop && IridiumArtworkImagePolicy.fitsCover(featured: featured, windows: game.windows != nil,
                    width: Double(image?.size.width ?? 0), height: Double(image?.size.height ?? 0)))
            if image == nil {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller").font(.largeTitle)
                    Text(artwork.title(game)).font(.headline).lineLimit(1).truncationMode(.tail)
                    Text(game.platform.title).font(.caption).foregroundStyle(.secondary)
                }.padding().foregroundStyle(.white)
            }
        }.accessibilityHidden(true)
            .task(id: artwork.key(game) + String(backdrop)) {
                let value = await artwork.image(for: game, backdrop: backdrop)
                if !Task.isCancelled { image = value }
            }
    }
}

struct IridiumConsoleOptions: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = IridiumConsoleLibrary.shared
    let game: IridiumConsoleGame
    var play: ((IridiumConsoleGame) -> Void)? = nil
    var embedded = false
    @State private var removing = false
    @State private var editingArtwork = false
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @AppStorage("iridium.favoriteGames") private var favorites = ""
    private var isFavorite: Bool { favorites.split(separator: ",").contains(Substring(game.id.uuidString)) }
    private var currentGame: IridiumConsoleGame { library.games.first { $0.id == game.id } ?? game }
    private var compatibleRuntimes: [IridiumRuntimeDescriptor] {
        IridiumRuntimeRegistry.compatible(with: currentGame.platform)
    }
    private var resolvedRuntime: IridiumRuntimeDescriptor? {
        try? IridiumRuntimeRegistry.resolve(platform: currentGame.platform, preferred: currentGame.runtimeID)
    }
    private var runtimeDescription: String {
        guard let runtime = resolvedRuntime else { return "This game’s emulator is unavailable." }
        switch runtime.id {
        case "dolphin": return "Dolphin requires the shared JIT system. Each launch checks that JIT works before the game starts."
        case "azahar": return "3DS requires the shared JIT system. Each launch checks that JIT works before the game starts."
        case "play": return "Fully close and reopen Iridium after finishing a PlayStation 2 game."
        default: return ""
        }
    }
    private var saveDescription: String {
        "Use the game's Save command before closing. Removing a game from the library keeps its files and saves."
    }
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
    private var content: some View {
            Form {
                Group {

                Section {
                    IridiumGameOptionsHeader(game: IridiumGame(console: currentGame))
                    if let play {
                        Button("Play", systemImage: "play.fill") { dismiss(); play(currentGame) }
                            .disabled(library.working || resolvedRuntime == nil)
                    }
                }
                Section("Runtime") {
                    LabeledContent("Platform", value: game.platform.title)
                    if compatibleRuntimes.isEmpty {
                        LabeledContent("Runtime", value: "Unavailable")
                    } else if compatibleRuntimes.count == 1 {
                        let runtime = compatibleRuntimes[0]
                        if resolvedRuntime == nil {
                            Button("Use \(runtime.name)") {
                                var changed = currentGame; changed.runtimeID = runtime.id; library.update(changed)
                            }.disabled(library.working || IridiumConsoleSession.shared.isActive)
                        } else { LabeledContent("Emulator", value: runtime.name) }
                    } else {
                        Picker("Preferred runtime", selection: Binding(get: {
                            currentGame.runtimeID
                        }, set: { value in var changed = currentGame; changed.runtimeID = value; library.update(changed) })) {
                            ForEach(compatibleRuntimes) { runtime in
                                Text(runtime.name).tag(runtime.id)
                            }
                        }.disabled(library.working)
                    }
                    if !runtimeDescription.isEmpty { Text(runtimeDescription).font(.footnote).foregroundStyle(.secondary) }
                    if game.platform == .psp {
                        Toggle("Faster CPU (JIT)", isOn: Binding(get: { currentGame.pspJITEnabled }, set: { value in
                            var changed = currentGame; changed.pspJIT = value; library.update(changed)
                        }))
                        .disabled(library.working || IridiumConsoleSession.shared.isActive)
                        .accessibilityIdentifier("psp-use-jit")
                        Text("Off by default. If JIT is unavailable, this game uses the interpreter.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if game.runtimeID == "dolphin" { IridiumDolphinGameOptions(game: currentGame) }
                Section("Controls") {
                    IridiumGameControlsButton(target: .init(platform: game.platform, title: artwork.title(IridiumGame(console: currentGame)), gameID: game.id))
                }
                Section {
                    Button("Rename & Artwork", systemImage: "photo") { editingArtwork = true }
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: isFavorite ? "heart.fill" : "heart") {
                        var ids = Set(favorites.split(separator: ",").map(String.init))
                        if !ids.insert(game.id.uuidString).inserted { ids.remove(game.id.uuidString) }
                        favorites = ids.sorted().joined(separator: ",")
                    }
                    Button("Remove from Library", role: .destructive) { removing = true }
                } footer: { Text(saveDescription) }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Game Options")
                .sheet(isPresented: $editingArtwork) { IridiumArtworkEditor(game: IridiumGame(console: currentGame)) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Remove this library entry? Its files and saves will stay on this device.", isPresented: $removing) {
                    Button("Remove Entry", role: .destructive) { library.remove(game); dismiss() }
                }
    }
}
