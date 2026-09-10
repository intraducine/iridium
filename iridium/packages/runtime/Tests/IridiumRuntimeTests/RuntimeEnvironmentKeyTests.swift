import XCTest

@testable import IridiumRuntime

final class RuntimeEnvironmentKeyTests: XCTestCase {
    func testSharedRuntimeEnvironmentKeysRemainStable() {
        XCTAssertEqual(RuntimeEnvironmentKey.noDesktop, "IRIDIUM_NO_DESKTOP")
        XCTAssertEqual(RuntimeEnvironmentKey.hostJITStatus, "IRIDIUM_HOST_JIT_STATUS")
        XCTAssertEqual(RuntimeEnvironmentKey.runtimeBundleRoot, "IRIDIUM_RUNTIME_BUNDLE_ROOT")
        XCTAssertEqual(RuntimeEnvironmentKey.runtimeBundleID, "IRIDIUM_RUNTIME_BUNDLE_ID")
        XCTAssertEqual(RuntimeEnvironmentKey.runtimeBundleVersion, "IRIDIUM_RUNTIME_BUNDLE_VERSION")
        XCTAssertEqual(RuntimeEnvironmentKey.runtimeGraphicsStack, "IRIDIUM_RUNTIME_GRAPHICS_STACK")
        XCTAssertEqual(RuntimeEnvironmentKey.userlandRoot, "IRIDIUM_USERLAND_ROOT")
        XCTAssertEqual(RuntimeEnvironmentKey.wineDataDirectory, "WINEDATADIR")
        XCTAssertEqual(RuntimeEnvironmentKey.wineIOSGraphicsDriver, "IRIDIUM_WINE_IOS_GRAPHICS_DRIVER")
        XCTAssertEqual(RuntimeEnvironmentKey.wineIOSAudioDriver, "IRIDIUM_WINE_IOS_AUDIO_DRIVER")
    }
}
