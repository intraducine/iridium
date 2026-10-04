import Foundation

struct SteamCloudTarget: Equatable, Identifiable, Sendable {
    let gameID: UUID
    let appID: UInt32
    var id: UUID { gameID }
}

struct SteamCloudFile: Codable, Equatable, Sendable {
    let path: String
    let sha: String
    let size: Int64
    let time: UInt64
}

struct SteamCloudEntry: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let action: String
    let local: SteamCloudFile?
    let remote: SteamCloudFile?
    var id: String { path }
    var name: String { path.components(separatedBy: "/").last ?? path }
}

struct SteamCloudChoice: Encodable, Sendable {
    let path: String
    let side: String
    let localSha: String?
    let remoteSha: String?
    init(_ entry: SteamCloudEntry, side: String) {
        path = entry.path
        self.side = side
        localSha = entry.local?.sha
        remoteSha = entry.remote?.sha
    }
}

struct SteamCloudStatus: Decodable, Equatable, Sendable {
    let gameId: String
    let appId: UInt32
    let enabled: Bool
    let phase: String
    let message: String
    let entries: [SteamCloudEntry]
    let backups: [String]
    var readyToPlay: Bool { phase == "ready" && entries.allSatisfy { ["same", "keptMissing"].contains($0.action) } }
}
