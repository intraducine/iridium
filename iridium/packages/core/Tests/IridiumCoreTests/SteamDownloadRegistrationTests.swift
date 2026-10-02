import Foundation
import IridiumCore
import XCTest

final class SteamDownloadRegistrationTests: XCTestCase {
    private func register(_ store: IridiumStore, appID: String = "42", path: String = "/fixture/v1", fingerprint: String = "first") async -> GameRecord {
        await store.registerSteamGame(title: "Same Display Name", appID: appID, installPath: path,
            executablePath: path + "/game.exe", compatibilityProfileName: "default-profile",
            inputProfileName: "default-input", deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
            launchArguments: [], titleFlags: ["steam-native-download"],
            managedArtifactIdentifier: fingerprint, executableFingerprint: fingerprint)
    }

    func testRepairPreservesUserSettingsAndPrefix() async throws {
        let store = IridiumStore(snapshot: .empty)
        var old = await register(store)
        old.title = "My Custom Title"
        old.savePathMapping = "/custom/saves"
        old.compatibilityProfileName = "user-profile"
        old.inputProfileName = "user-input"
        old.touchOverlayName = "my-overlay"
        old.controllerPresetName = "my-controller"
        old.keyboardMouseEnabled = false
        old.deviceTier = .tier2
        old.rendererPreset = .dxvkPerformance
        old.launchProfile.arguments = ["--custom"]
        old.launchProfile.titleFlags.append("user-flag")
        await store.update(old)
        let originalPrefix = await store.prefix(prefixID: old.launchProfile.prefixID)
        var prefix = try XCTUnwrap(originalPrefix)
        prefix.state = .customized
        prefix.environmentOverrides = ["CUSTOM_OPTION": "enabled"]
        await store.updatePrefix(prefix)
        let updated = await register(store, path: "/fixture/v2", fingerprint: "second")
        XCTAssertEqual(updated.id, old.id)
        XCTAssertEqual(updated.title, old.title)
        XCTAssertEqual(updated.installPath, "/fixture/v2")
        XCTAssertEqual(updated.launchProfile.executablePath, "/fixture/v2/game.exe")
        XCTAssertEqual(updated.launchProfile.prefixID, old.launchProfile.prefixID)
        XCTAssertEqual(updated.savePathMapping, old.savePathMapping)
        XCTAssertEqual(updated.compatibilityProfileName, old.compatibilityProfileName)
        XCTAssertEqual(updated.inputProfileName, old.inputProfileName)
        XCTAssertEqual(updated.touchOverlayName, old.touchOverlayName)
        XCTAssertEqual(updated.controllerPresetName, old.controllerPresetName)
        XCTAssertEqual(updated.keyboardMouseEnabled, old.keyboardMouseEnabled)
        XCTAssertEqual(updated.deviceTier, old.deviceTier)
        XCTAssertEqual(updated.rendererPreset, old.rendererPreset)
        XCTAssertEqual(updated.launchProfile.arguments, old.launchProfile.arguments)
        XCTAssertEqual(updated.launchProfile.titleFlags, old.launchProfile.titleFlags)
        XCTAssertEqual(updated.prefixState, .customized)
        XCTAssertEqual(updated.executableFingerprint, "second")
        XCTAssertNil(updated.installedSizeGB)
        let resolvedPrefix = await store.prefix(prefixID: old.launchProfile.prefixID)
        let newPrefix = try XCTUnwrap(resolvedPrefix)
        XCTAssertEqual(newPrefix.environmentOverrides, prefix.environmentOverrides)
        XCTAssertEqual(newPrefix.state, prefix.state)
        XCTAssertEqual(newPrefix.titleFingerprint, "second")
        let games = await store.allGames()
        XCTAssertEqual(games.count, 1)
    }

    func testDifferentAppIDsWithSameTitleRemainSeparate() async {
        let store = IridiumStore(snapshot: .empty)
        let first = await register(store)
        let second = await register(store, appID: "43", path: "/fixture/other")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.launchProfile.prefixID, second.launchProfile.prefixID)
        let games = await store.allGames()
        XCTAssertEqual(games.count, 2)
    }
}
