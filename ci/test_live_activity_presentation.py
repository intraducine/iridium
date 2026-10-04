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
        print("Production Live Activity presentation checks passed")
    }
}
'''


class LiveActivityPresentationTests(unittest.TestCase):
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
