import Combine
import Foundation
import SwiftUI
import UIKit
import ImageIO
import Security
import IridiumCore

struct LibraryAppearance: Codable, Equatable {
    var title: String?
    var matchID: Int?
    var matchName: String?
    var matchSource: String?
    var automaticLookup = true
    var cover: String?
    var portraitCover: Bool?
    var portraitSourceVersion: Int?
    var background: String?
    var customCover = false
    var customBackground = false
    var coverY = 0.5
    var backgroundY = 0.5
    var favorite = false
}

struct ArtworkMatch: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    var source: String? = nil
}

/// Presentation data never changes an executable, prefix, or save path.
@MainActor final class LibraryArtwork: ObservableObject {
    static let shared = LibraryArtwork()
    @Published private(set) var entries: [UUID: LibraryAppearance] = [:]
    @Published var backdropGameID: UUID?
    @Published var error: String?
    @Published private(set) var lookupNote: String?
    @Published private(set) var connected = false
    private let root: URL
    private let session: URLSession
    private let testCredential: String?
    private var attempted = Set<UUID>()
    private var localAttempted = Set<UUID>()
    private var revisions: [UUID: UUID] = [:]
    private let images = NSCache<NSString, UIImage>()
    private var loadingImages = Set<String>()
    private var missingImages = Set<String>()
    private var writable = true

