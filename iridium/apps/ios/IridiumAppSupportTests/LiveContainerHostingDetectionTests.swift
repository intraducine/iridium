import Foundation
import XCTest
@testable import IridiumAppSupport

@MainActor
final class LiveContainerHostingDetectionTests: XCTestCase {
    func testLegacyGuestBundlePathIsHosted() {
        let bundleURL = URL(fileURLWithPath:
            "/var/mobile/Containers/Data/Application/HOST/Documents/Applications/software.iridium.app")

        XCTAssertTrue(
            LiveContainerIntegration.isHosted(
                bundleURL: bundleURL,
                documentDirectoryURL: nil,
                liveContainerHomePath: nil
            )
        )
    }

    func testSharedAppGroupGuestDataPathIsHosted() {
        let bundleURL = URL(fileURLWithPath:
            "/var/containers/Bundle/Application/HOST/LiveContainer.app")
        let documentsURL = URL(fileURLWithPath:
            "/var/mobile/Containers/Shared/AppGroup/GROUP/LiveContainer/Data/Application/GUEST/Documents")

        XCTAssertTrue(
            LiveContainerIntegration.isHosted(
                bundleURL: bundleURL,
                documentDirectoryURL: documentsURL,
                liveContainerHomePath: nil
            )
        )
    }

    func testLiveContainerHomePathIsHosted() {
        let bundleURL = URL(fileURLWithPath:
            "/var/containers/Bundle/Application/HOST/LiveContainer.app")

        XCTAssertTrue(
            LiveContainerIntegration.isHosted(
                bundleURL: bundleURL,
                documentDirectoryURL: nil,
                liveContainerHomePath: "/var/mobile/Containers/Shared/AppGroup/GROUP/LiveContainer"
            )
        )
    }

    func testStandalonePathsAreNotHosted() {
        let bundleURL = URL(fileURLWithPath:
            "/var/containers/Bundle/Application/APP/software.iridium.app")
        let documentsURL = URL(fileURLWithPath:
            "/var/mobile/Containers/Data/Application/APP/Documents")

        XCTAssertFalse(
            LiveContainerIntegration.isHosted(
                bundleURL: bundleURL,
                documentDirectoryURL: documentsURL,
                liveContainerHomePath: nil
            )
        )
    }
}
