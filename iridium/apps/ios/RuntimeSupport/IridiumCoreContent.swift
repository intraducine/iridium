// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumCoreContent {
    static func components(_ relative: String) throws -> [String] {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard relative.utf8.count <= 4096, parts.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") })
        else { throw IridiumRuntimeError.unsafePath }
        return parts
    }
    static func saveFolders(_ folders: [String: String], game: UUID) {
        let safe = folders.filter { $0.key.utf8.count <= 128 && (try? components($0.value)) != nil }
        if !safe.isEmpty { UserDefaults.standard.set(safe, forKey: "CoreFolders.\(game)") }
    }
    static func folders(_ game: IridiumConsoleGame) -> [String: String] {
        if game.runtimeID == "flycast" { return ["VMU and Arcade Saves": "."] }
        if game.runtimeID == "azahar" { return ["3DS Storage": "Azahar"] }
        return UserDefaults.standard.dictionary(forKey: "CoreFolders.\(game.id)") as? [String: String] ?? [:]
    }
    static func directory(_ relative: String, root: URL, create: Bool = false) throws -> URL {
        try IridiumConsoleStore(root: root).checked(relative == "." ? [] : components(relative), createDirectory: create)
    }
}