    init(root: URL? = nil, session: URLSession = .shared, testCredential: String? = nil) {
        self.session = session
        self.testCredential = testCredential
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("LibraryArtwork", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let file = self.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                entries = try JSONDecoder().decode([UUID: LibraryAppearance].self, from: Data(contentsOf: file))
            }
        } catch {
            writable = false
            self.error = "Library appearance could not be opened. Your saved choices have not been overwritten."
        }
        images.totalCostLimit = 48 * 1024 * 1024
        connected = !apiKey.isEmpty
    }

    func appearance(_ id: UUID) -> LibraryAppearance { entries[id] ?? LibraryAppearance() }
    func title(_ game: GameRecord) -> String { appearance(game.id).title ?? appearance(game.id).matchName ?? game.title }

    func update(_ id: UUID, _ change: (inout LibraryAppearance) -> Void) throws {
        guard writable else { throw ArtworkError.message("Saved appearance data could not be read. Existing data has been preserved.") }
        var next = entries
        var item = appearance(id)
        change(&item)
        next[id] = item
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let previous = appearance(id)
        entries = next
        discard([previous.cover, previous.background])
        revisions[id] = UUID()
    }

    private func discard(_ names: [String?]) {
        let retained = Set(entries.values.flatMap { [$0.cover, $0.background].compactMap { $0 } })
        for name in names.compactMap({ $0 }) where !retained.contains(name) && name.hasSuffix(".jpg") && UUID(uuidString: String(name.dropLast(4))) != nil {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            images.removeObject(forKey: name as NSString)
        }
    }

    func image(_ name: String?) -> UIImage? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        if let image = images.object(forKey: name as NSString) { return image }
        guard let image = UIImage(contentsOfFile: root.appendingPathComponent(name).path) else { return nil }
        images.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    // UI reads must not load or decode artwork on the main thread during navigation.
    func displayImage(_ name: String?) -> UIImage? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        if let image = images.object(forKey: name as NSString) { return image }
        guard !loadingImages.contains(name), !missingImages.contains(name) else { return nil }
        loadingImages.insert(name)
        let path = root.appendingPathComponent(name).path
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)?.preparingForDisplay()
            }.value
            loadingImages.remove(name)
            if let image {
                images.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height * 4))
            } else { missingImages.insert(name) }
            objectWillChange.send()
        }
        return nil
    }

    func setImage(_ data: Data, id: UUID, background: Bool) throws {
        let name = try saveImage(data)
        do {
            try update(id) {
                if background { $0.background = name; $0.customBackground = true; $0.backgroundY = 0.5 }
                else { $0.cover = name; $0.customCover = true; $0.coverY = 0.5 }
            }
        } catch {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            throw error
        }
    }

    private func saveImage(_ data: Data) throws -> String {
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.88)
        else { throw ArtworkError.message("Choose a supported image smaller than 25 MB.") }
        let name = UUID().uuidString + ".jpg"
        try encoded.write(to: root.appendingPathComponent(name), options: .atomic)
        return name
    }

    func removeMatch(_ id: UUID) throws {
        try update(id) {
            $0.matchID = nil; $0.matchName = nil; $0.matchSource = nil; $0.automaticLookup = false
            if !$0.customCover { $0.cover = nil }
            if !$0.customBackground { $0.background = nil }
        }
    }

    static func query(_ raw: String) -> String {
        let leaf = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        return String(leaf.replacingOccurrences(of: #"(?i)\.exe$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }
    static func normalized(_ raw: String) -> String {
        query(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    func search(_ query: String) async throws -> [ArtworkMatch] {
        let cleaned = Self.query(query)
        guard !cleaned.isEmpty else { return [] }
        if !connected {
            struct SearchResult: Decodable {
                struct Item: Decodable { let id: Int; let name: String; let type: String }
                let items: [Item]
            }
            let result: SearchResult = try await storeRequest("storesearch/?term=" + (cleaned.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + "&l=english&cc=US")
            return result.items.filter { $0.type == "app" }.map { ArtworkMatch(id: $0.id, name: $0.name, source: "steam") }
        }
        return try await request("search/autocomplete/" + (cleaned.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
    }

    func prepare(_ games: [GameRecord]) async {
        for game in games {
            guard !Task.isCancelled else { return }
            if !localAttempted.contains(game.id) {
                localAttempted.insert(game.id)
                let current = appearance(game.id)
                if current.cover == nil && !current.customCover {
                    let data = await Task.detached(priority: .utility) { Self.localArtwork(game.installPath) }.value
                    if let data, appearance(game.id).cover == nil, !appearance(game.id).customCover {
                        do {
                            let name = try saveImage(data)
                            try update(game.id) { $0.cover = name }
                        } catch { self.lookupNote = "Local artwork could not be read. You can still play this game." }
                    }
                }
            }
            let current = appearance(game.id)
            if current.automaticLookup, !current.customCover, current.portraitSourceVersion != 2,
               let matchID = current.matchID, !attempted.contains(game.id) {
                attempted.insert(game.id)
                do { try await apply(ArtworkMatch(id: matchID, name: current.matchName ?? game.title, source: current.matchSource), to: game.id) }
                catch { lookupNote = "Portrait artwork is unavailable right now. You can still play." }
                continue
            }
            guard current.automaticLookup, current.matchID == nil, !attempted.contains(game.id) else { continue }
            attempted.insert(game.id)
            let revision = revisions[game.id]
            do {
                if let appID = Self.steamAppID(game.installPath) {
                    print("[IridiumArtwork] Found Steam app ID \(appID) for \(game.title)")
                    try await apply(ArtworkMatch(id: appID, name: game.title, source: "steam"), to: game.id)
                    print("[IridiumArtwork] Applied Steam artwork for \(game.title)")
                    continue
                }
                let matches = try await search(game.title)
                let exact = matches.filter { Self.normalized($0.name) == Self.normalized(game.title) }
                // A folder title alone is not sufficient evidence for an automatic match.
                let executable = Self.normalized(game.launchProfile.executablePath)
                guard exact.count == 1, executable == Self.normalized(exact[0].name), revisions[game.id] == revision else { continue }
                try await apply(exact[0], to: game.id)
            } catch is CancellationError { return }
            catch {
                print("[IridiumArtwork] Lookup failed for \(game.title): \(error.localizedDescription)")
                self.lookupNote = "Artwork is unavailable right now. Your games are still ready to use."
                return
            }
        }
    }

    nonisolated private static func localArtwork(_ path: String) -> Data? {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        // Only inspect explicit root artwork files, never scan game textures or saves.
        for name in ["cover.jpg", "cover.png", "folder.jpg", "icon.png", "game.ico"] {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 25 * 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { continue }
            return data
        }
        return nil
    }

    nonisolated static func steamAppID(_ path: String) -> Int? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        for name in ["steam_appid.txt", "steam_settings/force_appid.txt"] {
            let file = root.appendingPathComponent(name)
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let id = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 {
                return id
            }
        }
        let ini = root.appendingPathComponent("steam_emu.ini")
        if let values = try? ini.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size <= 1024 * 1024,
           let data = try? Data(contentsOf: ini),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           let match = text.firstMatch(of: /(?im)^\s*AppId\s*=\s*(\d+)\s*$/),
           let id = Int(match.1), id > 0 {
            return id
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in names {
                if let match = name.wholeMatch(of: /appmanifest_(\d+)\.acf/),
                   let id = Int(match.1), id > 0 {
                    return id
                }
            }
        }
        return nil
    }

    func apply(_ match: ArtworkMatch, to id: UUID) async throws {
        let revision = revisions[id]
        if match.source == "steam" {
            struct Details: Decodable {
                struct Game: Decodable {
                    struct Screenshot: Decodable { let path_full: URL }
                    let type: String
                    let name: String?
                    let header_image: URL?
                    let background_raw: URL?
                    let screenshots: [Screenshot]?
                }
                let success: Bool
                let data: Game?
            }
            let result: [String: Details] = try await storeRequest("appdetails?appids=\(match.id)")
            guard let result = result[String(match.id)], result.success, let game = result.data, game.type == "game" else {
                throw ArtworkError.message("This catalog entry is not an available game. Choose another match or keep your local entry.")
            }
            // Steam supplies these larger library assets for many, but not all, games.
            let assetRoot = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(match.id)/")
            let libraryCover = try? await download(assetRoot?.appendingPathComponent("library_600x900.jpg"))
            let cover: String?
            if let libraryCover { cover = libraryCover } else { cover = try await download(game.header_image) }
            defer { discard([cover]) }
            let libraryHero = try? await download(assetRoot?.appendingPathComponent("library_hero.jpg"))
            let background: String?
            if let libraryHero { background = libraryHero }
            else { background = try await download(game.screenshots?.first?.path_full ?? game.background_raw) }
            defer { discard([background]) }
            guard !Task.isCancelled, revisions[id] == revision else { return }
            try update(id) {
                $0.matchID = match.id; $0.matchName = game.name ?? match.name; $0.matchSource = "steam"
                if !$0.customCover { $0.cover = cover; $0.portraitCover = libraryCover != nil; $0.portraitSourceVersion = libraryCover == nil ? nil : 2 }
                if !$0.customBackground { $0.background = background }
            }
            lookupNote = nil
            return
        }
        struct RemoteImage: Decodable { let url: URL }
        let covers: [RemoteImage] = try await request("grids/game/\(match.id)?dimensions=600x900&types=static&nsfw=false&humor=false")
        let backgrounds: [RemoteImage] = try await request("heroes/game/\(match.id)?types=static&nsfw=false&humor=false")
        let cover = try await download(covers.first?.url)
        defer { discard([cover]) }
        let background = try await download(backgrounds.first?.url)
        defer { discard([background]) }
        guard !Task.isCancelled, revisions[id] == revision else { return }
        // Re-read after suspension so user choices always win a concurrent lookup.
        try update(id) {
            $0.matchID = match.id; $0.matchName = match.name; $0.matchSource = nil
            if !$0.customCover { $0.cover = cover; $0.portraitCover = true; $0.portraitSourceVersion = 2 }
            if !$0.customBackground { $0.background = background }
        }
    }

    private func download(_ url: URL?) async throws -> String? {
        guard let url else { return nil }
        guard url.scheme == "https", let host = url.host,
              host == "cdn2.steamgriddb.com" || host == "cdn.steamgriddb.com" || host == "images.steamgriddb.com" || host.hasSuffix(".steamstatic.com") || host == "steamcdn-a.akamaihd.net"
        else { throw ArtworkError.message("The artwork service returned an unsupported image address.") }
        let (file, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 25))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25 * 1024 * 1024
        else { throw ArtworkError.message("The artwork could not be downloaded.") }
        return try saveImage(Data(contentsOf: file))
    }

    // Public store endpoints are best-effort; failures never gate launching a local game.
    private func storeRequest<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "https://store.steampowered.com/api/" + path)!
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024 else {
            throw ArtworkError.message("The game catalog is unavailable. Try again later or use a custom image.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(_ path: String) async throws -> [T] {
        guard !apiKey.isEmpty else { throw ArtworkError.message("Connect SteamGridDB in Artwork Settings first.") }
        let url = URL(string: "https://www.steamgriddb.com/api/v2/" + path)!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024 else {
            throw ArtworkError.message("Artwork service unavailable. Check the connection and API key.")
        }
        return try JSONDecoder().decode(ArtworkResponse<T>.self, from: data).data
    }

    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "software.iridium.artwork", kSecAttrAccount as String: "SteamGridDB"]
    }
    private var apiKey: String {
        if let testCredential { return testCredential }
        var query = keyQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func connect(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(keyQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ArtworkError.message("Could not remove the saved connection.") }
        } else {
            let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            var status = SecItemUpdate(keyQuery as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                var query = keyQuery.merging(values) { _, new in new }
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw ArtworkError.message("Could not save the artwork connection securely.") }
        }
        connected = !key.isEmpty
        attempted.removeAll()
    }
}
private struct ArtworkResponse<T: Decodable>: Decodable { let data: [T] }
enum ArtworkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
