// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Local evidence only. No binary, binary hash or filesystem path is sent to a catalog.
struct IridiumGameIdentity: Sendable {
    var manifestSteamID: Int?
    var productName: String?
    var metadataNames: [String] = []
    var steamHints: Set<Int> = []
    var hints: [String] = []
    var conflict = false

    var queries: [String] {
        var seen = Set<String>()
        return ([productName].compactMap { $0 } + metadataNames + hints).filter {
            seen.insert(IridiumArtworkMatcher.normalized($0, platform: .windows)).inserted
        }.prefix(5).map { $0 }
    }
    func mayAutomaticallyMatch(_ candidate: IridiumArtworkCandidate) -> Bool {
        guard !conflict, candidate.source == "steam", let id = Int(candidate.id) else { return false }
        if let manifestSteamID { return id == manifestSteamID }
        if !steamHints.isEmpty && !steamHints.contains(id) { return false }
        let key = IridiumArtworkMatcher.normalized(candidate.title, platform: .windows)
        let matchingMetadata = metadataNames.contains { IridiumArtworkMatcher.normalized($0, platform: .windows) == key }
        let matchingHint = hints.contains { IridiumArtworkMatcher.normalized($0, platform: .windows) == key }
        let productMatches = productName.map { IridiumArtworkMatcher.normalized($0, platform: .windows) == key } ?? false
        // A folder/filename or an unverified steam_appid.txt alone is a suggestion.
        return (productMatches && (matchingMetadata || matchingHint)) ||
            (steamHints == [id] && (productMatches || matchingMetadata || matchingHint))
    }

    static func inspect(title: String, relativePath: String, drive: URL) -> Self {
        var result = Self(hints: IridiumArtworkMatcher.identificationQueries(title: title, executableRelativePath: relativePath))
        let root = drive.resolvingSymlinksInPath().standardizedFileURL
        let executable = root.appendingPathComponent(relativePath).standardizedFileURL
        guard IridiumGameStorage.windowsRelative(executable, drive: root) != nil else { return result }
        if executable.pathExtension.lowercased() == "exe" { result.productName = PEVersionName.read(executable) }
        var folder = executable.deletingLastPathComponent()
        var manifests: [Int: String] = [:]
        for _ in 0..<4 {
            guard IridiumGameStorage.windowsRelative(folder, drive: root) != nil else { break }
            if let data = localData(folder.appendingPathComponent("steam_appid.txt"), root: folder, limit: 128),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let id = Int(text), id > 0, id <= Int(UInt32.max) { result.steamHints.insert(id) }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted().prefix(64) where name.hasPrefix("goggame-") && name.hasSuffix(".info") {
                if let data = localData(folder.appendingPathComponent(name), root: folder, limit: 64 * 1024),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = cleanTitle(info["name"] as? String) { result.metadataNames.append(name) }
            }
            if folder.deletingLastPathComponent().lastPathComponent.lowercased() == "common" {
                let steamApps = folder.deletingLastPathComponent().deletingLastPathComponent()
                if steamApps.lastPathComponent.lowercased() == "steamapps" {
                    for file in ((try? FileManager.default.contentsOfDirectory(atPath: steamApps.path)) ?? []).sorted().prefix(2000)
                        where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                        guard let id = Int(file.dropFirst(12).dropLast(4)), id > 0, id <= Int(UInt32.max),
                              let data = localData(steamApps.appendingPathComponent(file), root: steamApps, limit: 1 << 20),
                              var parser = try? SteamKeyValues(data), let parsed = try? parser.read(),
                              let state = parsed["AppState"], state["appid"]?.string == String(id),
                              state["installdir"]?.string?.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                              let name = cleanTitle(state["name"]?.string) else { continue }
                        manifests[id] = name
                    }
                }
            }
            folder.deleteLastPathComponent()
        }
        result.conflict = manifests.count > 1 || result.steamHints.count > 1
        if manifests.count == 1, let pair = manifests.first {
            result.manifestSteamID = pair.key
            result.metadataNames.insert(pair.value, at: 0)
        }
        return result
    }

    private static func localData(_ url: URL, root: URL, limit: Int) -> Data? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        guard path.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              let file = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
    fileprivate static func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        guard (2...200).contains(title.count), !title.contains("/"), !title.contains("\\"),
              title.rangeOfCharacter(from: .controlCharacters) == nil,
              !["game", "application", "unity", "unityplayer", "unreal engine", "launcher"].contains(title.lowercased()) else { return nil }
        return title
    }
}

