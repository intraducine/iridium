// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine

/// The shared editor and player use the same serialized controls. Existing
/// Madeira files and per-console UserDefaults remain readable and untouched.
struct IridiumControlLayoutState: Codable, Equatable {
    var version = 1
    var controls: [TouchControl]
    var visible: Bool
    var size: Double
    var automatic: Bool?
    var opacity: Double?

    func validate(for platform: IridiumPlatform) throws {
        guard version == 1, controls.count <= 128,
              Set(controls.map(\.id)).count == controls.count,
              size.isFinite, (0.5...2).contains(size),
              opacity.map({ $0.isFinite && (0.15...1).contains($0) }) ?? true,
              controls.allSatisfy({ c in
                  c.nx.isFinite && c.ny.isFinite && c.scale.isFinite &&
                  (0...1).contains(c.nx) && (0...1).contains(c.ny) && (0.5...3).contains(c.scale) &&
                  (c.opacity.map { $0.isFinite && (0.15...1).contains($0) } ?? true) &&
                  (platform == .windows || c.action.padName.map { IridiumControlActions.names(for: platform).contains($0) } == true)
              }) else { throw IridiumControlProfileError.invalidLayout }
    }
}

enum IridiumControlActions {
    static func names(for platform: IridiumPlatform) -> [String] {
        let directions = ["DPad", "D↑", "D↓", "D←", "D→", "Menu", "View"]
        switch platform {
        case .gameBoy, .gameBoyColor: return ["A", "B"] + directions
        case .psp: return ["A", "B", "X", "Y", "LB", "RB", "LS"] + directions
        case .nintendo3DS: return ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "LS", "RS", "R3"] + directions
        default: return ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "LS", "RS", "L3", "R3"] + directions
        }
    }
    static func system(_ platform: IridiumPlatform) -> IridiumPlatform { platform == .gameBoyColor ? .gameBoy : platform }
}

struct IridiumControlProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var platform: IridiumPlatform
    var layout: IridiumControlLayoutState
}

struct IridiumControlSelection: Codable, Equatable {
    var profileID: UUID?
    var layout: IridiumControlLayoutState?
    static let inherit = Self()
}

enum IridiumControlProfileError: LocalizedError {
    case invalidLayout, unreadable, newerVersion, missingProfile, invalidName
    var errorDescription: String? {
        switch self {
        case .invalidLayout: return "These controls could not be read. The saved copy has been kept. Choose another profile or reset this layout."
        case .unreadable: return "Saved control profiles could not be read. The original file has been kept; close this editor and restore a readable copy before saving."
        case .newerVersion: return "These profiles were saved by a newer Iridium version. Update Iridium to edit them."
        case .missingProfile: return "This profile is no longer available for this system. Choose another profile."
        case .invalidName: return "Enter a profile name with 1–80 characters."
        }
    }
}

final class IridiumControlProfileStore: ObservableObject {
    static let shared = IridiumControlProfileStore()
    struct Game: Codable, Equatable { var platform: IridiumPlatform; var selection: IridiumControlSelection }
    struct Document: Codable, Equatable {
        var version = 1
        var profiles: [IridiumControlProfile] = []
        var systems: [String: IridiumControlSelection] = [:]
        // An explicit inherited record also shadows a legacy game override.
        var games: [String: Game] = [:]
    }
    @Published private(set) var document = Document()
    private(set) var loadError: Error?
    private let url: URL
    private let defaults: UserDefaults
    private let write: (Data, URL) throws -> Void
    private var savedData: Data?

