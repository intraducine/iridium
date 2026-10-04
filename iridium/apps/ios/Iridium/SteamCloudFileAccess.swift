import Foundation

// Acquire on MainActor before scheduling or awaiting any file work. A global
// lease also covers library entries whose source folders overlap another game.
@MainActor
final class SteamCloudFileAccess {
    static let shared = SteamCloudFileAccess()
    enum Operation: CaseIterable {
        case cloud, refresh, installer, deleteImportedFiles, deleteSteamFiles
        case removeLibraryEntry, relocate, register, repairPrefix, rebuildPrefix, clonePrefix
        case editLaunchArguments
    }
    struct Lease: Equatable {
        fileprivate let id: UUID
        let operation: Operation
    }
    private var active: Lease?
    var busy: Bool { active != nil }
    var cloudOwned: Bool { active?.operation == .cloud }
    var mutating: Bool { active != nil && !cloudOwned }
    func isHeld(by operation: Operation) -> Bool { active?.operation == operation }

    func begin(_ operation: Operation) -> Lease? {
        guard active == nil else { return nil }
        let lease = Lease(id: UUID(), operation: operation)
        active = lease
        return lease
    }
    func owns(_ lease: Lease, operation: Operation) -> Bool {
        active == lease && lease.operation == operation
    }
    func finish(_ lease: Lease) {
        guard active == lease else { return }
        active = nil
        SteamLibraryModel.shared.resumeQueueAfterFileOperation()
    }
}