/// Bounded PE resource reader, not a heuristic scan of executable strings.
/// https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
/// https://learn.microsoft.com/en-us/windows/win32/menurc/vs-versioninfo
private enum PEVersionName {
    private struct Bytes {
        let data: Data
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }
    }
    static func read(_ url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func read(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count > 0, count <= 4 << 20 else { return nil }
            do {
                try file.seek(toOffset: UInt64(offset))
                guard let data = try file.read(upToCount: count), data.count == count else { return nil }
                return data
            } catch { return nil }
        }
        guard let dos = read(0, 64), dos.starts(with: [0x4d, 0x5a]),
              let peOffset = Bytes(data: dos).u32(60), (64..<(16 << 20)).contains(peOffset),
              let coff = read(peOffset, 24), coff.starts(with: [0x50, 0x45, 0, 0]),
              let sections = Bytes(data: coff).u16(6), (1...96).contains(sections),
              let optionalSize = Bytes(data: coff).u16(20), optionalSize <= 4096,
              let headers = read(peOffset + 24, optionalSize + sections * 40) else { return nil }
        let h = Bytes(data: headers)
        guard let magic = h.u16(0), magic == 0x10b || magic == 0x20b else { return nil }
        let directories = magic == 0x10b ? 96 : 112
        guard optionalSize >= directories + 24, let count = h.u32(directories - 4), count >= 3,
              let resourceRVA = h.u32(directories + 16), resourceRVA > 0,
              let resourceSize = h.u32(directories + 20), (16...(4 << 20)).contains(resourceSize) else { return nil }
        func fileOffset(_ rva: Int, size: Int) -> Int? {
            for i in 0..<sections {
                let section = optionalSize + i * 40
                guard let address = h.u32(section + 12), let rawSize = h.u32(section + 16),
                      let pointer = h.u32(section + 20) else { continue }
                if rva >= address, rva - address + size <= rawSize { return pointer + rva - address }
            }
            return nil
        }
        guard let offset = fileOffset(resourceRVA, size: resourceSize), let data = read(offset, resourceSize) else { return nil }
        let resources = Bytes(data: data)
        var visited = Set<Int>(), payloads: [Data] = []
        var remainingPayloads = 16, remainingPayloadBytes = 4 << 20
        var payloadBudgetExhausted = false
        func directory(_ at: Int, depth: Int) {
            guard !payloadBudgetExhausted, depth <= 3, visited.count < 64, visited.insert(at).inserted,
                  let named = resources.u16(at + 12), let ids = resources.u16(at + 14), named + ids <= 256,
                  at + 16 + (named + ids) * 8 <= data.count else { return }
            for i in 0..<(named + ids) {
                guard !payloadBudgetExhausted else { return }
                let entry = at + 16 + i * 8
                guard let id = resources.u32(entry), let target = resources.u32(entry + 4), depth != 0 || id == 16 else { continue }
                let next = target & 0x7fff_ffff
                if target & 0x8000_0000 != 0 {
                    directory(next, depth: depth + 1)
                    guard !payloadBudgetExhausted else { return }
                } else if let rva = resources.u32(next), let size = resources.u32(next + 4),
                          size > 0, size <= 1 << 20, let start = fileOffset(rva, size: size) {
                    // Reserve globally before I/O and retention, including
                    // repeated leaves and failures across recursive siblings.
                    guard remainingPayloads > 0, size <= remainingPayloadBytes else {
                        payloadBudgetExhausted = true; return
                    }
                    remainingPayloads -= 1; remainingPayloadBytes -= size
                    if let payload = read(start, size) { payloads.append(payload) }
                    if remainingPayloads == 0 || remainingPayloadBytes == 0 {
                        payloadBudgetExhausted = true; return
                    }
                }
            }
        }
        directory(0, depth: 0)
        guard !payloadBudgetExhausted else { return nil }
        var values: [String: String] = [:]
        for payload in payloads {
            let view = Bytes(data: payload)
            func node(_ start: Int, end: Int, path: [String]) {
                guard path.count < 5, let length = view.u16(start), length >= 8, start + length <= end,
                      let valueLength = view.u16(start + 2), let type = view.u16(start + 4) else { return }
                var cursor = start + 6, keyBytes = Data(), terminated = false
                while cursor + 2 <= start + length, keyBytes.count < 256 {
                    guard let word = view.u16(cursor) else { return }; cursor += 2
                    if word == 0 { terminated = true; break }
                    keyBytes.append(UInt8(word & 255)); keyBytes.append(UInt8(word >> 8))
                }
                guard terminated, let key = String(data: keyBytes, encoding: .utf16LittleEndian),
                      !path.isEmpty || key == "VS_VERSION_INFO" else { return }
                cursor = (cursor + 3) & ~3
                let bytes = valueLength * (type == 1 ? 2 : 1)
                guard cursor + bytes <= start + length else { return }
                if path.count == 3, path[1] == "StringFileInfo", type == 1,
                   key == "ProductName" || key == "FileDescription", bytes <= 1024,
                   let title = IridiumGameIdentity.cleanTitle(String(data: payload.subdata(in: cursor..<(cursor + bytes)), encoding: .utf16LittleEndian)) {
                    if values[key] == nil { values[key] = title }
                }
                cursor = (cursor + bytes + 3) & ~3
                while cursor + 6 <= start + length {
                    guard let childLength = view.u16(cursor), childLength >= 8, cursor + childLength <= start + length else { break }
                    node(cursor, end: start + length, path: path + [key]); cursor = (cursor + childLength + 3) & ~3
                }
            }
            node(0, end: payload.count, path: [])
        }
        return values["ProductName"] ?? values["FileDescription"]
    }
}
