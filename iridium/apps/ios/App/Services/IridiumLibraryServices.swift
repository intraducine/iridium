// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor protocol IridiumWindowsLaunching {
    func launch(_ game: LibraryEntry)
    func launchSteam(_ game: DockGame, compactPool: Bool)
}
@MainActor protocol IridiumJITServicing {
    func enableForPlaying()
}
@MainActor protocol IridiumSteamServicing {
    func refreshInstalledGames()
    func connectAndReconcile()
    func reconcileIfEnabled()
}
@MainActor protocol IridiumControlEditing {
    func begin(owner: UUID, platform: IridiumPlatform, layout: IridiumControlLayoutState) throws
    func end(owner: UUID)
}
protocol IridiumSaveServicing: Sendable {
    func backup() throws -> SaveBackup.BackupResult
    func restore(from url: URL) throws -> Int
}

/// View dependencies; native runtime admission/lifecycle remains in its adapters.
@MainActor struct IridiumLibraryServices {
    let windows: any IridiumWindowsLaunching
    let jit: any IridiumJITServicing
    let steam: any IridiumSteamServicing
}
