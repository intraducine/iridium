import Foundation

/// Optional live check. Pass a game title; this creates only an isolated temporary artwork store.
@main struct CatalogSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ArtworkError.message("Pass a game title to test.") }
        let query = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-artwork-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryArtwork(root: root, testCredential: "")
        let matches = try await store.search(query)
        guard let match = matches.first(where: { LibraryArtwork.normalized($0.name) == LibraryArtwork.normalized(query) }) else {
            throw ArtworkError.message("No exact game match found.")
        }
        let id = UUID()
        try await store.apply(match, to: id)
        let item = store.appearance(id)
        guard store.image(item.cover) != nil, store.image(item.background) != nil else {
            throw ArtworkError.message("The game did not return both usable artwork images.")
        }
        guard let cover = store.image(item.cover), cover.size.height > cover.size.width,
              item.portraitSourceVersion == 2 else {
            throw ArtworkError.message("The catalog returned no portrait cover for this game.")
        }
        let reopened = LibraryArtwork(root: root, testCredential: "")
        guard reopened.image(reopened.appearance(id).cover) != nil else { throw ArtworkError.message("Cached cover could not be reopened.") }
        print("PASS: portrait cover, catalog match, background, image decode, persistent offline cache")
    }
}
