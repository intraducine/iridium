// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md). Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String) -> Bool {
        library.caseInsensitiveCompare(libraryRelative) == .orderedSame
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    /// The language the install record states (`UserConfig.language`), or nil.
    static func language(appID: Int, steamApps: URL) -> String? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let language = state["UserConfig"]?["language"]?.string, !language.isEmpty else { return nil }
        return language.lowercased()
    }

    /// The depots the install record holds: its own (`InstalledDepots`) and
    /// those shared from other apps (`SharedDepots`).
    static func depots(appID: Int, steamApps: URL) -> Set<Int> {
        guard let state = record(appID: appID, steamApps: steamApps) else { return [] }
        let keys = Array((state["InstalledDepots"]?.fields ?? [:]).keys) + Array((state["SharedDepots"]?.fields ?? [:]).keys)
        return Set(keys.prefix(512).compactMap { Int($0) })
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Removal accepts direct common children
    /// and journaled aliases to managed game folders.
    @discardableResult
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) -> Bool {
        guard appID > 0, UInt64(appID) < UInt64(UInt32.max), folderName == safeFolderName(folderName) else { return false }
        let fm = FileManager.default
        func remove(_ url: URL) throws {
            if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        }
        do {
            let state = record(appID: appID, steamApps: steamApps)
            if let recordedFolder = state?["installdir"]?.string, recordedFolder.caseInsensitiveCompare(folderName) != .orderedSame { return false }
            let held = Set((state?["InstalledDepots"]?.fields ?? [:]).keys)
            let owners = Set((state?["SharedDepots"]?.fields ?? [:]).values.compactMap { $0.string })
            let names = (try? fm.contentsOfDirectory(atPath: steamApps.path)) ?? []
            guard names.count <= 100_000 else { return false }
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let id = Int(name.dropFirst(12).dropLast(4)), id != appID,
                      let other = record(appID: id, steamApps: steamApps) else { continue }
                let lent = Set((other["SharedDepots"]?.fields ?? [:]).filter { $0.value.string == String(appID) }.keys)
                // A shared-only record belongs to the consuming game, not a separate install.
                if !lent.isEmpty && held.isSubset(of: lent) { return false }
                if other["installdir"]?.string?.caseInsensitiveCompare(folderName) == .orderedSame {
                    let shared = Set((state?["SharedDepots"]?.fields ?? [:]).filter { $0.value.string == String(id) }.keys)
                    let owned = Set((other["InstalledDepots"]?.fields ?? [:]).keys)
                    guard owners.contains(String(id)), owned.isSubset(of: shared) else { return false }
                }
            }
            let common = steamApps.appendingPathComponent("common", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let link = common.appendingPathComponent(folderName)
            let folder = link.resolvingSymlinksInPath().standardizedFileURL
            let drive = steamApps.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if let managed = IridiumGameStorage.movedWindowsFolder(link, drive: drive) {
                try remove(managed); try remove(link)
            } else {
                guard folder.deletingLastPathComponent().path == common.path else { return false }
                try remove(link)
            }
            if let state {
                let shared = (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64)
                for (_, owner) in shared {
                    guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID,
                          let ownerState = record(appID: ownerID, steamApps: steamApps) else { continue }
                    let mine = Set(shared.filter { $0.value.string == owner.string }.map { $0.key })
                    let owned = Set((ownerState["InstalledDepots"]?.fields ?? [:]).keys)
                    guard owned.isSubset(of: mine) else { continue }
                    try remove(steamApps.appendingPathComponent("appmanifest_\(ownerID).acf"))
                }
            }
            try remove(steamApps.appendingPathComponent("appmanifest_\(appID).acf"))
            try remove(steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
            return true
        } catch { return false }
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    private static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}
