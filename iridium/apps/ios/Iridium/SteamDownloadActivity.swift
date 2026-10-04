import ActivityKit
import UIKit

@MainActor
final class SteamDownloadActivity {
    static let shared = SteamDownloadActivity()
    private var activity: Activity<SteamDownloadActivityAttributes>?
    private var pending: Task<Void, Never>?
    private var lastUpdate = Date.distantPast

    func recoverAfterRelaunch() async {
        await pending?.value
        for previous in Activity<SteamDownloadActivityAttributes>.activities {
            await previous.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    func begin(_ job: SteamDownloadJob) {
        guard !LiveContainerIntegration.isHosted(), UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = SteamDownloadActivityAttributes(operationId: job.id.uuidString, gameName: String(job.name.prefix(80)))
        let content = makeContent(job, phase: "resolving")
        do { activity = try Activity.request(attributes: attributes, content: content, pushType: nil) }
        catch { activity = nil } // Download remains usable if local ActivityKit is disabled/unavailable.
        lastUpdate = Date()
    }

    func update(_ job: SteamDownloadJob, phase: String? = nil, force: Bool = false) {
        guard let activity, activity.attributes.operationId == job.id.uuidString,
              force || Date().timeIntervalSince(lastUpdate) >= 5 else { return }
        lastUpdate = Date()
        let content = makeContent(job, phase: phase ?? job.phase)
        let previous = pending
        pending = Task { await previous?.value; await activity.update(content) }
    }

    func end(_ job: SteamDownloadJob) {
        guard let activity, activity.attributes.operationId == job.id.uuidString else { return }
        let content = makeContent(job, phase: job.status.rawValue)
        let previous = pending
        pending = Task {
            await previous?.value
            await activity.end(content, dismissalPolicy: job.status == .cancelled ? .immediate : .after(Date().addingTimeInterval(60)))
        }
        self.activity = nil
    }

    private func makeContent(_ job: SteamDownloadJob, phase: String) -> ActivityContent<SteamDownloadActivityAttributes.ContentState> {
        let state = SteamDownloadActivityAttributes.ContentState(phase: phase, verifiedBytes: max(0, job.completedBytes),
            totalBytes: max(0, job.totalBytes), lastUpdated: Date())
        return ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
    }
}
