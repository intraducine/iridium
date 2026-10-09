// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Read-only presentation precedence. Existing Madeira covers and imported
/// Iridium backgrounds remain user choices without migrating their records.
enum IridiumArtworkSourcePolicy {
    enum Source: Equatable, Sendable {
        case shared(String)
        case legacyCover(String)
        case legacyBackground(String)
        case steam(Int)
    }

    static func sources(_ item: IridiumArtworkAppearance, legacyCover: String?, legacyBackground: String?,
                        steamID: Int?, backdrop: Bool) -> [Source] {
        if backdrop, item.customBackground { return item.background.map { [.shared($0)] } ?? [] }
        if !backdrop, item.customCover { return item.cover.map { [.shared($0)] } ?? [] }
        var result: [Source] = []
        if backdrop {
            if item.ignoreLegacyBackground != true {
                if let legacyBackground { result.append(.legacyBackground(legacyBackground)) }
                // A deliberately replaced or removed cover no longer supplies
                // an inherited background; its prior file still stays on disk.
                if !item.customCover, item.ignoreLegacyCover != true, let legacyCover {
                    result.append(.legacyCover(legacyCover))
                }
            }
            if let background = item.background { result.append(.shared(background)) }
            if let cover = item.cover { result.append(.shared(cover)) }
        } else {
            if item.ignoreLegacyCover != true, let legacyCover { result.append(.legacyCover(legacyCover)) }
            if let cover = item.cover { result.append(.shared(cover)) }
        }
        if item.automaticLookup, let steamID { result.append(.steam(steamID)) }
        return result
    }

    static func needsAutomaticCover(_ item: IridiumArtworkAppearance, legacyCover: String?) -> Bool {
        !item.customCover && (item.ignoreLegacyCover == true || legacyCover == nil)
    }
    static func needsAutomaticBackground(_ item: IridiumArtworkAppearance, legacyCover: String?, legacyBackground: String?) -> Bool {
        !item.customBackground && (item.ignoreLegacyBackground == true ||
            (legacyBackground == nil && (legacyCover == nil || item.customCover || item.ignoreLegacyCover == true)))
    }
}

/// The editor alone owns Back while its page is active. Native pickers keep
/// their modality, then text editing ends before navigation can leave the page.
enum IridiumArtworkBackPolicy {
    enum Action: Equatable { case ignore, endEditing, leaveEditor }
    @MainActor static func leaveAfterCurrentDelivery(_ leave: @escaping @MainActor () -> Void) {
        // Combine's synchronous subscriber order is unspecified. The parent
        // must see this page as active for the entire current command delivery.
        DispatchQueue.main.async { leave() }
    }
    static func action(pickerPresented: Bool, fieldFocused: Bool) -> Action {
        if pickerPresented { return .ignore }
        return fieldFocused ? .endEditing : .leaveEditor
    }
}

/// Try only this candidate's known asset URLs, in their declared order. A
/// missing capsule can fall back to its own header without changing game match.
@MainActor enum IridiumArtworkFallback {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "No artwork is available for this match." }
    }
    static func firstAvailable<Value>(_ urls: [URL], load: (URL) async throws -> Value) async throws -> Value {
        var seen = Set<URL>()
        let candidates = Array(urls.filter { seen.insert($0).inserted }.prefix(5))
        var failure: Error = Failure.unavailable
        for url in candidates {
            try Task.checkCancellation()
            do {
                let result = try await load(url)
                try Task.checkCancellation()
                return result
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failure = error
            }
        }
        throw failure
    }
}
