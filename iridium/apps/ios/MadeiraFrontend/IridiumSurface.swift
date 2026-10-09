import SwiftUI

/// Pages share the selected game's artwork. Only the background ignores safe areas.
struct IridiumPageBackdrop: View {
    @ObservedObject private var library = LibraryModel.shared
    @AppStorage("iridium.selectedGame") private var selected = ""
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !opaque, let entry = library.entries.first(where: { $0.id.uuidString == selected }),
                   entry.coverFile != nil || entry.steamID != nil || entry.steamAppID != nil {
                    LibraryArtwork(entry: entry, backdrop: true)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                    Color.black.opacity(0.76)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct IridiumPageSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { IridiumPageBackdrop() }
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.66, green: 0.82, blue: 0.76))
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

extension View {
    func iridiumPageSurface() -> some View { modifier(IridiumPageSurface()) }
    func iridiumRowSurface() -> some View { listRowBackground(Color.white.opacity(0.07)) }
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
