import ActivityKit
import UIKit
import SwiftUI

@MainActor
final class SteamDownloadActivity {
    static let shared = SteamDownloadActivity()
    private var activity: Activity<SteamDownloadActivityAttributes>?
    private var pending: Task<Void, Never>?
    private var lastUpdate = Date.distantPast
    private let artwork = NSCache<NSNumber, NSData>()

    // Reuse the cover already decoded by the app's AsyncImage. No additional
    // request, shared-container entitlement or app Documents URL is involved.
    func cacheArtwork(_ image: Image, for appId: UInt32) {
        let key = NSNumber(value: appId)
        guard artwork.object(forKey: key) == nil else { return }
        let renderer = ImageRenderer(content: image.resizable().scaledToFill().frame(width: 80, height: 40).clipped())
        renderer.scale = 1
        guard let thumbnail = renderer.uiImage,
              let jpeg = thumbnail.jpegData(compressionQuality: 0.25), jpeg.count <= 1_450 else { return }
        artwork.countLimit = 24
        artwork.setObject(jpeg as NSData, forKey: key)
        // A late image must not mark an old progress/rate sample as fresh.
        // The next normally sampled update will pick up the cached thumbnail.
    }

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
        let content = makeContent(job, attributes: attributes, phase: "resolving")
        do { activity = try Activity.request(attributes: attributes, content: content, pushType: nil) }
        catch { activity = nil } // Download remains usable if local ActivityKit is disabled/unavailable.
        lastUpdate = Date()
    }

    func update(_ job: SteamDownloadJob, phase: String? = nil, force: Bool = false, receivedBytesPerSecond: Double? = nil) {
        guard let activity, activity.attributes.operationId == job.id.uuidString,
              force || Date().timeIntervalSince(lastUpdate) >= 5 else { return }
        lastUpdate = Date()
        let content = makeContent(job, attributes: activity.attributes, phase: phase ?? job.phase,
            receivedBytesPerSecond: receivedBytesPerSecond)
        let previous = pending
        pending = Task { await previous?.value; await activity.update(content) }
    }

    // Finish the queued local update before relinquishing a URLSession wake.
    func flush() async { await pending?.value }

    func end(_ job: SteamDownloadJob) {
        guard let activity, activity.attributes.operationId == job.id.uuidString else { return }
        let content = makeContent(job, attributes: activity.attributes, phase: job.status.rawValue)
        let previous = pending
        pending = Task {
            await previous?.value
            await activity.end(content, dismissalPolicy: job.status == .cancelled ? .immediate : .after(Date().addingTimeInterval(60)))
        }
        self.activity = nil
    }

    private func makeContent(_ job: SteamDownloadJob, attributes: SteamDownloadActivityAttributes, phase: String,
                             receivedBytesPerSecond: Double? = nil) -> ActivityContent<SteamDownloadActivityAttributes.ContentState> {
        let state = SteamDownloadActivityAttributes.ContentState(phase: phase, verifiedBytes: max(0, job.completedBytes),
            totalBytes: max(0, job.totalBytes), lastUpdated: Date(), receivedBytesPerSecond: receivedBytesPerSecond,
            artworkJPEG: artwork.object(forKey: NSNumber(value: job.appId)) as Data?)
        return ActivityContent(state: state.bounded(for: attributes), staleDate: Date().addingTimeInterval(30))
    }
}
