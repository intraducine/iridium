import BackgroundTasks
import UIKit

@MainActor
final class SteamDownloadRuntime {
    static let shared = SteamDownloadRuntime()
    private var currentTask: AnyObject?
    private var operation: UUID?
    private var registered = false
    private var submitted = false
    private var stop: (() -> Void)?
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "software.iridium") + ".steam-download" }

    var hasContinuedRuntime: Bool { currentTask != nil }

    func begin(operation: UUID, name: String, userInitiated: Bool, stop: @escaping () -> Void) {
        guard userInitiated, !LiveContainerIntegration.isHosted(), UIApplication.shared.applicationState == .active,
              #available(iOS 26.0, *) else { return }
        self.operation = operation
        self.stop = stop
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor [weak self] in
                    guard let self, self.submitted, self.operation != nil else { task.setTaskCompleted(success: false); return }
                    self.currentTask = task
                    task.progress.totalUnitCount = 1
                    task.progress.completedUnitCount = 0
                    task.expirationHandler = { [weak self] in
                        Task { @MainActor in self?.expire() }
                    }
                }
            }
        }
        guard registered else { self.operation = nil; self.stop = nil; return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: "Download \(String(name.prefix(80)))", subtitle: "Preparing game files")
        request.strategy = .fail // No delayed automatic launch of a stale intent.
        submitted = true
        do { try BGTaskScheduler.shared.submit(request) }
        catch { submitted = false; self.operation = nil; self.stop = nil }
    }

    func progress(operation: UUID, completed: Int64, total: Int64, phase: String) {
        guard self.operation == operation, #available(iOS 26.0, *),
              let task = currentTask as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = max(1, total)
        task.progress.completedUnitCount = min(max(0, completed), max(1, total))
        task.updateTitle("Downloading game", subtitle: phase == "verifying" ? "Verifying game files" : "Downloading game files")
    }

    func finish(operation: UUID, success: Bool) {
        guard self.operation == operation else { return }
        if #available(iOS 26.0, *), let task = currentTask as? BGContinuedProcessingTask { task.setTaskCompleted(success: success) }
        if submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        currentTask = nil
        self.operation = nil
        submitted = false
        stop = nil
    }

    private func expire() {
        let cancellation = stop
        if let operation { finish(operation: operation, success: false) }
        cancellation?() // Persist/resumable pause and stop HTTP + native work.
    }
}
