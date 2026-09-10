import SwiftUI
import Combine
import IridiumCore

@main struct PreviewApp: App {
    var body: some Scene { WindowGroup { PreviewLibrary() } }
}
struct PreviewLibrary: View {
    @StateObject var artwork = (ProcessInfo.processInfo.arguments.contains("--concept-preview") ? LibraryArtwork(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ConceptPortraitArtwork"), testCredential: "") : LibraryArtwork.shared)
    @StateObject var controller = LibraryController()
    private let inputTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    @State var selected: UUID?
    @State var search = ""
    @State var favorites = false
    @State var edit: GameRecord?
    @State var settings = false
    @State var message = false
    let games: [GameRecord] = (ProcessInfo.processInfo.arguments.contains("--concept-preview") ? ["Hollow Knight", "A Short Hike", "The Elder Scrolls V: Skyrim Special Edition", "Celeste", "Stardew Valley", "Hades", "Portal 2"] : ["Unreleased Project", "Mountain Walk", "A Very Long Custom Game Title For Layout Testing"]).enumerated().map { index, title in
        GameRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!, title: title, source: .manualImport, installPath: "/preview", savePathMapping: "/preview/saves", compatibilityProfileName: "", inputProfileName: "", touchOverlayName: "", controllerPresetName: "", keyboardMouseEnabled: true, prefixState: .clean, deviceTier: .tier1, rendererPreset: .dxvkBalanced, launchProfile: .init(executablePath: title + ".exe", arguments: [], prefixID: UUID(), rendererPreset: .dxvkBalanced, deviceTier: .tier1, titleFlags: []), summary: "")
    }
    var body: some View {
        ControllerMenuHost(nativeNavigation: true) { library.environmentObject(controller) }.ignoresSafeArea()
    }
    private var library: some View {
        NavigationStack {
            LibraryShelf(games: games, artwork: artwork, controller: controller, play: { _ in message = true }, disabled: { _ in false }, launchTitle: { _ in "Play" }, details: { edit = $0 }, search: $search, favorites: $favorites, selectedID: $selected, importGame: { message = true }, settings: { settings = true })
                .toolbar(.hidden, for: .navigationBar)
                .onReceive(inputTimer) { _ in if !message { controller.poll() } }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--concept-preview") else { return }
                    if ProcessInfo.processInfo.arguments.contains("--last-game") { selected = games.last?.id }
                    if ProcessInfo.processInfo.arguments.contains("--appearance") { edit = games.first }
                    if ProcessInfo.processInfo.arguments.contains("--artwork-settings") { settings = true }
                    for game in games where artwork.appearance(game.id).cover == nil || artwork.appearance(game.id).portraitSourceVersion != 2 {
                        do {
                            let matches = try await artwork.search(game.title)
                            if let match = matches.first(where: { LibraryArtwork.normalized($0.name) == LibraryArtwork.normalized(game.title) }) { try await artwork.apply(match, to: game.id) }
                        } catch { artwork.error = error.localizedDescription }
                    }
                }
                .toolbar { Button("Artwork Settings", systemImage: "photo") { settings = true } }
                .sheet(item: $edit) { LibraryAppearanceEditor(game: $0, artwork: artwork) }
                .sheet(isPresented: $settings) { ArtworkConnectionView(artwork: artwork) }
                .alert("Launch action received", isPresented: $message) { Button("OK") {} }
        }.preferredColorScheme(.dark)
    }
}
