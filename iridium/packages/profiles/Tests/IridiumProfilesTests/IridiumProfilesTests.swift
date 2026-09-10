import XCTest
@testable import IridiumProfiles

final class IridiumProfilesTests: XCTestCase {
    func testGenericCompatibilityProfilesArePresent() {
        XCTAssertNotNil(BuiltInCompatibilityProfiles.compatibilityProfile(slug: "lightweight-default"))
        XCTAssertNotNil(BuiltInCompatibilityProfiles.compatibilityProfile(slug: "balanced-default"))
        XCTAssertNotNil(BuiltInCompatibilityProfiles.compatibilityProfile(slug: "performance-default"))
        XCTAssertNotNil(BuiltInCompatibilityProfiles.compatibilityProfile(slug: "heavy-whitelist"))
    }

    func testEveryGenericProfileMatchesAKnownDeviceTier() {
        XCTAssertEqual(BuiltInCompatibilityProfiles.all[0].minimumDeviceTier, .tier1)
        XCTAssertEqual(BuiltInCompatibilityProfiles.all[1].minimumDeviceTier, .tier1)
        XCTAssertEqual(BuiltInCompatibilityProfiles.all[2].minimumDeviceTier, .tier1)
        XCTAssertEqual(BuiltInCompatibilityProfiles.all[3].minimumDeviceTier, .tier1)
        XCTAssertNotNil(BuiltInCompatibilityProfiles.deviceProfile(id: "tier1-a17-mbase"))
        XCTAssertNotNil(BuiltInCompatibilityProfiles.deviceProfile(id: "tier2-a17max-mclass"))
        XCTAssertNotNil(BuiltInCompatibilityProfiles.deviceProfile(id: "tier3-mseries-whitelist"))
    }

    func testGenericTitleClassesPreferAppropriateProfiles() {
        XCTAssertEqual(
            BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(forTitle: "Lightweight Sample Game").slug,
            "lightweight-default"
        )
        XCTAssertEqual(
            BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(forTitle: "Balanced Sample Game").slug,
            "balanced-default"
        )
        XCTAssertEqual(
            BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(forTitle: "Performance Sample Game").slug,
            "performance-default"
        )
        XCTAssertEqual(
            BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(forTitle: "Heavy Sample Game").slug,
            "heavy-whitelist"
        )
    }

    func testLightweightProfileForcesUnityOpenGLPresentation() {
        let profile = BuiltInCompatibilityProfiles.compatibilityProfile(slug: "lightweight-default")
        XCTAssertEqual(
            profile?.launchArguments,
            ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
        )
    }

    func testRuntimePoliciesMatchGenericTitleBuckets() {
        let lightweight = BuiltInCompatibilityProfiles.runtimePolicy(forTitle: "Lightweight Sample Game", deviceTier: .tier1)
        let performance = BuiltInCompatibilityProfiles.runtimePolicy(forTitle: "Performance Sample Game", deviceTier: .tier2)
        let heavy = BuiltInCompatibilityProfiles.runtimePolicy(forTitle: "Heavy Sample Game", deviceTier: .tier3)

        XCTAssertEqual(lightweight.memoryBudgetClass, .compact)
        XCTAssertEqual(lightweight.framePacingCap, 60)
        XCTAssertEqual(lightweight.environmentOverrides["IRIDIUM_TITLE_CLASS"], "generic-lightweight")

        XCTAssertEqual(performance.rendererOverride, .dxvkPerformance)
        XCTAssertEqual(performance.framePacingCap, 60)
        XCTAssertEqual(performance.environmentOverrides["IRIDIUM_TITLE_CLASS"], "generic-performance")

        XCTAssertEqual(heavy.memoryBudgetClass, .expansive)
        XCTAssertEqual(heavy.framePacingCap, 60)
        XCTAssertTrue(heavy.requiresExplicitWhitelist)
        XCTAssertEqual(heavy.environmentOverrides["IRIDIUM_TITLE_CLASS"], "generic-heavy")
    }
}
