// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// System grouping reuses the library's real per-game options and stored identities.
struct IridiumSystemGameSettings: View {
    let platform: IridiumPlatform
    var focus: String?
    @ObservedObject private var library = IridiumConsoleLibrary.shared
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    private var games: [IridiumConsoleGame] { Self.games(for: platform) }
    static func games(for platform: IridiumPlatform) -> [IridiumConsoleGame] {
        IridiumConsoleLibrary.shared.games.filter {
            $0.platform == platform || (platform == .gameBoy && $0.platform == .gameBoyColor)
        }
    }
    static func routes(for platform: IridiumPlatform) -> [String] { games(for: platform).map { "console:" + $0.id.uuidString } }
    static func game(for route: String) -> IridiumConsoleGame? {
        guard route.hasPrefix("console:"), let id = UUID(uuidString: String(route.dropFirst(8))) else { return nil }
        return IridiumConsoleLibrary.shared.games.first { $0.id == id }
    }
    var body: some View {
        Section {
            if games.isEmpty { Text("Add a game through Files in the library.").foregroundStyle(.secondary) }
            ForEach(games) { game in
                let route = "console:" + game.id.uuidString
                NavigationLink(value: route) { Text(artwork.title(IridiumGame(console: game))).lineLimit(1).truncationMode(.tail) }
                    .id(route).listRowBackground(focus == route ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
            }
        } header: { Text("Games") } footer: {
            Text(platform == .psp ? "Graphics, CPU status and save states are in each running game’s menu. Touch layouts are saved per game." :
                "Game Boy and Game Boy Color use SameBoy. Touch layouts are saved per game; shared feedback is in Controls.")
        }
    }
}
