import Combine
import IridiumCore
import IridiumRuntime
import SwiftUI

/// Runs the real shelf, presenter, player and file-backed first-frame observer.
/// It never starts Wine/JIT and uses only the preview's generated artwork.
struct LaunchPresentationPreview: View {
    let games: [GameRecord]
    @StateObject private var controller = LibraryController()
    @ObservedObject private var artwork = LibraryArtwork.shared
    @State private var selected: UUID?
    @State private var search = ""
    @State private var favorites = false
    @State private var playerModel: AppViewModel?
    @State private var configuration: RuntimePlayerBridgeConfiguration?
    @State private var isPresenting = false
    @State private var frameTask: Task<Void, Never>?
    @State private var fixtureError: String?

    var body: some View {
        LibraryShelf(games: games, artwork: artwork, controller: controller,
            play: start, disabled: { _ in false }, launchTitle: { _ in "Play" },
            details: { _ in }, search: $search, favorites: $favorites, selectedID: $selected,
            acceptsControllerInput: !isPresenting)
            .environmentObject(controller).environment(\.menuController, controller)
            .background {
                if let playerModel, let configuration {
                    MadeiraPlayerPresentation(viewModel: playerModel, presentationConfiguration: configuration)
                        .frame(width: 0, height: 0)
                        .onReceive(playerModel.$activeRuntimePlayerSession.receive(on: DispatchQueue.main)) {
                            isPresenting = $0 != nil
                        }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(fixtureError ?? (artworkReady ? "Fixture ready" : "Preparing fixture"))
                    .font(.caption2).padding(8)
                    .accessibilityIdentifier(fixtureError != nil ? "launchFixtureError" : (artworkReady ? "launchFixtureReady" : "launchFixturePreparing"))
            }
    }

    private var artworkReady: Bool {
        guard let game = games.first else { return true }
        let appearance = artwork.appearance(game.id)
        return (appearance.background == nil || artwork.displayImage(appearance.background) != nil)
            && (appearance.cover == nil || artwork.displayImage(appearance.cover) != nil)
    }

    private func start(_ game: GameRecord) {
        guard !isPresenting else { return }
        frameTask?.cancel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fixtureError = error.localizedDescription; return }
        var config = InterfacePreviewApp.playerConfiguration
        config.sessionIdentifier = root.lastPathComponent
        config.surfaceIdentifier = root.lastPathComponent
        config.bridgeRootPath = root.path
        config.framebufferPath = root.appendingPathComponent("frame.bgra").path
        config.frameReadyPath = root.appendingPathComponent("ready").path
        config.inputEventsPath = root.appendingPathComponent("input.csv").path
        config.surfaceWidth = 16
        config.surfaceHeight = 16
        var session = InterfacePreviewApp.playerSession(game: game)
        session.sessionIdentifier = config.sessionIdentifier
        session.gameTitle = game.title
        session.state = ProcessInfo.processInfo.arguments.contains("--launch-failed") ? .failed : .running
        session.stateHistory = [session.state]
        let model = AppViewModel.makeForTesting(games: games, activeRuntimePlayerSession: session)
        configuration = config
        playerModel = model
        isPresenting = true
        let immediate = ProcessInfo.processInfo.arguments.contains("--launch-frame-immediate")
        let delayed = ProcessInfo.processInfo.arguments.contains("--launch-frame-delayed")
        guard immediate || delayed else { return }
        let readyConfiguration = config
        frameTask = Task { @MainActor in
            if delayed {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
            guard !Task.isCancelled,
                  model.activeRuntimePlayerSession?.sessionIdentifier == readyConfiguration.sessionIdentifier else { return }
            do {
                let pixels = Data((0..<(16 * 16)).flatMap { _ in [UInt8(70), 130, 210, 255] })
                try pixels.write(to: URL(fileURLWithPath: readyConfiguration.framebufferPath), options: .atomic)
                try Data().write(to: URL(fileURLWithPath: readyConfiguration.frameReadyPath), options: .atomic)
            } catch { fixtureError = error.localizedDescription }
        }
    }
}
