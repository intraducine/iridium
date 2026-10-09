// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Artwork is presentation-only. These records never contain a ROM, executable,
/// prefix, runtime selection, or save path.
struct IridiumArtworkMatch: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let platform: IridiumPlatform
    let source: String
}

struct IridiumArtworkCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let platform: IridiumPlatform
    let source: String
    var coverURL: URL? = nil
    var backgroundURL: URL? = nil
    var coverAlternates: [URL] = []

    var match: IridiumArtworkMatch {
        IridiumArtworkMatch(id: id, title: title, platform: platform, source: source)
    }
}

struct IridiumArtworkAppearance: Codable, Equatable, Sendable {
    var title: String?
    var match: IridiumArtworkMatch?
    var automaticLookup = true
    var cover: String?
    var background: String?
    // A deliberately empty custom image is also an override.
    var customCover = false
    var customBackground = false
    // Optional for compatibility with appearance files written before these
    // explicit per-slot choices existed. Nil preserves legacy custom artwork.
    var ignoreLegacyCover: Bool?
    var ignoreLegacyBackground: Bool?
    var coverY = 0.5
    var backgroundY = 0.5
    var revision = UUID()
}

struct IridiumArtworkTicket: Equatable, Sendable {
    let gameID: UUID
    fileprivate let revision: UUID?
    fileprivate let requestID: UUID
    fileprivate let automatic: Bool
}

enum IridiumArtworkStateError: LocalizedError {
    case unsafePath, invalidAppearance, unreadableStore, newerStore, changedOnDisk

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The artwork path is not a safe local file."
        case .invalidAppearance: return "The artwork choices contain invalid metadata."
        case .unreadableStore: return "Saved artwork choices could not be read. The original file has been preserved."
        case .newerStore: return "Saved artwork choices use a newer format. The original file has been preserved."
        case .changedOnDisk: return "Saved artwork choices changed elsewhere. Reopen the library before editing them."
        }
    }
}

/// The owner serializes access (the frontend uses its main-actor model). Image
/// decoding and downloads happen elsewhere. A lease spans those asynchronous
/// operations, so only the newest request at the current revision may commit.
final class IridiumArtworkStore {
    let root: URL
    private(set) var entries: [UUID: IridiumArtworkAppearance]
    private var requests: [UUID: IridiumArtworkTicket] = [:]
    private var savedData: Data?
    private let manager = FileManager.default
    private static let documentName = "appearance.json"
    private static let maximumDocumentSize = 4 * 1024 * 1024
    private struct Header: Decodable { let version: Int }
    private struct Document: Codable {
        let version: Int
        let entries: [String: IridiumArtworkAppearance]
    }

    init(root: URL) throws {
        guard root.isFileURL else { throw IridiumArtworkStateError.unsafePath }
        self.root = root.standardizedFileURL
        entries = [:]
        let loaded = try readDocument()
        entries = loaded.entries
        savedData = loaded.data
    }

    func appearance(_ id: UUID) -> IridiumArtworkAppearance {
        entries[id] ?? IridiumArtworkAppearance(revision: id)
    }

    func update(_ id: UUID, _ change: (inout IridiumArtworkAppearance) -> Void) throws {
        var item = appearance(id)
        change(&item)
        item.revision = UUID()
        try validate(item)
        var next = entries
        next[id] = item
        try persist(next)
        entries = next
        requests[id] = nil
    }

    /// Calling begin again supersedes the previous request, even before either
    /// request has produced a result. Explicit matching can run while disabled.
    func begin(_ id: UUID, automatic: Bool = true) -> IridiumArtworkTicket? {
        guard !Task.isCancelled, !automatic || appearance(id).automaticLookup else { return nil }
        let ticket = IridiumArtworkTicket(gameID: id, revision: entries[id]?.revision,
                                         requestID: UUID(), automatic: automatic)
        requests[id] = ticket
        return ticket
    }

    func cancel(_ ticket: IridiumArtworkTicket) {
        if requests[ticket.gameID] == ticket { requests[ticket.gameID] = nil }
    }

