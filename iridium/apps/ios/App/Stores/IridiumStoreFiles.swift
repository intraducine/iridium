// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Store paths can use only their install root, a journaled Games alias, or a registered drive.
enum IridiumStoreFiles {
    static func url(folder: String, installRoot: String) throws -> URL {
        let parts = try ExternalStoragePath.components(folder)
        if parts.first == "External" { return try ExternalDrives.nativeURL(folder, write: true) }
        guard folder.hasPrefix(installRoot + "/"), parts.count > installRoot.split(separator: "/").count else {
            throw ExternalStorageError.unsafePath
        }
        let drive = LibraryModel.drive, link = drive.appendingPathComponent(folder)
        if let target = IridiumGameStorage.movedWindowsFolder(link, drive: drive) { return target }
        return try ExternalStoragePath.native(folder, root: drive)
    }

    /// Only a missing whole install counts as a Files uninstall. Partial damage stays repairable.
    static func isDeleted(folder: String, installRoot: String) -> Bool {
        guard let target = try? url(folder: folder, installRoot: installRoot),
              !folder.hasPrefix("External/") else { return false }
        do { _ = try FileManager.default.attributesOfItem(atPath: target.path); return false }
        catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
    }

    static func settingsFile(_ relative: String) throws -> URL {
        let parts = try ExternalStoragePath.components(relative)
        guard parts.last?.lowercased().hasSuffix(".ini") == true else { throw ExternalStorageError.unsafePath }
        if parts.first == "External" { return try ExternalDrives.nativeURL(relative, write: true) }
        let drive = LibraryModel.drive.resolvingSymlinksInPath().standardizedFileURL
        var url = drive
        // Resolve each existing parent. Darwin can leave links unresolved for a missing leaf.
        for part in parts {
            url.appendPathComponent(part)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved != url, IridiumGameStorage.windowsRelative(resolved, drive: drive) != nil else { throw ExternalStorageError.unsafePath }
                    url = resolved
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
        }
        return url
    }

    static func remove(folder: String, installRoot: String, metadata: [URL]) throws {
        let fm = FileManager.default
        let target = try url(folder: folder, installRoot: installRoot)
        let link = LibraryModel.drive.appendingPathComponent(folder)
        let managedAlias = IridiumGameStorage.movedWindowsFolder(link, drive: LibraryModel.drive) != nil
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        if target != link, managedAlias {
            try fm.removeItem(at: link)
        }
        for file in metadata where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }
}
