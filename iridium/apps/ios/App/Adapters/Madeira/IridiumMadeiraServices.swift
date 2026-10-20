// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Calls the retained Windows coordinator; it owns JIT continuation, runtime
/// leases, cloud preflight, launch worker and graceful shutdown.
@MainActor struct IridiumMadeiraLaunchAdapter: IridiumWindowsLaunching {
    let start: (LibraryEntry) -> Void
    let startDock: (DockGame, Bool) -> Void
    func launch(_ game: LibraryEntry) { start(game) }
    func launchSteam(_ game: DockGame, compactPool: Bool) { startDock(game, compactPool) }
}

@MainActor struct IridiumMadeiraJITAdapter: IridiumJITServicing {
    let enable: () -> Void
    func enableForPlaying() { enable() }
}

@MainActor struct IridiumMadeiraSteamAdapter: IridiumSteamServicing {
    func refreshInstalledGames() { SteamGamesModel.shared.refresh() }
    func connectAndReconcile() {
        guard SteamOwnedLibrary.enabled else { return }
        SteamOwnedLibrary.shared.start()
        SteamOwnedLibrary.shared.reconcileSession()
    }
    func reconcileIfEnabled() {
        if SteamOwnedLibrary.enabled { SteamOwnedLibrary.shared.reconcileSession() }
    }
}

/// Admission includes native Windows processes, not only frontend session state.
/// The editing owner token and restoration snapshot stay in TouchControlsModel.
@MainActor struct IridiumMadeiraControlAdapter: IridiumControlEditing {
    func begin(owner: UUID, platform: IridiumPlatform, layout: IridiumControlLayoutState) throws {
        let admission = LibraryModel.shared.current == nil && !LibraryModel.shared.launching &&
            !IridiumConsoleSession.shared.isActive && !JITCoordinator.shared.busy &&
            wine_process_is_running() == 0 && wineserver_is_running() == 0
        try TouchControlsModel.shared.iridiumBeginSettings(owner: owner, platform: platform, state: layout, admission: admission)
    }
    func end(owner: UUID) { TouchControlsModel.shared.iridiumEndSettings(owner: owner) }
}

struct IridiumMadeiraSaveAdapter: IridiumSaveServicing {
    func backup() throws -> SaveBackup.BackupResult { try SaveBackup.backup() }
    func restore(from url: URL) throws -> Int { try SaveBackup.restore(from: url) }
}