    /// A false result means the result was stale, cancelled, or no longer
    /// enabled. The caller may discard newly downloaded, unreferenced files.
    @discardableResult
    func apply(_ candidate: IridiumArtworkCandidate, coverName: String?, backgroundName: String?,
               ticket: IridiumArtworkTicket) throws -> Bool {
        guard !Task.isCancelled,
              requests[ticket.gameID] == ticket,
              entries[ticket.gameID]?.revision == ticket.revision,
              !ticket.automatic || appearance(ticket.gameID).automaticLookup else { return false }
        for name in [coverName, backgroundName].compactMap({ $0 }) { _ = try imageURL(name) }
        try update(ticket.gameID) { item in
            if item.match != candidate.match {
                if !item.customCover { item.cover = nil; item.coverY = 0.5 }
                if !item.customBackground { item.background = nil; item.backgroundY = 0.5 }
            }
            item.match = candidate.match
            if !ticket.automatic { item.automaticLookup = true }
            if !item.customCover, let coverName { item.cover = coverName; item.coverY = 0.5 }
            if !item.customBackground, let backgroundName { item.background = backgroundName; item.backgroundY = 0.5 }
        }
        return true
    }

    func removeMatch(_ id: UUID) throws {
        try update(id) {
            $0.match = nil
            $0.automaticLookup = false
            if !$0.customCover { $0.cover = nil; $0.coverY = 0.5 }
            if !$0.customBackground { $0.background = nil; $0.backgroundY = 0.5 }
        }
    }

    /// Never return a traversal or symlink destination to the image cache.
    /// Missing safe filenames are allowed because the cache also uses this
    /// method to choose its destination before an atomic write.
    func imageURL(_ name: String) throws -> URL {
        try Self.validateFilename(name)
        return try checked(name)
    }

    /// Create the cache directory only for an intended image write, after
    /// validating both the filename and any existing appearance document.
    func prepareImageURL(_ name: String) throws -> URL {
        _ = try imageURL(name)
        guard try readDocument().data == savedData else { throw IridiumArtworkStateError.changedOnDisk }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return try imageURL(name)
    }

    private static func validateFilename(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.utf8.count <= 160,
              name != ".", name != "..", name != documentName,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              name.first != "." else { throw IridiumArtworkStateError.unsafePath }
    }

    private func checked(_ name: String) throws -> URL {
        guard root.resolvingSymlinksInPath().path == root.path else { throw IridiumArtworkStateError.unsafePath }
        if manager.fileExists(atPath: root.path) {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            else { throw IridiumArtworkStateError.unsafePath }
        }
        let url = root.appendingPathComponent(name)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw IridiumArtworkStateError.unsafePath }
        guard url.resolvingSymlinksInPath().path == url.path else { throw IridiumArtworkStateError.unsafePath }
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw IridiumArtworkStateError.unsafePath }
        }
        return url
    }

    private func validate(_ item: IridiumArtworkAppearance) throws {
        guard item.title.map({ $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true,
              item.coverY.isFinite, (0...1).contains(item.coverY),
              item.backgroundY.isFinite, (0...1).contains(item.backgroundY)
        else { throw IridiumArtworkStateError.invalidAppearance }
        if let match = item.match {
            guard !match.id.isEmpty, match.id.utf8.count <= 512, !match.id.contains("\0"),
                  !match.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  match.title.utf8.count <= 512, !match.title.contains("\0"),
                  !match.source.isEmpty, match.source.utf8.count <= 128, !match.source.contains("\0")
            else { throw IridiumArtworkStateError.invalidAppearance }
        }
        for name in [item.cover, item.background].compactMap({ $0 }) { _ = try imageURL(name) }
    }

    private func readDocument() throws -> (entries: [UUID: IridiumArtworkAppearance], data: Data?) {
        let url = try checked(Self.documentName)
        guard manager.fileExists(atPath: url.path) else { return ([:], nil) }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= Self.maximumDocumentSize else { throw IridiumArtworkStateError.unreadableStore }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumDocumentSize + 1) ?? Data()
        guard data.count <= Self.maximumDocumentSize else { throw IridiumArtworkStateError.unreadableStore }
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw IridiumArtworkStateError.unreadableStore }
        guard header.version == 1 else { throw IridiumArtworkStateError.newerStore }
        let document: Document
        do { document = try decoder.decode(Document.self, from: data) }
        catch { throw IridiumArtworkStateError.unreadableStore }
        var result: [UUID: IridiumArtworkAppearance] = [:]
        for (key, value) in document.entries {
            guard let id = UUID(uuidString: key), result[id] == nil else { throw IridiumArtworkStateError.unreadableStore }
            try validate(value)
            result[id] = value
        }
        return (result, data)
    }

    private func persist(_ next: [UUID: IridiumArtworkAppearance]) throws {
        // Recheck the disk before every mutation. Corrupt, future-version and
        // independently changed files are preserved rather than repaired over.
        guard try readDocument().data == savedData else { throw IridiumArtworkStateError.changedOnDisk }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = Document(version: 1, entries: Dictionary(uniqueKeysWithValues: next.map { ($0.key.uuidString, $0.value) }))
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentSize else { throw IridiumArtworkStateError.invalidAppearance }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: checked(Self.documentName), options: .atomic)
        savedData = data
    }
}

