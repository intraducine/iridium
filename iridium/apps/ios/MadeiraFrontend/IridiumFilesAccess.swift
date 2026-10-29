// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumFilesAccess {
    static func read<Value>(_ urls: [URL], operation: ([URL]) throws -> Value) throws -> Value {
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        let coordinator = NSFileCoordinator()
        func coordinate(_ index: Int, _ resolved: [URL]) throws -> Value {
            if index == urls.count { return try operation(resolved) }
            var error: NSError?, result: Result<Value, Error>?
            coordinator.coordinate(readingItemAt: urls[index], options: [], error: &error) { updated in
                result = Result { try Task.checkCancellation(); return try coordinate(index + 1, resolved + [updated]) }
            }
            if let result { return try result.get() }
            if let error { throw error }
            throw IridiumFilesImport.Failure.sourceChanged
        }
        coordinator.prepare(forReadingItemsAt: urls, options: [], writingItemsAt: [], options: [], error: &coordinationError) { completed in
            defer { completed() }
            result = Result { try Task.checkCancellation(); return try coordinate(0, []) }
        }
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw IridiumFilesImport.Failure.sourceChanged
    }
    static func readGame<Value>(_ source: URL, selectedFiles: [URL], operation: (URL, [URL]) throws -> Value) throws -> Value {
        let scopes = selectedFiles.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        let names = try read([source]) { urls in
            ["gdi", "cue"].contains(source.pathExtension.lowercased())
                ? try IridiumDiscSet(urls[0], selectedFiles: selectedFiles, validateFiles: false).filenames : []
        }
        let inputs = [source] + names.map { source.deletingLastPathComponent().appendingPathComponent($0) }
        return try read(inputs) { urls in
            for (index, name) in names.enumerated() {
                guard urls[index + 1].standardizedFileURL == urls[0].deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
                else { throw IridiumFilesImport.Failure.sourceChanged }
            }
            return try operation(urls[0], urls)
        }
    }
    static func read<Value>(_ url: URL, operation: (URL) throws -> Value) throws -> Value {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Task.checkCancellation(); return try operation(source) }
        }
        // An accessor that completed publication owns a real result. Do not
        // replace it with a late coordination error and lose the saved copy.
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw IridiumFilesImport.Failure.sourceChanged
    }
}
