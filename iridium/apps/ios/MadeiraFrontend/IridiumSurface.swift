import SwiftUI

/// Pages share the selected game's artwork. Only the background ignores safe areas.
struct IridiumPageBackdrop: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @AppStorage("iridium.selectedGame") private var selected = ""
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !opaque {
                    IridiumLibraryBackdrop(game: selectedGame)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                    Color.black.opacity(0.76)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
    private var selectedGame: IridiumGame? {
        if let entry = library.entries.first(where: { $0.id.uuidString == selected }) { return IridiumGame(windows: entry) }
        if let entry = consoles.games.first(where: { $0.id.uuidString == selected }) { return IridiumGame(console: entry) }
        return nil
    }

}

enum IridiumTheme {
    static let accent = Color(red: 0.66, green: 0.82, blue: 0.76)
}

struct IridiumSettingsRowSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        content.listRowBackground(opaque ? Color(uiColor: .secondarySystemGroupedBackground) : Color.white.opacity(0.07))
    }
}

struct IridiumPageSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { IridiumPageBackdrop() }
            .preferredColorScheme(.dark)
            .tint(IridiumTheme.accent)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct IridiumGlassSurface: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if opaque { content.background(Color(uiColor: .secondarySystemBackground), in: shape) }
        else if #available(iOS 26, *) { content.glassEffect(.regular, in: shape) }
        else { content.background(.regularMaterial, in: shape) }
    }
}

/// Floating actions share native materials; content surfaces and system pickers keep their own styles.
struct IridiumFloatingActionStyle: ViewModifier {
    var enabled = true
    var primary = false
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            Group {
                if #available(iOS 26, *), !opaque {
                    if primary { content.buttonStyle(.glass).foregroundStyle(.white).fontWeight(.bold) }
                    else { content.buttonStyle(.glass) }
                } else {
                    if primary { content.buttonStyle(.borderedProminent).foregroundStyle(.black).fontWeight(.bold) }
                    else { content.buttonStyle(.bordered) }
                }
            }.buttonBorderShape(.capsule)
        } else { content }
    }
}

extension View {
    func iridiumPageSurface() -> some View { modifier(IridiumPageSurface()) }
    func iridiumRowSurface() -> some View { modifier(IridiumSettingsRowSurface()) }
}

struct IridiumFavoriteButton: View {
    let entry: LibraryEntry
    @AppStorage("iridium.favoriteGames") private var ids = ""
    private var favorite: Bool { ids.split(separator: ",").contains(Substring(entry.id.uuidString)) }
    static func toggle(_ entry: LibraryEntry) {
        let defaults = UserDefaults.standard
        var values = Set((defaults.string(forKey: "iridium.favoriteGames") ?? "").split(separator: ",").map(String.init))
        if !values.insert(entry.id.uuidString).inserted { values.remove(entry.id.uuidString) }
        defaults.set(values.sorted().joined(separator: ","), forKey: "iridium.favoriteGames")
    }
    var body: some View {
        Button { Self.toggle(entry) } label: {
            Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.fill" : "heart")
        }
    }
}

struct IridiumGameOptionsHeader: View {
    let game: IridiumGame
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    var body: some View {
        HStack(spacing: 16) {
            IridiumGameArtwork(game: game).frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(artwork.title(game)).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(game.platform.title).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4).accessibilityIdentifier("gameOptionsHeader")
    }
}