    init(url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("iridium-control-profiles.json"),
         defaults: UserDefaults = .standard,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url; self.defaults = defaults; self.write = write
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw IridiumControlProfileError.unreadable }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Document.self, from: data)
            guard decoded.version == 1 else { throw IridiumControlProfileError.newerVersion }
            try validate(decoded); document = decoded; savedData = data
        } catch { loadError = error is IridiumControlProfileError ? error : IridiumControlProfileError.unreadable }
    }

    func profiles(for platform: IridiumPlatform) -> [IridiumControlProfile] {
        document.profiles.filter { $0.platform == IridiumControlActions.system(platform) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func selection(platform: IridiumPlatform, gameID: UUID?) -> IridiumControlSelection {
        if let gameID { return document.games[gameID.uuidString]?.selection ?? .inherit }
        return document.systems[IridiumControlActions.system(platform).rawValue] ?? .inherit
    }
    func hasGameOverride(_ id: UUID) -> Bool {
        guard let value = document.games[id.uuidString] else { return defaults.data(forKey: "IridiumConsoleControlLayout." + id.uuidString) != nil }
        return value.selection != .inherit
    }
    func hasSelection(platform: IridiumPlatform, gameID: UUID?) -> Bool {
        if let gameID, document.games[gameID.uuidString] != nil { return true }
        return document.systems[IridiumControlActions.system(platform).rawValue] != nil
    }
    private func layout(_ selection: IridiumControlSelection, platform: IridiumPlatform) throws -> IridiumControlLayoutState? {
        if let id = selection.profileID {
            guard let p = document.profiles.first(where: { $0.id == id && $0.platform == IridiumControlActions.system(platform) }) else { throw IridiumControlProfileError.missingProfile }
            return p.layout
        }
        return selection.layout
    }
    func resolve(platform: IridiumPlatform, gameID: UUID?, builtIn: IridiumControlLayoutState) throws -> IridiumControlLayoutState {
        if let loadError { throw loadError }
        let system = try layout(selection(platform: platform, gameID: nil), platform: platform) ?? builtIn
        var game: IridiumControlLayoutState?
        if let id = gameID {
            if let record = document.games[id.uuidString] {
                guard record.platform == IridiumControlActions.system(platform) else { throw IridiumControlProfileError.invalidLayout }
                game = try layout(record.selection, platform: platform)
            } else if platform != .windows, let data = defaults.data(forKey: "IridiumConsoleControlLayout." + id.uuidString) {
                game = try JSONDecoder().decode(IridiumControlLayoutState.self, from: data)
                try game?.validate(for: platform)
            }
        }
        guard var game else { return system }
        if game.automatic == true { game.controls = system.controls; game.automatic = system.automatic }
        return game
    }
    func set(_ selection: IridiumControlSelection, platform: IridiumPlatform, gameID: UUID?) throws {
        var next = document
        if let id = gameID { next.games[id.uuidString] = Game(platform: IridiumControlActions.system(platform), selection: selection) }
        else { next.systems[IridiumControlActions.system(platform).rawValue] = selection }
        try persist(next)
    }
    @discardableResult func saveProfile(name: String, platform: IridiumPlatform, layout: IridiumControlLayoutState, replacing id: UUID? = nil) throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { throw IridiumControlProfileError.invalidName }
        var next = document
        let profile = IridiumControlProfile(id: id ?? UUID(), name: clean, platform: IridiumControlActions.system(platform), layout: layout)
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
            guard next.profiles[index].platform == profile.platform else { throw IridiumControlProfileError.missingProfile }
            next.profiles[index] = profile
        } else { next.profiles.append(profile) }
        try persist(next); return profile.id
    }
    func deleteProfile(_ id: UUID) throws {
        guard let profile = document.profiles.first(where: { $0.id == id }) else { throw IridiumControlProfileError.missingProfile }
        var next = document
        // Existing users keep the exact layout when its reusable name is removed.
        for key in next.systems.keys where next.systems[key]?.profileID == id { next.systems[key] = .init(layout: profile.layout) }
        for key in next.games.keys where next.games[key]?.selection.profileID == id { next.games[key]?.selection = .init(layout: profile.layout) }
        next.profiles.removeAll { $0.id == id }; try persist(next)
    }
    private func persist(_ next: Document) throws {
        if let loadError { throw loadError }
        try validate(next)
        // Recheck disk identity so a second writer/future version is not lost.
        var diskData: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw IridiumControlProfileError.unreadable }
            diskData = try Data(contentsOf: url)
        }
        guard diskData == savedData else { throw IridiumControlProfileError.unreadable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next); try write(data, url); savedData = data; document = next
    }
    private func validate(_ value: Document) throws {
        guard value.version == 1, value.profiles.count <= 256, value.games.count <= 4096,
              Set(value.profiles.map(\.id)).count == value.profiles.count else { throw IridiumControlProfileError.unreadable }
        for p in value.profiles { guard !p.name.isEmpty, p.name.count <= 80 else { throw IridiumControlProfileError.invalidName }; try p.layout.validate(for: p.platform) }
        func check(_ selection: IridiumControlSelection, _ platform: IridiumPlatform) throws {
            guard selection.profileID == nil || selection.layout == nil else { throw IridiumControlProfileError.invalidLayout }
            if let id = selection.profileID { guard value.profiles.contains(where: { $0.id == id && $0.platform == platform }) else { throw IridiumControlProfileError.missingProfile } }
            try selection.layout?.validate(for: platform)
        }
        for (key, selection) in value.systems { guard let platform = IridiumPlatform(rawValue: key) else { throw IridiumControlProfileError.invalidLayout }; try check(selection, platform) }
        for (key, record) in value.games { guard UUID(uuidString: key) != nil else { throw IridiumControlProfileError.invalidLayout }; try check(record.selection, record.platform) }
    }
}
