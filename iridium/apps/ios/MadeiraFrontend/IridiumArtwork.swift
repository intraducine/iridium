// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import ImageIO

/// One artwork identity and cache for every runtime. Launch records and saves
/// never become catalog records, and catalog failures never block Play.
@MainActor final class IridiumArtworkModel: ObservableObject {
    static let shared = IridiumArtworkModel()
    @Published private(set) var revision = 0
    @Published private(set) var statuses: [UUID: String] = [:]
    @Published private(set) var error: String?
    private let root: URL
    private var store: IridiumArtworkStore?
    private var attempted = Set<UUID>()
    private var lookupRequests: [UUID: IridiumArtworkTicket] = [:]
    private let images = NSCache<NSString, UIImage>()
    private var imageRequests: [URL: Task<UIImage?, Never>] = [:]
    private var legacyBackgrounds: [UUID: String]?
    private var legacyBackgroundRequest: Task<[UUID: String], Never>?

    init(root: URL = LibraryModel.documents.resolvingSymlinksInPath().appendingPathComponent("iridium-artwork")) {
        self.root = root
        do { store = try IridiumArtworkStore(root: root) }
        catch { self.error = "Saved artwork could not be read. Your existing choices have been preserved." }
        images.totalCostLimit = 48 * 1024 * 1024
    }
    func appearance(_ id: UUID) -> IridiumArtworkAppearance {
        if let store { return store.appearance(id) }
        var empty = IridiumArtworkAppearance(); empty.revision = id; return empty
    }
    func title(_ game: IridiumGame) -> String { appearance(game.id).title ?? game.title }
    func key(_ game: IridiumGame) -> String {
        "\(game.id):\(appearance(game.id).revision):\(game.coverFile ?? ""):\(game.steamID ?? game.steamAppID ?? 0)"
    }
    func update(_ id: UUID, _ change: (inout IridiumArtworkAppearance) -> Void) throws {
        guard let store else { throw LibraryError.message(error ?? "Artwork storage is unavailable.") }
        try store.update(id, change); lookupRequests[id] = nil; statuses[id] = nil; revision += 1
    }
    func removeMatch(_ id: UUID) throws {
        guard let store else { throw LibraryError.message(error ?? "Artwork storage is unavailable.") }
        try store.removeMatch(id); lookupRequests[id] = nil; statuses[id] = "Choose a match"; revision += 1
    }
    func search(_ query: String, platform: IridiumPlatform) async throws -> [IridiumArtworkCandidate] {
        try await IridiumArtworkCatalog.search(query, platform: platform)
    }
    func prepare(_ game: IridiumGame, retry: Bool = false) async {
        if retry { attempted.remove(game.id); IridiumArtworkCatalog.retry(platform: game.platform) }
        let legacyBackground = await legacyBackground(for: game.id)
        let item = appearance(game.id)
        guard let store, item.automaticLookup, item.match == nil,
              IridiumArtworkSourcePolicy.needsAutomaticCover(item, legacyCover: game.coverFile) ||
                IridiumArtworkSourcePolicy.needsAutomaticBackground(item, legacyCover: game.coverFile, legacyBackground: legacyBackground),
              !attempted.contains(game.id),
              let ticket = store.begin(game.id) else { return }
        attempted.insert(game.id); lookupRequests[game.id] = ticket; statuses[game.id] = "Finding artwork…"
        defer { if lookupRequests[game.id] == ticket { lookupRequests[game.id] = nil } }
        do {
            let candidate: IridiumArtworkCandidate?
            if let id = game.steamID ?? game.steamAppID, game.platform == .windows {
                candidate = IridiumArtworkCatalog.steam(id: id, title: game.title)
            } else {
                let matches = try await search(game.title, platform: game.platform)
                candidate = IridiumArtworkMatcher.exactMatch(game.title, platform: game.platform, candidates: matches)
            }
            try Task.checkCancellation()
            guard let candidate else {
                store.cancel(ticket)
                if lookupRequests[game.id] == ticket { statuses[game.id] = "Choose artwork" }
                return
            }
            try await apply(candidate, ticket: ticket, game: game)
        } catch is CancellationError {
            store.cancel(ticket)
            if lookupRequests[game.id] == ticket { attempted.remove(game.id); statuses[game.id] = nil }
        } catch {
            store.cancel(ticket)
            if lookupRequests[game.id] == ticket {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    attempted.remove(game.id); statuses[game.id] = nil
                } else { statuses[game.id] = "Artwork unavailable. Retry in Game Options." }
            }
        }
    }
    func select(_ candidate: IridiumArtworkCandidate, for game: IridiumGame) async throws {
        guard let store, let ticket = store.begin(game.id, automatic: false) else {
            throw LibraryError.message(error ?? "Artwork storage is unavailable.")
        }
        lookupRequests[game.id] = ticket
        defer { if lookupRequests[game.id] == ticket { lookupRequests[game.id] = nil } }
        do { try await apply(candidate, ticket: ticket, game: game) }
        catch { store.cancel(ticket); throw error }
    }
    private func apply(_ candidate: IridiumArtworkCandidate, ticket: IridiumArtworkTicket, game: IridiumGame) async throws {
        guard let store else { return }
        let gameID = game.id
        let legacyBackground = await legacyBackground(for: gameID)
        let item = appearance(gameID)
        var cover: String?, background: String?
        if IridiumArtworkSourcePolicy.needsAutomaticCover(item, legacyCover: game.coverFile), let url = candidate.coverURL {
            cover = try await IridiumArtworkFallback.firstAvailable([url] + candidate.coverAlternates) { source in
                let data = try await IridiumArtworkCatalog.data(source, limit: 25 * 1024 * 1024)
                return try await saveImage(data)
            }
        }
        try Task.checkCancellation()
        if IridiumArtworkSourcePolicy.needsAutomaticBackground(item, legacyCover: game.coverFile, legacyBackground: legacyBackground), let url = candidate.backgroundURL {
            // A missing hero must not throw away a valid box cover.
            if let data = try? await IridiumArtworkCatalog.data(url, limit: 25 * 1024 * 1024) {
                background = try? await saveImage(data)
            }
        }
        try Task.checkCancellation()
        if try store.apply(candidate, coverName: cover, backgroundName: background, ticket: ticket) {
            statuses[gameID] = nil; revision += 1
        }
        // Unreferenced downloaded images are harmless recovery data. Never
        // delete an image that a newer manual operation might have retained.
    }
    func setImage(_ data: Data, for id: UUID, background: Bool) async throws {
        try Task.checkCancellation()
        // Invalidate old lookups without committing an image override before
        // decoding succeeds. Failed/cancelled imports retain the prior choice.
        try update(id) { _ in }
        let expected = appearance(id).revision
        let name = try await saveImage(data)
        try Task.checkCancellation()
        guard appearance(id).revision == expected else { return }
        try update(id) {
            if background { $0.background = name; $0.customBackground = true; $0.backgroundY = 0.5 }
            else { $0.cover = name; $0.customCover = true; $0.coverY = 0.5 }
        }
    }
    private func saveImage(_ data: Data) async throws -> String {
        guard data.count <= 25 * 1024 * 1024, let store else { throw LibraryError.message("Choose an image smaller than 25 MB.") }
        let name = UUID().uuidString + ".jpg"
        let target = try store.prepareImageURL(name)
        try await Task.detached(priority: .utility) {
            guard let image = Self.decode(data), let encoded = image.jpegData(compressionQuality: 0.88) else {
                throw LibraryError.message("Choose a supported image smaller than 25 MB.")
            }
            try encoded.write(to: target, options: .atomic)
        }.value
        return name
    }
    nonisolated private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    func image(for game: IridiumGame, backdrop: Bool) async -> UIImage? {
        let legacyBackground = backdrop ? await legacyBackground(for: game.id) : nil
        let sources = IridiumArtworkSourcePolicy.sources(appearance(game.id), legacyCover: game.coverFile,
            legacyBackground: legacyBackground, steamID: game.steamID ?? game.steamAppID, backdrop: backdrop)
        for source in sources {
            guard !Task.isCancelled else { return nil }
            let urls: [URL]
            switch source {
            case .shared(let name): urls = [try? store?.imageURL(name)].compactMap { $0 }
            case .legacyCover(let name):
                let root = LibraryModel.documents.resolvingSymlinksInPath().appendingPathComponent("madeira-art")
                let url = root.appendingPathComponent(name)
                guard name == URL(fileURLWithPath: name).lastPathComponent,
                      url.resolvingSymlinksInPath().deletingLastPathComponent() == root else { continue }
                urls = [url]
            case .legacyBackground(let name): urls = [try? IridiumImportPreferences.image(name)].compactMap { $0 }
            case .steam(let id):
                urls = backdrop ? [SteamCatalog.hero(id)].compactMap { $0 } :
                    SteamGamesRules.artwork(appID: id, owned: { SteamOwnedLibrary.shared.game($0) })
            }
            for url in urls {
                guard !Task.isCancelled else { return nil }
                if let image = await load(url) { return image }
            }
        }
        return nil
    }
    private func legacyBackground(for id: UUID) async -> String? {
        if let legacyBackgrounds { return legacyBackgrounds[id] }
        if let pending = legacyBackgroundRequest { return (await pending.value)[id] }
        let request = Task.detached(priority: .utility) { () -> [UUID: String] in
            let file = URL.applicationSupportDirectory.appendingPathComponent("LibraryArtwork/library.json")
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 4 * 1024 * 1024 else { return [:] }
            // This compatibility read never copies, rewrites, or removes the
            // prior metadata or images. The existing validated path reader is reused.
            return (try? IridiumImportPreferences.appearances().compactMapValues { $0.background }) ?? [:]
        }
        legacyBackgroundRequest = request
        let values = await request.value
        legacyBackgrounds = values; legacyBackgroundRequest = nil
        return values[id]
    }
    private func load(_ url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let image = images.object(forKey: key) { return image }
        if let pending = imageRequests[url] { return await pending.value }
        let request = Task { @MainActor () async -> UIImage? in
            let data: Data?
            if url.isFileURL {
                data = await Task.detached(priority: .utility) {
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 25 * 1024 * 1024 else { return nil as Data? }
                    return try? Data(contentsOf: url)
                }.value
            } else { data = try? await IridiumArtworkCatalog.data(url, limit: 25 * 1024 * 1024) }
            guard let data else { return nil }
            return await Task.detached(priority: .utility) { Self.decode(data) }.value
        }
        imageRequests[url] = request
        let image = await request.value
        imageRequests[url] = nil
        if let image { images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
}

/// Reuse Madeira's public Steam catalog and artwork URL rules. Retro data uses
/// Libretro's documented per-system Named_Boxarts/Named_Snaps repositories via
/// GitHub's public tree API, never a first-result fuzzy match or HTML scraping.
@MainActor enum IridiumArtworkCatalog {
    private static var indexes: [IridiumPlatform: [IridiumArtworkCandidate]] = [:]
    private static var retryAfter: [IridiumPlatform: Date] = [:]
    private static var pendingIndexes: [IridiumPlatform: Task<[IridiumArtworkCandidate], Error>] = [:]
    static func retry(platform: IridiumPlatform) { retryAfter[platform] = nil }
    static func steam(id: Int, title: String) -> IridiumArtworkCandidate {
        let covers = SteamGamesRules.artwork(appID: id, owned: { SteamOwnedLibrary.shared.game($0) })
        return IridiumArtworkCandidate(id: String(id), title: title, platform: .windows, source: "steam",
            coverURL: covers.first, backgroundURL: SteamCatalog.hero(id), coverAlternates: Array(covers.dropFirst()))
    }
    static func search(_ raw: String, platform: IridiumPlatform) async throws -> [IridiumArtworkCandidate] {
        let query = IridiumArtworkMatcher.query(raw, platform: platform)
        guard !query.isEmpty else { return [] }
        if platform == .windows {
            let found = try await SteamCatalog.search(query)
            try Task.checkCancellation()
            return found.map { steam(id: $0.id, title: $0.name) }
        }
        let all = try await index(platform: platform)
        let result = try await Task.detached(priority: .utility) {
            let normalized = IridiumArtworkMatcher.normalized(query, platform: platform)
            let matches = all.filter { IridiumArtworkMatcher.normalized($0.title, platform: platform).contains(normalized) }
            let exact = matches.filter { IridiumArtworkMatcher.normalized($0.title, platform: platform) == normalized }
            guard exact.count <= 100 else { throw LibraryError.message("This title is too ambiguous. Search a more specific title.") }
            // Preserve exact candidates for ambiguity checks; partial suggestions stay bounded.
            return exact + Array(matches.filter { !exact.contains($0) }.prefix(max(0, 40 - exact.count)))
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func index(platform: IridiumPlatform) async throws -> [IridiumArtworkCandidate] {
        if let cached = indexes[platform] { return cached }
        if let pending = pendingIndexes[platform] { return try await pending.value }
        if let date = retryAfter[platform], date > Date() {
            throw LibraryError.message("The artwork catalog is temporarily unavailable. Retry later or choose a local image.")
        }
        let operation = Task { @MainActor () async throws -> [IridiumArtworkCandidate] in
            let repository: String
            switch platform {
            case .gameBoy: repository = "Nintendo_-_Game_Boy"
            case .gameBoyColor: repository = "Nintendo_-_Game_Boy_Color"
            case .psp: repository = "Sony_-_PlayStation_Portable"
            case .windows: return []
            }
            let url = URL(string: "https://api.github.com/repos/libretro-thumbnails/\(repository)/git/trees/master?recursive=1")!
            let payloadData = try await data(url, limit: 8 * 1024 * 1024)
            return try await Task.detached(priority: .utility) {
                struct Tree: Decodable {
                    struct Item: Decodable { let path: String; let type: String }
                    let tree: [Item]
                    let truncated: Bool
                }
                let payload = try JSONDecoder().decode(Tree.self, from: payloadData)
                guard !payload.truncated, payload.tree.count <= 30_000 else {
                    throw LibraryError.message("The artwork catalog is incomplete. Choose your own image or retry later.")
                }
                let paths = Set(payload.tree.filter { $0.type == "blob" }.map(\.path))
                let root = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repository)/master/")!
                let all: [IridiumArtworkCandidate] = paths.sorted().compactMap { path in
                    let parts = path.split(separator: "/")
                    guard parts.count == 2, parts[0] == "Named_Boxarts", path.hasSuffix(".png"),
                          parts[1].utf8.count <= 512, !parts[1].contains("\\"), !parts[1].contains("..") else { return nil }
                    let filename = String(parts[1]), title = String(filename.dropLast(4))
                    let snap = "Named_Snaps/" + filename
                    return IridiumArtworkCandidate(id: filename, title: title, platform: platform, source: "libretro",
                        coverURL: root.appendingPathComponent(path),
                        backgroundURL: paths.contains(snap) ? root.appendingPathComponent(snap) : nil)
                }
                return all
            }.value
        }
        pendingIndexes[platform] = operation
        defer { pendingIndexes[platform] = nil }
        do {
            let all = try await operation.value
            indexes[platform] = all; retryAfter[platform] = nil
            return all
        } catch {
            // One cooldown per platform also covers unauthenticated GitHub
            // rate limits. Failed catalog access is never stored as no match.
            retryAfter[platform] = Date().addingTimeInterval(300)
            throw error
        }
    }
    nonisolated static func data(_ url: URL, limit: Int) async throws -> Data {
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https", url.user == nil, url.password == nil,
              ["api.github.com", "raw.githubusercontent.com"].contains(host) || host.hasSuffix(".steamstatic.com") else {
            throw LibraryError.message("This artwork source is unsupported.")
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue("Iridium-Game-Artwork", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Int64(limit), response.url?.host == url.host else {
            throw LibraryError.message("Artwork is unavailable right now. You can still play or choose a local image.")
        }
        var result = Data()
        for try await byte in bytes {
            if result.count % 16_384 == 0 { try Task.checkCancellation() }
            guard result.count < limit else { throw LibraryError.message("The artwork download is too large.") }
            result.append(byte)
        }
        try Task.checkCancellation()
        return result
    }
}

struct IridiumArtworkImage: View {
    let image: UIImage?
    var position = 0.5
    var fit = false
    var body: some View {
        GeometryReader { geometry in
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height).background(.black)
                } else {
                    let scale = max(geometry.size.width / max(image.size.width, 1), geometry.size.height / max(image.size.height, 1))
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .offset(x: (geometry.size.width - image.size.width * scale) / 2,
                                y: (geometry.size.height - image.size.height * scale) * position)
                }
            } else { Color(uiColor: .secondarySystemBackground) }
        }.clipped().accessibilityHidden(true)
    }
}
