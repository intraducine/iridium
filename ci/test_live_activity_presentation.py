"""Exercise the production Activity presentation without ActivityKit or a login."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

CHECKS = r'''
import Foundation
@main struct PresentationChecks {
    static func main() {
        func state(_ phase: String, _ stale: Bool, _ verified: Int64 = 25, _ total: Int64 = 100) -> SteamDownloadPresentation {
            .init(phase: phase, verifiedBytes: verified, totalBytes: total, isStale: stale)
        }
        for phase in ["completed", "cancelled", "failed"] {
            let fresh = state(phase, false), stale = state(phase, true)
            precondition(!stale.isStale && fresh.symbol == stale.symbol && fresh.tone == stale.tone)
        }
        for phase in ["resolving", "downloading", "verifying", "finalizing", "paused", "waitingForeground"] {
            let stale = state(phase, true)
            precondition(stale.isStale && stale.tone == .attention && stale.symbol == "clock.badge.exclamationmark")
        }
        precondition(state("paused", false).symbol == "pause.circle")
        precondition(state("failed", false).tone == .failure)
        precondition(state("completed", false).tone == .success)
        precondition(state("downloading", false).fractionCompleted == 0.25)
        precondition(state("downloading", false, 200).fractionCompleted == 1)
        precondition(state("downloading", false, -1).fractionCompleted == 0)
        precondition(state("resolving", false, 0, 0).fractionCompleted == nil)
        precondition(state("resolving", false, 25, -1).fractionCompleted == nil)
        precondition(state("resolving", false, 25, 0).verifiedSummary.contains("total unknown"))
        precondition(state("downloading", false).verifiedSummary.hasPrefix("Verified "))
        func rate(_ phase: String, _ stale: Bool, _ value: Double?) -> SteamDownloadPresentation {
            .init(phase: phase, verifiedBytes: 25, totalBytes: 100, isStale: stale, receivedBytesPerSecond: value)
        }
        precondition(rate("downloading", false, 12_000_000).receivedRateSummary != nil)
        let invalidRates: [Double?] = [nil, 0, -1, Double.infinity, Double.nan, Double(Int64.max)]
        for value in invalidRates {
            precondition(rate("downloading", false, value).receivedRateSummary == nil)
        }
        precondition(rate("downloading", true, 12_000_000).receivedRateSummary == nil)
        for phase in ["resolving", "verifying", "finalizing", "paused", "waitingForeground", "completed", "failed", "cancelled"] {
            precondition(rate(phase, false, 12_000_000).receivedRateSummary == nil)
        }
        precondition(rate("downloading", false, nil).verifiedAmount == state("downloading", false).verifiedAmount)
        print("Production Live Activity presentation checks passed")
    }
}
'''


ACTIVITY_HOST = r'''
import Foundation
protocol ActivityAttributes: Codable { associatedtype ContentState: Codable, Hashable }
// Platform artwork rendering is outside this serialization/flush fixture.
struct Image {
    func resizable() -> Self { self }
    func scaledToFill() -> Self { self }
    func frame(width: Double, height: Double) -> Self { self }
    func clipped() -> Self { self }
}
struct UIImage {
    func jpegData(compressionQuality: Double) -> Data? { nil }
}
@MainActor final class ImageRenderer {
    var scale: Double = 1
    var uiImage: UIImage? { nil }
    init(content: Image) {}
}
struct ActivityContent<State> { let state: State; let staleDate: Date }
enum ActivityUIDismissalPolicy { case immediate, after(Date) }
struct ActivityAuthorizationInfo { var areActivitiesEnabled: Bool { true } }
@MainActor enum ActivityFixture {
    static var hold = true
    static var continuation: CheckedContinuation<Void, Never>?
    static var verified: [Int64] = []
}
@MainActor final class Activity<Attributes: ActivityAttributes> {
    let attributes: Attributes
    init(attributes: Attributes) { self.attributes = attributes }
    static var activities: [Activity<Attributes>] { [] }
    static func request(attributes: Attributes, content: ActivityContent<Attributes.ContentState>,
                        pushType: String?) throws -> Activity<Attributes> { .init(attributes: attributes) }
    func update(_ content: ActivityContent<Attributes.ContentState>) async {
        if ActivityFixture.hold { await withCheckedContinuation { ActivityFixture.continuation = $0 } }
        let state = content.state as! SteamDownloadActivityAttributes.ContentState
        ActivityFixture.verified.append(state.verifiedBytes)
    }
    func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {}
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
enum LiveContainerIntegration { static func isHosted() -> Bool { false } }
'''

ACTIVITY_CHECKS = r'''
@MainActor @main struct ActivityChecks {
    static func main() async {
        let activity = SteamDownloadActivity()
        var job = SteamDownloadJob(game: SteamOwnedGame(appId: 42, name: "Fixture"),
            account: "synthetic-account", options: SteamInstallOptions())
        activity.begin(job)
        UIApplication.shared.applicationState = .background
        job.completedBytes = 25
        activity.update(job, force: true)
        for _ in 0..<10000 {
            if ActivityFixture.continuation != nil { break }
            await Task.yield()
        }
        precondition(ActivityFixture.continuation != nil)
        job.completedBytes = 75
        activity.update(job, force: true)
        var flushed = false
        let draining = Task { await activity.flush(); flushed = true }
        await Task.yield()
        precondition(!flushed && ActivityFixture.verified.isEmpty)
        ActivityFixture.hold = false
        ActivityFixture.continuation?.resume()
        ActivityFixture.continuation = nil
        await draining.value
        precondition(flushed && ActivityFixture.verified == [25, 75])
        print("PASS: production Activity flush waits for serialized background updates")
    }
}
'''


class LiveActivityPresentationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_production_activity_flush(self):
        source = (ROOT / 'iridium/apps/ios/Iridium/SteamDownloadActivity.swift').read_text()
        for name in ('ActivityKit', 'UIKit', 'SwiftUI'):
            source = source.replace('import ' + name + '\n', '')
        # Execute the real payload construction/bounding with host platform I/O.
        attributes = (ROOT / 'iridium/apps/ios/SteamActivityShared/SteamDownloadActivityAttributes.swift').read_text()
        attributes = attributes[:attributes.index('struct CancelSteamDownloadIntent:')]
        for name in ('ActivityKit', 'AppIntents'):
            attributes = attributes.replace('import ' + name + '\n', '')
        with tempfile.TemporaryDirectory(prefix='iridium-activity-flush-') as temporary:
            directory = Path(temporary)
            host = directory / 'ActivityChecks.swift'
            host.write_text(ACTIVITY_HOST + attributes + source + ACTIVITY_CHECKS)
            executable = directory / 'activity-checks'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                           '-module-cache-path', str(directory / 'module-cache'),
                           str(ROOT / 'iridium/apps/ios/Iridium/SteamDownloadQueue.swift'),
                           str(host), '-o', str(executable)], check=True, timeout=180)
            subprocess.run([str(executable)], check=True, timeout=60)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_production_presentation(self):
        with tempfile.TemporaryDirectory(prefix='iridium-activity-checks-') as temporary:
            directory = Path(temporary)
            host = directory / 'PresentationChecks.swift'
            host.write_text(CHECKS)
            executable = directory / 'presentation-checks'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                           '-module-cache-path', str(directory / 'module-cache'),
                           str(ROOT / 'iridium/apps/ios/SteamDownloadWidget/SteamDownloadPresentation.swift'),
                           str(host), '-o', str(executable)], check=True, timeout=180)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