/// Exact matching is platform scoped and deliberately conservative. Only known
/// ROM extensions and trailing region/revision/language metadata are removed;
/// subtitle, disc, hack, demo, and unknown parenthesized words remain significant.
enum IridiumArtworkMatcher {
    private static let tagExpression = try! NSRegularExpression(pattern: #"\([^()]*\)|\[[^\[\]]*\]"#)
    private static let knownTags: Set<String> = [
        "world", "usa", "us", "u", "europe", "eur", "eu", "e", "japan", "jp", "j", "uk", "australia",
        "germany", "france", "italy", "spain", "korea", "china", "taiwan", "brazil", "canada", "sweden",
        "netherlands", "portugal", "russia", "asia", "hong kong",
        "en", "ja", "fr", "de", "es", "it", "nl", "pt", "sv", "da", "no", "fi", "ko", "zh", "ru", "pl", "cs", "hu", "el", "tr", "ar",
        "english", "japanese", "french", "german", "spanish", "italian", "dutch", "portuguese", "korean", "chinese"
    ]

    static func query(_ raw: String, platform: IridiumPlatform) -> String {
        var leaf = filename(raw, platform: platform).replacingOccurrences(of: "_", with: " ")
        while let tag = trailingTag(leaf), recognizedTag(tag.contents) {
            leaf = String(leaf[..<tag.start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return leaf
    }

    static func normalized(_ raw: String, platform: IridiumPlatform) -> String {
        words(query(raw, platform: platform))
    }

    static func exactMatch(_ title: String, platform: IridiumPlatform,
                           candidates: [IridiumArtworkCandidate]) -> IridiumArtworkCandidate? {
        let eligible = candidates.filter { $0.platform == platform && !$0.id.isEmpty && !$0.source.isEmpty }
        let fullTitle = fullNormalized(title, platform: platform)
        guard !fullTitle.isEmpty else { return nil }
        let key = normalized(title, platform: platform)
        guard !key.isEmpty else { return nil }
        if fullTitle != key {
            let full = eligible.filter { fullNormalized($0.title, platform: platform) == fullTitle }
            if !full.isEmpty { return full.count == 1 ? full[0] : nil }
        }
        let exact = eligible.filter { normalized($0.title, platform: platform) == key }
        return exact.count == 1 ? exact[0] : nil
    }

    private static func words(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        // Only the documented region/revision/language tags are ignorable.
        // Preserve every other qualifier, including punctuation-only [!] and
        // editions such as (A+), instead of erasing their meaning as separators.
        for match in tagExpression.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            guard let range = Range(match.range, in: folded) else { continue }
            let tag = String(folded[range].dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !recognizedTag(tag) {
                components.append("tag:" + tag.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-"))
            }
        }
        return components.joined(separator: " ")
    }

    private static func fullNormalized(_ raw: String, platform: IridiumPlatform) -> String {
        // Retain suffix tags here so explicit regional filenames take priority
        // over the region-stripped comparison used only as a fallback.
        words(filename(raw, platform: platform))
    }

    private static func filename(_ raw: String, platform: IridiumPlatform) -> String {
        guard raw.utf8.count <= 2048 else { return "" }
        var leaf = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        leaf = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = (leaf as NSString).pathExtension.lowercased()
        let extensions: [String]
        switch platform {
        case .windows: extensions = ["exe"]
        case .gameBoy: extensions = ["gb"]
        case .gameBoyColor: extensions = ["gbc"]
        case .psp: extensions = ["iso", "cso", "pbp", "elf"]
        }
        if extensions.contains(suffix) { leaf = String(leaf.dropLast(suffix.count + 1)) }
        return leaf.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trailingTag(_ value: String) -> (start: String.Index, contents: String)? {
        guard let end = value.last, end == ")" || end == "]" else { return nil }
        let open: Character = end == ")" ? "(" : "["
        guard let start = value.lastIndex(of: open) else { return nil }
        let contents = String(value[value.index(after: start)..<value.index(before: value.endIndex)])
        guard !contents.contains(where: { "()[]".contains($0) }) else { return nil }
        return (start, contents)
    }

    private static func recognizedTag(_ value: String) -> Bool {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.range(of: #"^(?:rev(?:ision)?\s+(?:[a-z]|\d+(?:\.\d+){0,3}[a-z]?)|(?:v|version\s+)\d+(?:\.\d+){0,3})$"#,
                         options: .regularExpression) != nil { return true }
        let components = lowered.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !components.isEmpty && components.allSatisfy { knownTags.contains($0) }
    }
}
