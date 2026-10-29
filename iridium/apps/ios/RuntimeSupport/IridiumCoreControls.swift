// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct IridiumCoreOption: Codable, Identifiable, Equatable {
    struct Choice: Codable, Equatable {
        let value: String
        let title: String
    }
    let key: String
    let title: String
    let info: String
    let category: String
    var value: String
    let defaultValue: String
    let choices: [Choice]
    let visible: Bool
    var restartRequired: Bool? = nil
    var id: String { key }
    var selectedTitle: String { choices.first { $0.value == value }?.title ?? value }
}

struct IridiumCoreControls: Decodable {
    var options: [IridiumCoreOption] = []
    var states = false
    var discCount = 0
    var discIndex = 0
    var players = 1
    var aspect: Double = 400.0 / 480.0
    var cheatFormats: [String]?
    var canChangeDisc: Bool?
    var contentFolders: [String: String]?
    var captureStatus: String?
    var patches: [IridiumCorePatch]?
}

struct IridiumCorePatch: Decodable {
    let name: String
    let code: String
    let enabled: Bool
    let userDefined: Bool
    var cheat: IridiumCheat { .init(name: name, format: "patch", code: code, enabled: enabled) }
}

struct IridiumCheat: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var format: String
    var code = ""
    var enabled = true

    static func title(_ format: String) -> String {
        switch format {
        case "gameshark": return "GameShark"
        case "gamegenie": return "Game Genie"
        case "cwcheat": return "CWCheat"
        case "gateway": return "Gateway"
        case "gecko": return "Gecko"
        case "ar": return "Action Replay"
        case "patch": return "Dolphin Patch"
        default: return format
        }
    }
    static func validate(_ items: [Self], formats: [String]) throws {
        guard items.count <= 64, Set(items.map(\.id)).count == items.count else { throw IridiumCheatError.invalid }
        var bytes = 0
        for item in items {
            guard formats.contains(item.format), !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.name.utf8.count < 128, item.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !item.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.code.utf8.count <= 8192, ![item.name, item.code].contains(where: { $0.utf8.contains(0) }) else { throw IridiumCheatError.invalid }
            bytes += item.name.utf8.count + item.code.utf8.count + item.format.utf8.count
        }
        guard bytes <= 65536 else { throw IridiumCheatError.invalid }
    }
    static func load(_ game: UUID) throws -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: "CoreCheats.\(game)") else { return [] }
        guard data.count <= 131072 else { throw IridiumCheatError.invalid }
        return try JSONDecoder().decode([Self].self, from: data)
    }
    static func save(_ items: [Self], game: UUID) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: "CoreCheats.\(game)")
    }
    static func command(_ items: [Self]) -> [String: Any] {
        ["operation": "cheats", "items": items.map { ["name": $0.name, "format": $0.format, "code": $0.code, "enabled": $0.enabled] }]
    }
}

enum IridiumCheatError: LocalizedError {
    case invalid
    var errorDescription: String? { "Check the cheat name, format, and code. Use up to 64 cheats, 127 bytes per name, 8 KB per code, and 64 KB in total." }
}

final class IridiumCoreOptionCollection {
    var options: [IridiumCoreOption] = []
}

enum IridiumCorePreferences {
    static func load(_ game: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "CoreOptions.\(game)") as? [String: String] ?? [:]
    }
    static func save(_ value: String, key: String, game: UUID) {
        var options = load(game); options[key] = value
        UserDefaults.standard.set(options, forKey: "CoreOptions.\(game)")
    }
}

struct IridiumConsoleStateRecord: Codable {
    let runtime: String
    let version: String
    let data: Data
}

/// Snapshots use a memory limit so large states reduce history, not free RAM.
struct IridiumRewindHistory {
    private var frames: [Data] = []
    private var bytes = 0
    let limit: Int
    init(limit: Int = 32 * 1024 * 1024) { self.limit = max(0, limit) }
    mutating func append(_ data: Data) {
        guard !data.isEmpty, data.count <= limit else { return }
        frames.append(data); bytes += data.count
        while bytes > limit { bytes -= frames.removeFirst().count }
    }
    mutating func pop(steps: Int = 1) -> Data? {
        var result: Data?
        for _ in 0..<max(0, min(steps, frames.count)) {
            let state = frames.removeLast(); bytes -= state.count; result = state
        }
        return result
    }
    mutating func clear() { frames.removeAll(); bytes = 0 }
}

extension IridiumCorePreferences {
    static func pspStartup(_ game: UUID) -> [String: String] {
        load(game).filter { ["bSoftwareRendering", "iPSPModel"].contains($0.key) && ["0", "1"].contains($0.value) }
    }
}
