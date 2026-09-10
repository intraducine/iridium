import Foundation
import IridiumCore
import IridiumRuntime
import XCTest

#if canImport(JavaScriptCore)
    import JavaScriptCore
#endif

@testable import IridiumAppSupport

@MainActor
final class IridiumAppSupportTests: XCTestCase {
    func testLiveContainerSetupFeedbackRequiresReadbackAndRelaunch() {
        func status(hosted: Bool = true, present: Bool = true, configured: Bool) -> LiveContainerIntegrationStatus {
            .init(isHosted: hosted, configurationFilePresent: present,
                  legacyFilePickerFixEnabled: configured, documentHostFixEnabled: configured,
                  launchWithJITEnabled: configured, jitScriptInstalled: configured, jitScriptMatches: configured)
        }
        let incomplete = status(configured: false)
        let complete = status(configured: true)
        XCTAssertTrue(incomplete.setupFeedback(launchStatus: incomplete)!.contains("incomplete"))
        XCTAssertTrue(complete.setupFeedback(launchStatus: incomplete)!.contains("Restart required"))
        XCTAssertTrue(complete.setupFeedback(launchStatus: complete)!.contains("setup complete"))
        XCTAssertTrue(status(present: false, configured: false).setupFeedback(launchStatus: complete)!.contains("Could not verify"))
        XCTAssertNil(status(hosted: false, configured: false).setupFeedback(launchStatus: incomplete))
    }

    func testActivationStartsWithLiveContainerRepairWhenHostedSetupIsIncomplete() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: true,
                liveContainerConfigured: false,
                repairRequiresRestart: false,
                gameCount: 0,
                readyGameCount: 0,
                blockedGameCount: 0,
                launchSupportUnavailable: true,
                featuredGameTitle: nil
            )
        )

        XCTAssertEqual(state.phase, .repairLiveContainer)
        XCTAssertEqual(state.actionTitle, "Fix LiveContainer Setup")
    }

    func testActivationRequestsImportAfterHostSetupCompletes() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: true,
                liveContainerConfigured: true,
                repairRequiresRestart: false,
                gameCount: 0,
                readyGameCount: 0,
                blockedGameCount: 0,
                launchSupportUnavailable: false,
                featuredGameTitle: nil
            )
        )

        XCTAssertEqual(state.phase, .importGame)
        XCTAssertEqual(state.actionTitle, "Choose Game Folder")
    }

    func testActivationRequiresRestartAfterLiveContainerRepair() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: true,
                liveContainerConfigured: true,
                repairRequiresRestart: true,
                gameCount: 0,
                readyGameCount: 0,
                blockedGameCount: 0,
                launchSupportUnavailable: false,
                featuredGameTitle: nil
            )
        )

        XCTAssertEqual(state.phase, .restartAfterRepair)
        XCTAssertEqual(state.actionTitle, "Check Setup Again")
    }

    func testActivationPrioritizesLaunchSupportBeforeGameBlockers() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: true,
                liveContainerConfigured: true,
                repairRequiresRestart: false,
                gameCount: 1,
                readyGameCount: 0,
                blockedGameCount: 1,
                launchSupportUnavailable: true,
                featuredGameTitle: "Hades II"
            )
        )

        XCTAssertEqual(state.phase, .enableLaunching)
        XCTAssertEqual(state.actionTitle, "Check Launch Support")
    }

    func testActivationOffersPlayForReadyGame() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: false,
                liveContainerConfigured: false,
                repairRequiresRestart: false,
                gameCount: 1,
                readyGameCount: 1,
                blockedGameCount: 0,
                launchSupportUnavailable: false,
                featuredGameTitle: "Hades II"
            )
        )

        XCTAssertEqual(state.phase, .playGame)
        XCTAssertEqual(state.title, "Hades II")
        XCTAssertEqual(state.actionTitle, "Play")
    }

    func testActivationRoutesBlockedGameToItsDetail() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: false,
                liveContainerConfigured: false,
                repairRequiresRestart: false,
                gameCount: 1,
                readyGameCount: 0,
                blockedGameCount: 1,
                launchSupportUnavailable: false,
                featuredGameTitle: "Hades II"
            )
        )

        XCTAssertEqual(state.phase, .resolveGameBlocker)
        XCTAssertEqual(state.actionTitle, "Review Hades II")
    }

    func testActivationReviewsImportedGameWithoutAReadinessResult() {
        let state = ProductActivationState.resolve(
            ProductActivationContext(
                isHostedByLiveContainer: false,
                liveContainerConfigured: false,
                repairRequiresRestart: false,
                gameCount: 1,
                readyGameCount: 0,
                blockedGameCount: 0,
                launchSupportUnavailable: false,
                featuredGameTitle: "Hades II"
            )
        )

        XCTAssertEqual(state.phase, .reviewGame)
        XCTAssertEqual(state.actionTitle, "Review Hades II")
    }

    func testAppBackgroundTransitionDoesNotDismissRuntimePlayer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repoRoot.appending(path: "apps/ios/Iridium/IridiumApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            appSource.contains("case .background:\n                    viewModel.dismissActiveRuntimePlayer()"),
            "Background scene transitions must not release the fullscreen runtime player while FEX is still booting."
        )
    }

    func testLaunchSessionUsesCompatibilityLaunchArgumentsWhenStoredArgumentsAreEmpty() throws {
        let fixture = try makeGameFixture(title: "Existing Lightweight Game")
        var game = fixture.game
        game.compatibilityProfileName = "lightweight-default"
        game.launchProfile.arguments = []
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            games: [game]
        )

        let session = viewModel.launchSession(for: game)

        XCTAssertEqual(
            session.arguments,
            ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
        )
    }

    func testLaunchSessionUsesUnityOpenGLArgumentsForMetalFallbackWhenStoredArgumentsAreEmpty() throws {
        let fixture = try makeGameFixture(title: "Existing Hollow Knight Import")
        var game = fixture.game
        game.compatibilityProfileName = "balanced-default"
        game.rendererPreset = .metalOpenGLFallback
        game.launchProfile.rendererPreset = .metalOpenGLFallback
        game.launchProfile.arguments = []
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            games: [game]
        )

        let session = viewModel.launchSession(for: game)

        XCTAssertEqual(
            session.arguments,
            ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
        )
    }

    func testLaunchSessionReplacesWindowedOnlyArgumentsForMetalFallback() throws {
        let fixture = try makeGameFixture(title: "Existing Hollow Knight Import")
        var game = fixture.game
        game.compatibilityProfileName = "balanced-default"
        game.rendererPreset = .metalOpenGLFallback
        game.launchProfile.rendererPreset = .metalOpenGLFallback
        game.launchProfile.arguments = ["--windowed"]
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            games: [game]
        )

        let session = viewModel.launchSession(for: game)

        XCTAssertEqual(
            session.arguments,
            ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
        )
    }

    func testLaunchSessionReplacesWindowedArgumentsWhenRuntimePolicyFallsBackToMetalOpenGL() throws {
        let fixture = try makeGameFixture(title: "Existing Hollow Knight Import")
        var game = fixture.game
        game.compatibilityProfileName = "balanced-default"
        game.rendererPreset = .dxvkBalanced
        game.launchProfile.rendererPreset = .dxvkBalanced
        game.launchProfile.arguments = ["--windowed"]
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            games: [game],
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: readyReadiness(summary: "Presentation bridge ready."),
                input: readyReadiness(summary: "Input bridge ready."),
                audio: readyReadiness(summary: "Audio bridge ready.")
            )
        )

        XCTAssertEqual(viewModel.runtimePolicy(for: game).rendererOverride, .metalOpenGLFallback)

        let session = viewModel.launchSession(for: game)

        XCTAssertEqual(
            session.arguments,
            ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
        )
    }

    func testLaunchActionCanPreparePlayerWhenPlayabilityIsOnlyBlocker() throws {
        let fixture = try makeGameFixture(title: "Prepare Player")
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                constraints: [
                    "Steam bridge heartbeat is missing.",
                    "Device launches use the bundled on-device runtime backend.",
                ],
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        XCTAssertEqual(viewModel.launchActionTitle(for: fixture.game), "Prepare Player and Launch")
        XCTAssertFalse(viewModel.isLaunchActionDisabled(for: fixture.game))
        XCTAssertTrue(viewModel.launchActionDetail(for: fixture.game)?.contains("fullscreen player services") == true)
    }

    func testPlayerPreparationSurfacesGraphicsBackendBlocker() async throws {
        let fixture = try makeGameFixture(title: "Missing Graphics Backend")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let blockedAfterReservation = makeHostCapabilities(
            launchReady: true,
            presentation: blockedReadiness(
                status: "graphicsBackendMissing",
                summary:
                    "Runtime host presentation service is live, but this bundle does not include an iOS Wine graphics backend contract."
            ),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: blockedAfterReservation),
            runtimePlayerServiceRegistry: registry,
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let failureSurfaced = await waitUntil {
            viewModel.activityStatusMessage?.contains("does not include an iOS Wine graphics backend contract")
                == true
        }
        XCTAssertTrue(failureSurfaced)
        XCTAssertNil(viewModel.activeRuntimePlayerSession)
        XCTAssertEqual(registry.releaseCount(), 1)
    }

    func testRecordLaunchPreparationPromotesRunningSessionToActivePlayerAndDismissReleasesIt() async throws {
        let fixture = try makeGameFixture(title: "Running Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let executor = CapturingRunningRuntimeSessionExecutor()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let playerActivated = await waitUntil {
            viewModel.activeRuntimePlayerSession != nil
        }
        XCTAssertTrue(playerActivated)
        XCTAssertEqual(viewModel.activeRuntimePlayerSession?.gameID, fixture.game.id)
        XCTAssertEqual(registry.reserveCount(), 1)

        let reservation = try XCTUnwrap(registry.latestReservation())
        let renderHandle = try XCTUnwrap(reservation.services.first(where: { $0.kind == .render })?.handle)
        let inputHandle = try XCTUnwrap(reservation.services.first(where: { $0.kind == .input })?.handle)
        let audioHandle = try XCTUnwrap(reservation.services.first(where: { $0.kind == .audio })?.handle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renderHandle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputHandle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioHandle))

        let maybeCapturedRequest = await executor.lastRequest()
        let capturedRequest = try XCTUnwrap(maybeCapturedRequest)
        XCTAssertEqual(capturedRequest.preferredSessionIdentifier, viewModel.activeRuntimePlayerSession?.sessionIdentifier)
        XCTAssertEqual(capturedRequest.session.environment["IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH"], renderHandle)
        XCTAssertEqual(capturedRequest.session.environment["IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH"], inputHandle)
        XCTAssertEqual(capturedRequest.session.environment["IRIDIUM_WINE_IOS_AUDIO_STATE_PATH"], audioHandle)
        let bridgeConfigPath = try XCTUnwrap(capturedRequest.session.environment["IRIDIUM_WINE_IOS_BRIDGE_CONFIG"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridgeConfigPath))
        XCTAssertNotNil(capturedRequest.session.environment["IRIDIUM_WINE_IOS_TRACE_PATH"])
        XCTAssertEqual(capturedRequest.session.environment["IRIDIUM_WINE_IOS_GRAPHICS_DRIVER"], "wineios.drv")
        XCTAssertEqual(
            capturedRequest.session.environment["WINEDEBUG"],
            "err+all,warn+loaddll,warn+seh,warn+driver,warn+winediag,warn+winstation"
        )
        let wineDebugLogPath = try XCTUnwrap(capturedRequest.session.environment["WINEDEBUGLOG"])
        XCTAssertTrue(wineDebugLogPath.hasSuffix("wine-debug.log"))
        XCTAssertNotNil(capturedRequest.session.environment["IRIDIUM_WINE_IOS_SURFACE_WIDTH"])
        XCTAssertNotNil(capturedRequest.session.environment["IRIDIUM_WINE_IOS_SURFACE_HEIGHT"])

        viewModel.dismissActiveRuntimePlayer()
        let playerDismissed = await waitUntil {
            viewModel.activeRuntimePlayerSession == nil
        }
        XCTAssertTrue(playerDismissed)
        XCTAssertEqual(registry.releaseCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renderHandle))
    }

    func testPreparedPlayerLaunchDoesNotRunFullRefreshBeforeSubmittingRuntimeSession() async throws {
        let fixture = try makeGameFixture(title: "Immediate Submit Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let orderingProbe = LaunchOrderingProbe()
        let executor = CapturingRunningRuntimeSessionExecutor(orderingProbe: orderingProbe)
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: ProbedTestingHostCapabilityProvider(
                snapshotValue: readySnapshot,
                orderingProbe: orderingProbe
            ),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        var requestSubmitted = false
        for _ in 0..<50 {
            if await executor.lastRequest() != nil {
                requestSubmitted = true
                break
            }
            try? await Task.sleep(nanoseconds: 20 * 1_000_000)
        }
        XCTAssertTrue(requestSubmitted)
        let snapshotCountAtFirstExecute = await orderingProbe.snapshotCountAtFirstExecute()
        XCTAssertEqual(snapshotCountAtFirstExecute, 1)
    }

    func testPreparedPlayerLaunchDoesNotBlockViewerOnPostLaunchHostRefresh() async throws {
        let fixture = try makeGameFixture(title: "Post Refresh Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let executor = CapturingRunningRuntimeSessionExecutor()
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let capabilityProvider = SlowSubsequentTestingHostCapabilityProvider(
            snapshotValue: readySnapshot,
            delayAfterFirstSnapshot: 1.2
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: capabilityProvider,
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        viewModel.recordLaunchPreparation(for: fixture.game)

        let playerActivated = await waitUntil(timeoutMS: 800) {
            viewModel.activeRuntimePlayerSession != nil
        }
        let activationElapsed = ProcessInfo.processInfo.systemUptime - startedAt
        XCTAssertTrue(playerActivated)
        XCTAssertLessThan(activationElapsed, 0.8)
        try await Task.sleep(nanoseconds: 100 * 1_000_000)
        XCTAssertEqual(capabilityProvider.snapshotCountSnapshot(), 1)
    }

    func testPreparedPlayerLaunchContinuesThroughRuntimeHealthWarning() async throws {
        let fixture = try makeGameFixture(title: "Warning Only Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let executor = CapturingRunningRuntimeSessionExecutor()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            constraints: [
                "Steam bridge heartbeat is missing.",
                "Device launches use the bundled on-device runtime backend.",
            ],
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let validationService = FixedRuntimeValidationService(
            report: RuntimeHealthReport(
                status: .degraded,
                runtimeName: "Iridium Runtime Base",
                notes: ["Steam bridge heartbeat is missing.", "Runtime ready."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        var requestSubmitted = false
        for _ in 0..<50 {
            if await executor.lastRequest() != nil {
                requestSubmitted = true
                break
            }
            try? await Task.sleep(nanoseconds: 20 * 1_000_000)
        }
        XCTAssertTrue(requestSubmitted)
        XCTAssertNotNil(viewModel.activeRuntimePlayerSession)
        XCTAssertEqual(registry.reserveCount(), 1)
        XCTAssertEqual(registry.releaseCount(), 0)
        XCTAssertFalse(viewModel.activityStatusMessage?.contains("Launch prep blocked") == true)
    }

    func testRunningPlayerKeepsViewerOpenWhenFramebufferNeverAdvances() async throws {
        let fixture = try makeGameFixture(title: "Stalled Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let executor = CapturingRunningRuntimeSessionExecutor()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            runtimePlayerFirstFrameTimeoutNanoseconds: 50 * 1_000_000,
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let playerActivated = await waitUntil {
            viewModel.activeRuntimePlayerSession != nil
        }
        XCTAssertTrue(playerActivated)

        let sessionIdentifier = try XCTUnwrap(viewModel.activeRuntimePlayerSession?.sessionIdentifier)
        let readyMarkerURL = FileManager.default.temporaryDirectory
            .appending(path: "IridiumRuntimePlayer", directoryHint: .isDirectory)
            .appending(path: sessionIdentifier, directoryHint: .isDirectory)
            .appending(path: "framebuffer.bgra.ready")
        XCTAssertTrue(FileManager.default.createFile(atPath: readyMarkerURL.path, contents: Data()))
        let stallRecorded = await waitUntil(timeoutMS: 1_000) {
            viewModel.activeRuntimePlayerSession?.sessionIdentifier == sessionIdentifier
                && viewModel.activeRuntimePlayerSession?.state == .running
                && registry.releaseCount() == 0
                && viewModel.activityStatusMessage?.contains("Still waiting for the first frame") == true
        }
        XCTAssertTrue(stallRecorded)
        XCTAssertEqual(viewModel.activeRuntimePlayerSession?.sessionIdentifier, sessionIdentifier)
        XCTAssertEqual(registry.releasedSessionIdentifierSnapshot(), [])

        viewModel.dismissActiveRuntimePlayer()
        let playerDismissed = await waitUntil {
            viewModel.activeRuntimePlayerSession == nil
        }
        XCTAssertTrue(playerDismissed)
        XCTAssertEqual(registry.releaseCount(), 1)
        XCTAssertEqual(registry.releasedSessionIdentifierSnapshot(), [sessionIdentifier])
    }

    func testRunningPlayerTerminalFailureStaysVisibleUntilDismissed() async throws {
        let fixture = try makeGameFixture(title: "Terminal Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let executor = CapturingRunningRuntimeSessionExecutor()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .failed),
            runtimePlayerFirstFrameTimeoutNanoseconds: 500 * 1_000_000,
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let terminalObserved = await waitUntil {
            viewModel.activeRuntimePlayerSession?.state == .failed
                && registry.releaseCount() == 0
        }
        XCTAssertTrue(terminalObserved)
        let sessionIdentifier = try XCTUnwrap(viewModel.activeRuntimePlayerSession?.sessionIdentifier)
        XCTAssertEqual(viewModel.activeRuntimePlayerSession?.statusSummary, "Observed terminal state failed.")

        viewModel.dismissActiveRuntimePlayer()
        let playerDismissed = await waitUntil {
            viewModel.activeRuntimePlayerSession == nil
        }
        XCTAssertTrue(playerDismissed)
        XCTAssertEqual(registry.releaseCount(), 1)
        XCTAssertEqual(registry.releasedSessionIdentifierSnapshot(), [sessionIdentifier])
    }

    func testPresentedFirstFrameCancelsRunningPlayerWatchdog() async throws {
        let fixture = try makeGameFixture(title: "Presented Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let executor = CapturingRunningRuntimeSessionExecutor()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live for session player-session."),
            input: readyReadiness(summary: "Runtime host input service is live for session player-session."),
            audio: readyReadiness(summary: "Runtime host audio service is live for session player-session.")
        )
        let validationService = ConditionalRuntimeValidationService(
            healthyReport: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: ["Live presentation, input, and audio services are bound to the active session."]
            )
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: executor,
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: validationService,
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .running),
            runtimePlayerFirstFrameTimeoutNanoseconds: 50 * 1_000_000,
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host has not registered a live iOS presentation service for session host-capability-refresh."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS input bridge for session host-capability-refresh."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host has not registered a live iOS audio bridge for session host-capability-refresh."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let playerActivated = await waitUntil {
            viewModel.activeRuntimePlayerSession != nil
        }
        XCTAssertTrue(playerActivated)
        let sessionIdentifier = try XCTUnwrap(viewModel.activeRuntimePlayerSession?.sessionIdentifier)
        let evidenceBeforeFirstFrame = await viewModel.store.compatibilityEvidence()
        let gamesBeforeFirstFrame = await viewModel.store.allGames()
        XCTAssertTrue(evidenceBeforeFirstFrame.isEmpty)
        XCTAssertNil(gamesBeforeFirstFrame.first?.lastSuccessfulRuntimeBundleVersion)

        viewModel.recordRuntimePlayerFirstFramePresented(sessionIdentifier: sessionIdentifier)
        var firstFrameEvidence: CompatibilityEvidenceRecord?
        for _ in 0..<50 {
            firstFrameEvidence = await viewModel.store.compatibilityEvidence().first
            if firstFrameEvidence?.terminalStatus == "firstFramePresented" {
                break
            }
            try await Task.sleep(nanoseconds: 20 * 1_000_000)
        }

        XCTAssertEqual(firstFrameEvidence?.accepted, true)
        XCTAssertEqual(firstFrameEvidence?.terminalStatus, "firstFramePresented")
        XCTAssertEqual(viewModel.activeRuntimePlayerSession?.sessionIdentifier, sessionIdentifier)
        XCTAssertEqual(registry.releaseCount(), 0)
        XCTAssertFalse(viewModel.activityStatusMessage?.contains("Runtime player stalled") == true)
        let gamesAfterFirstFrame = await viewModel.store.allGames()
        XCTAssertEqual(
            gamesAfterFirstFrame.first?.lastSuccessfulRuntimeBundleVersion,
            FileSystemRuntimeBundleRegistry.defaultManifest.version
        )
    }

    func testCompletedSessionBeforeFirstFrameIsRecordedAsFailure() async throws {
        let fixture = try makeGameFixture(title: "No Frame Player")
        let registry = TrackingRuntimePlayerServiceRegistry()
        let readySnapshot = makeHostCapabilities(
            launchReady: true,
            presentation: readyReadiness(summary: "Runtime host presentation service is live."),
            input: readyReadiness(summary: "Runtime host input service is live."),
            audio: readyReadiness(summary: "Runtime host audio service is live.")
        )
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .ready,
            runtimeHealth: degradedPlayabilityRuntimeHealth(),
            games: [fixture.game],
            sessionExecutor: CapturingRunningRuntimeSessionExecutor(),
            capabilityProvider: FixedTestingHostCapabilityProvider(snapshotValue: readySnapshot),
            validationService: ConditionalRuntimeValidationService(
                healthyReport: RuntimeHealthReport(
                    status: .healthy,
                    runtimeName: "Iridium Runtime Base",
                    notes: ["Player services are live."]
                )
            ),
            runtimePlayerServiceRegistry: registry,
            runningSessionObserver: TestRunningSessionObserver(terminalState: .completed),
            runtimePlayerFirstFrameTimeoutNanoseconds: 500 * 1_000_000,
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary: "Runtime host presentation service is not reserved yet."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary: "Runtime host input service is not reserved yet."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary: "Runtime host audio service is not reserved yet."
                )
            )
        )

        viewModel.recordLaunchPreparation(for: fixture.game)

        let terminalObserved = await waitUntil {
            viewModel.activeRuntimePlayerSession?.state == .completed
        }
        XCTAssertTrue(terminalObserved)

        var recordedFailure: LaunchHistoryEntry?
        for _ in 0..<50 {
            recordedFailure = (await viewModel.store.launchHistory()).first
            if recordedFailure?.failureCode == RuntimeFailureCode.gameProcessExited.rawValue {
                break
            }
            try await Task.sleep(nanoseconds: 20 * 1_000_000)
        }

        let evidence = await viewModel.store.compatibilityEvidence()
        let games = await viewModel.store.allGames()
        XCTAssertEqual(recordedFailure?.terminalStatus, RuntimeHostSessionState.completed.rawValue)
        XCTAssertEqual(recordedFailure?.failureCode, RuntimeFailureCode.gameProcessExited.rawValue)
        XCTAssertTrue(recordedFailure?.failureReason?.contains("before the fullscreen player presented a frame") == true)
        XCTAssertEqual(evidence.first?.accepted, false)
        XCTAssertNil(games.first?.lastSuccessfulRuntimeBundleVersion)
    }

    func testRuntimePlayerSurfaceUsesCappedLandscapeBufferForPhoneNativeBounds() {
        let surface = runtimePlayerSurfaceSize(nativeWidth: 1179, nativeHeight: 2556)

        XCTAssertEqual(surface.width, 960)
        XCTAssertEqual(surface.height, 540)
    }

    func testPresentationStatusPrefersQueuedLaunchOverPlayabilityWarning() throws {
        let fixture = try makeGameFixture(title: "Queued Game")
        let pendingLaunch = makePendingLaunch(for: fixture.game)
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            games: [fixture.game],
            pendingLaunches: [pendingLaunch],
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host does not provide an iOS presentation service for guest windows yet."
                ),
                input: blockedReadiness(
                    status: "inputBridgeMissing",
                    summary:
                        "Runtime host does not provide an iOS input bridge for guest events yet."
                ),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host does not provide an iOS audio bridge for guest output yet."
                )
            )
        )

        let status = viewModel.presentationStatus(for: fixture.game)
        XCTAssertEqual(status?.title, "Queued For JIT")
        XCTAssertEqual(status?.tone, .warning)
    }

    func testPresentationStatusReportsNotPlayableYetWhenFilesExist() throws {
        let fixture = try makeGameFixture(title: "Playable Blocked")
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            games: [fixture.game],
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host does not provide an iOS presentation service for guest windows yet."
                ),
                input: readyReadiness(summary: "Guest input path is ready."),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary:
                        "Runtime host does not provide an iOS audio bridge for guest output yet."
                )
            )
        )

        let status = try XCTUnwrap(viewModel.presentationStatus(for: fixture.game))
        XCTAssertEqual(status.title, "Not Playable Yet")
        XCTAssertEqual(status.tone, .warning)
        XCTAssertTrue(status.summary.contains("presentation and audio support"))
    }

    func testPresentationStatusReturnsNilWhenFilesExistAndPlayabilityReady() throws {
        let fixture = try makeGameFixture(title: "Playable Ready")
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            games: [fixture.game],
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: readyReadiness(summary: "Guest presentation path is ready."),
                input: readyReadiness(summary: "Guest input path is ready."),
                audio: readyReadiness(summary: "Guest audio path is ready.")
            )
        )

        XCTAssertNil(viewModel.presentationStatus(for: fixture.game))
    }

    func testRuntimeSubsystemStatusesReportBlockedReadyAndUnreportedStates() {
        let viewModel = AppViewModel.makeForTesting(
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary:
                        "Runtime host does not provide an iOS presentation service for guest windows yet."
                ),
                input: readyReadiness(summary: "Guest input path is ready."),
                audio: nil
            )
        )

        let statuses = viewModel.runtimeSubsystemStatuses
        XCTAssertEqual(statuses.map(\.title), ["Presentation", "Input", "Audio"])
        XCTAssertEqual(statuses[0].status, "Blocked")
        XCTAssertEqual(statuses[0].tone, .blocked)
        XCTAssertEqual(statuses[1].status, "Ready")
        XCTAssertEqual(statuses[1].tone, .ready)
        XCTAssertEqual(statuses[2].status, "Unreported")
        XCTAssertEqual(statuses[2].tone, .warning)
    }

    func testRuntimeSubsystemStatusesShowPendingWhenLaunchBootstrapIsUnavailable() {
        let viewModel = AppViewModel.makeForTesting(
            hostCapabilities: makeHostCapabilities(
                launchReady: false,
                launchStatus: "bootstrapMissing",
                launchStatusSummary:
                    "Embedded FEX build does not include the FEXCore runtime bootstrap.",
                presentation: blockedReadiness(
                    status: "launchBlocked",
                    summary:
                        "Guest presentation is blocked until embedded launch bootstrap is ready."
                ),
                input: nil,
                audio: nil
            )
        )

        let statuses = viewModel.runtimeSubsystemStatuses
        XCTAssertEqual(statuses.map(\.status), ["Blocked", "Pending", "Pending"])
        XCTAssertEqual(
            statuses[1].summary,
            "Embedded FEX build does not include the FEXCore runtime bootstrap."
        )
        XCTAssertEqual(
            statuses[2].summary,
            "Embedded FEX build does not include the FEXCore runtime bootstrap."
        )
    }

    func testRuntimeConstraintNotesFilterDuplicatedPlayabilitySummaries() {
        let presentationSummary =
            "Runtime host does not provide an iOS presentation service for guest windows yet."
        let audioSummary =
            "Runtime host does not provide an iOS audio bridge for guest output yet."
        let viewModel = AppViewModel.makeForTesting(
            hostCapabilities: makeHostCapabilities(
                launchReady: true,
                constraints: [
                    presentationSummary,
                    audioSummary,
                    "Low power mode is enabled.",
                ],
                presentation: blockedReadiness(
                    status: "presentationServiceMissing",
                    summary: presentationSummary
                ),
                input: readyReadiness(summary: "Guest input path is ready."),
                audio: blockedReadiness(
                    status: "audioBridgeMissing",
                    summary: audioSummary
                )
            )
        )

        XCTAssertEqual(viewModel.runtimeConstraintNotes, ["Low power mode is enabled."])
    }

    func testLaunchActionDetailUsesHostFailureSummaryWhenJITIsUnavailable() throws {
        let fixture = try makeGameFixture(title: "JIT Unavailable")
        let summary =
            "Embedded FEX runtime could not allocate a MAP_JIT code page: Operation not permitted"
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .unavailable,
            runtimeHealth: RuntimeHealthReport(
                status: .actionRequired,
                runtimeName: "Iridium Runtime Base",
                notes: [summary]
            ),
            games: [fixture.game],
            hostCapabilities: makeHostCapabilities(
                jitStatus: .unavailable,
                launchReady: false,
                launchStatus: "jitUnavailable",
                launchStatusSummary: summary,
                presentation: blockedReadiness(
                    status: "launchBlocked",
                    summary:
                        "Guest presentation is blocked until embedded launch bootstrap is ready."
                ),
                input: nil,
                audio: nil
            )
        )

        XCTAssertEqual(viewModel.launchActionTitle(for: fixture.game), "Direct Launch Unavailable")
        XCTAssertEqual(viewModel.launchActionDetail(for: fixture.game), summary)
    }

    func testBackendUnavailableStateUsesHostSummaryAfterExternalJITRequest() throws {
        let fixture = try makeGameFixture(title: "JIT Request Timed Out")
        let summary = "JitStreamer attach endpoint succeeded, but Iridium never observed runtime readiness."
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .unavailable,
            games: [fixture.game],
            pendingExternalJITProvider: .jitStreamer,
            jitStreamerAddress: "192.168.1.20:9172",
            hostCapabilities: makeHostCapabilities(
                jitStatus: .unavailable,
                launchReady: false,
                launchStatus: "jitUnavailable",
                launchStatusSummary: summary,
                jitSummary: summary,
                jitSessionKind: .debuggerBacked,
                jitFailureStage: "external bootstrap required",
                presentation: blockedReadiness(
                    status: "launchBlocked",
                    summary: "Guest presentation is blocked until embedded launch bootstrap is ready."
                ),
                input: nil,
                audio: nil
            )
        )

        XCTAssertEqual(viewModel.jitLaunchNotice, summary)
        XCTAssertEqual(viewModel.launchActionDetail(for: fixture.game), summary)
    }

    func testWaitingForExternalEnablementReportsAltJITWithoutObservedReadiness() throws {
        let fixture = try makeGameFixture(title: "Waiting For AltJIT")
        let viewModel = AppViewModel.makeForTesting(
            managedRootURL: fixture.root,
            jitStatus: .required,
            games: [fixture.game],
            pendingExternalJITProvider: .altJIT,
            externalJITBundleInfo: ExternalJITBundleInfo(
                bundleIdentifier: "software.iridium",
                altServerID: "server-id",
                altDeviceID: "device-id"
            ),
            hostCapabilities: makeHostCapabilities(
                jitStatus: .required,
                launchReady: false,
                launchStatus: "jitRequired",
                launchStatusSummary: "No external debugger/JIT session detected.",
                jitToolRecommendation: .stikDebug,
                jitSessionKind: JITSessionKind.none,
                jitFailureStage: "debugger signal missing",
                presentation: blockedReadiness(
                    status: "launchBlocked",
                    summary: "Guest presentation is blocked until embedded launch bootstrap is ready."
                ),
                input: nil,
                audio: nil
            )
        )

        XCTAssertEqual(
            viewModel.jitLaunchNotice,
            "Iridium requested JIT through AltJIT, but this app process still does not appear ready. Keep AltServer available, then check again."
        )
        XCTAssertEqual(
            viewModel.checkedJITSummary(at: "9:41 PM", status: JITStatus.required),
            "Checked at 9:41 PM. Iridium requested JIT through AltJIT, but this app process still does not appear ready. Keep AltServer available, then check again."
        )
    }

    func testProviderResolverPrefersAltJITWhenBundleHasAltServerAndAltDeviceIDs() throws {
        let provider = ExternalJITProviderResolver.recommendedProvider(
            for: makeHostCapabilities(
                jitStatus: .required,
                launchReady: false,
                jitToolRecommendation: .stikDebug,
                presentation: blockedReadiness(status: "launchBlocked", summary: "Presentation blocked."),
                input: nil,
                audio: nil
            ),
            bundleInfo: ExternalJITBundleInfo(
                bundleIdentifier: "software.iridium",
                altServerID: "server-id",
                altDeviceID: "device-id"
            ),
            jitStreamerAddress: "192.168.1.20:9172",
            installedSchemes: Set(["sidestore", "apple-magnifier"])
        )

        XCTAssertEqual(provider, .altJIT)
    }

    func testProviderResolverChoosesJitStreamerWhenConfiguredAndAltJITUnavailable() {
        let provider = ExternalJITProviderResolver.recommendedProvider(
            for: makeHostCapabilities(
                jitStatus: .required,
                launchReady: false,
                jitToolRecommendation: .stikDebug,
                presentation: blockedReadiness(status: "launchBlocked", summary: "Presentation blocked."),
                input: nil,
                audio: nil
            ),
            bundleInfo: ExternalJITBundleInfo(
                bundleIdentifier: "software.iridium",
                altServerID: nil,
                altDeviceID: nil
            ),
            jitStreamerAddress: "192.168.1.20:9172/",
            installedSchemes: Set(["sidestore", "apple-magnifier"])
        )

        XCTAssertEqual(provider, .jitStreamer)
    }

    func testProviderResolverFallsBackToSideStoreBeforeTrollStore() {
        let provider = ExternalJITProviderResolver.recommendedProvider(
            for: makeHostCapabilities(
                jitStatus: .required,
                launchReady: false,
                jitToolRecommendation: .stikDebug,
                presentation: blockedReadiness(status: "launchBlocked", summary: "Presentation blocked."),
                input: nil,
                audio: nil
            ),
            bundleInfo: ExternalJITBundleInfo(
                bundleIdentifier: "software.iridium",
                altServerID: nil,
                altDeviceID: nil
            ),
            jitStreamerAddress: "",
            installedSchemes: Set(["sidestore", "apple-magnifier"])
        )

        XCTAssertEqual(provider, .sideStore)
    }

    func testProviderResolverReturnsNilWhenNoProviderIsAvailable() {
        let provider = ExternalJITProviderResolver.recommendedProvider(
            for: makeHostCapabilities(
                jitStatus: .required,
                launchReady: false,
                jitToolRecommendation: .stikDebug,
                presentation: blockedReadiness(status: "launchBlocked", summary: "Presentation blocked."),
                input: nil,
                audio: nil
            ),
            bundleInfo: ExternalJITBundleInfo(
                bundleIdentifier: "software.iridium",
                altServerID: nil,
                altDeviceID: nil
            ),
            jitStreamerAddress: "",
            installedSchemes: []
        )

        XCTAssertNil(provider)
    }

    func testProviderResolverRequiresStikDebugForTXMCallbackDevices() {
        let snapshot = makeHostCapabilities(
            jitStatus: .required,
            launchReady: false,
            jitToolRecommendation: .stikDebug,
            presentation: blockedReadiness(status: "launchBlocked", summary: "Presentation blocked."),
            input: nil,
            audio: nil
        )
        let bundleInfo = ExternalJITBundleInfo(
            bundleIdentifier: "software.iridium",
            altServerID: "server-id",
            altDeviceID: "device-id"
        )

        XCTAssertNil(
            ExternalJITProviderResolver.recommendedProvider(
                for: snapshot,
                bundleInfo: bundleInfo,
                jitStreamerAddress: "192.168.1.20:9172",
                installedSchemes: Set(["sidestore"]),
                requiresPersistentDebuggerCallback: true
            )
        )
        XCTAssertEqual(
            ExternalJITProviderResolver.recommendedProvider(
                for: snapshot,
                bundleInfo: bundleInfo,
                jitStreamerAddress: "192.168.1.20:9172",
                installedSchemes: Set(["stikdebug"]),
                requiresPersistentDebuggerCallback: true
            ),
            .stikDebug
        )
    }

    func testJitStreamerAddressNormalizationPrependsHTTPAndStripsTrailingSlash() {
        XCTAssertEqual(
            ExternalJITProviderResolver.normalizedJitStreamerAddress(" 192.168.1.20:9172/ "),
            "http://192.168.1.20:9172"
        )
        XCTAssertEqual(
            ExternalJITProviderResolver.normalizedJitStreamerAddress("https://jit.example.test:9172/"),
            "https://jit.example.test:9172"
        )
    }

    func testSideStoreLaunchURLStillBuilds() throws {
        let url = try XCTUnwrap(
            ExternalJITProviderResolver.launchURL(
                for: .sideStore,
                bundleIdentifier: "software.iridium",
                processIdentifier: 7,
                installedSchemes: Set(["sidestore"])
            )
        )

        XCTAssertEqual(url.scheme, "sidestore")
        XCTAssertEqual(url.host, "sidejit-enable")
    }

    func testTrollStoreLaunchURLStillBuilds() throws {
        let url = try XCTUnwrap(
            ExternalJITProviderResolver.launchURL(
                for: .trollStore,
                bundleIdentifier: "software.iridium",
                processIdentifier: 7,
                installedSchemes: Set(["apple-magnifier"])
            )
        )

        XCTAssertEqual(url.scheme, "apple-magnifier")
        XCTAssertEqual(url.host, "enable-jit")
    }

    func testStikDebugLaunchURLIncludesBootstrapScriptAndTargetsCurrentPID() throws {
        let bootstrapAssets = try XCTUnwrap(
            JITBootstrapAssetBundle.recommended(
                kind: nil,
                recommendation: .stikDebug
            )
        )

        let url = try XCTUnwrap(
            JITHelperLaunchURLFactory.launchURL(
                tool: .stikDebug,
                bundleIdentifier: "software.iridium",
                processIdentifier: 7,
                installedSchemes: Set(["stikjit"]),
                bootstrapAssets: bootstrapAssets
            )
        )

        XCTAssertEqual(url.scheme, "stikjit")
        XCTAssertEqual(url.host, "enable-jit")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { item in
            (item.name, item.value ?? "")
        })

        XCTAssertEqual(queryItems["bundle-id"], "software.iridium")
        XCTAssertEqual(queryItems["pid"], "7")
        XCTAssertEqual(queryItems["script-name"], "IridiumDebuggerBootstrap.js")
        XCTAssertEqual(
            queryItems["script-data"],
            bootstrapAssets.baseScript.base64EncodedPayload
        )
    }

    func testLiveContainer2ForwardsCompleteStikDebugRequest() throws {
        let assets = try XCTUnwrap(JITBootstrapAssetBundle.recommended(kind: nil, recommendation: .stikDebug))
        let url = try XCTUnwrap(JITHelperLaunchURLFactory.launchURL(
            tool: .stikDebug, bundleIdentifier: "software.iridium", processIdentifier: 7,
            installedSchemes: ["livecontainer2"], bootstrapAssets: assets))
        XCTAssertEqual(url.scheme, "livecontainer2")
        XCTAssertEqual(url.host, "open-url")
        let outer = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let payload = try XCTUnwrap(outer.queryItems?.first?.value)
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        let guest = try XCTUnwrap(String(data: data, encoding: .utf8))
        let inner = try XCTUnwrap(URLComponents(string: guest))
        XCTAssertEqual(inner.scheme, "stikjit")
        XCTAssertEqual(inner.host, "enable-jit")
        let query = Dictionary(uniqueKeysWithValues: (inner.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["pid"], "7")
        XCTAssertEqual(query["bundle-id"], "software.iridium")
        XCTAssertEqual(query["script-data"], assets.baseScript.base64EncodedPayload)
    }

    func testTXMCompatibilityMatchesCurrentStikDebugDevicePolicy() {
        XCTAssertFalse(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 26,
                hardwareIdentifier: "iPhone14,1"
            )
        )
        XCTAssertTrue(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 26,
                hardwareIdentifier: "iPhone14,2"
            )
        )
        XCTAssertFalse(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 26,
                hardwareIdentifier: "iPad14,4"
            )
        )
        XCTAssertTrue(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 26,
                hardwareIdentifier: "iPad14,5"
            )
        )
        XCTAssertFalse(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 26,
                hardwareIdentifier: "iPad14,11"
            )
        )
        XCTAssertFalse(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 27,
                hardwareIdentifier: "iPad8,11"
            )
        )
        XCTAssertTrue(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 27,
                hardwareIdentifier: "iPhone12,1"
            )
        )
        XCTAssertFalse(
            JITPlatformCompatibility.inferTXM(
                iOSMajorVersion: 25,
                hardwareIdentifier: "iPhone17,1"
            )
        )
    }

    func testLiveContainerRepairConfiguresPickerAndPersistentJITScript() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurationURL = root.appending(path: LiveContainerIntegration.configurationFileName)
        let original: [String: Any] = [
            "doSymlinkInbox": false,
            "fixFilePickerNew": false,
            "isJITNeeded": false,
            "jitLaunchScriptJs": Data("stale".utf8).base64EncodedString(),
            "unrelatedLiveContainerSetting": "preserve-me",
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: original,
            format: .binary,
            options: 0
        )
        try originalData.write(to: configurationURL)

        let expectedScript = Data("persistent TXM callback".utf8)
        let before = LiveContainerIntegration.status(
            configurationURL: configurationURL,
            isHosted: true,
            expectedJITScriptData: expectedScript
        )
        XCTAssertFalse(before.filePickerConfigured)
        XCTAssertFalse(before.jitConfigured)

        let repaired = try LiveContainerIntegration.repair(
            configurationURL: configurationURL,
            expectedJITScriptData: expectedScript
        )
        XCTAssertTrue(repaired.fullyConfigured)
        XCTAssertTrue(repaired.legacyFilePickerFixEnabled)
        XCTAssertTrue(repaired.documentHostFixEnabled)
        XCTAssertTrue(repaired.launchWithJITEnabled)
        XCTAssertTrue(repaired.jitScriptMatches)

        let repairedData = try Data(contentsOf: configurationURL)
        let repairedPropertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: repairedData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(repairedPropertyList["unrelatedLiveContainerSetting"] as? String, "preserve-me")
        XCTAssertEqual(
            repairedPropertyList["jitLaunchScriptJs"] as? String,
            expectedScript.base64EncodedString()
        )
    }

    func testLiveContainerInfersStikDebugOnlyForExactActiveLaunchConfiguration() {
        let verified = LiveContainerIntegrationStatus(
            isHosted: true,
            configurationFilePresent: true,
            legacyFilePickerFixEnabled: true,
            documentHostFixEnabled: true,
            launchWithJITEnabled: true,
            jitScriptInstalled: true,
            jitScriptMatches: true
        )
        XCTAssertEqual(
            LiveContainerIntegration.inferredActiveJITProviderIdentifier(for: verified),
            ExternalJITProvider.stikDebug.runtimeIdentifier
        )

        let staleScript = LiveContainerIntegrationStatus(
            isHosted: true,
            configurationFilePresent: true,
            legacyFilePickerFixEnabled: true,
            documentHostFixEnabled: true,
            launchWithJITEnabled: true,
            jitScriptInstalled: true,
            jitScriptMatches: false
        )
        XCTAssertNil(
            LiveContainerIntegration.inferredActiveJITProviderIdentifier(for: staleScript)
        )

        let notHosted = LiveContainerIntegrationStatus(
            isHosted: false,
            configurationFilePresent: true,
            legacyFilePickerFixEnabled: true,
            documentHostFixEnabled: true,
            launchWithJITEnabled: true,
            jitScriptInstalled: true,
            jitScriptMatches: true
        )
        XCTAssertNil(
            LiveContainerIntegration.inferredActiveJITProviderIdentifier(for: notHosted)
        )
    }

    #if canImport(JavaScriptCore)
        func testLiveContainerBootstrapScriptExecutesAndInstallsExtensionCode() throws {
            let context = try XCTUnwrap(JSContext())
            var debuggerCommands: [String] = []
            let stopPacket =
                "T05thread:1;20:0010000000000000;00:0000000000000000;01:0000000000000000;10:0000000000000000;"

            let getPID: @convention(block) () -> Int = { 123 }
            let sendCommand: @convention(block) (String) -> String = { command in
                debuggerCommands.append(command)
                if command.hasPrefix("vAttach;") {
                    return "T05thread:1;"
                }
                if command == "c" {
                    return stopPacket
                }
                if command.hasPrefix("m1000,4") {
                    // BRK #0xf00d encoded as little-endian AArch64 bytes.
                    return "a0013ed4"
                }
                if command.hasPrefix("P20=") || command == "D" {
                    return "OK"
                }
                return ""
            }
            let prepareMemoryRegion: @convention(block) (UInt64, UInt64) -> String = {
                _, _ in "OK"
            }
            let log: @convention(block) (String) -> Void = { _ in }

            context.setObject(getPID, forKeyedSubscript: "get_pid" as NSString)
            context.setObject(sendCommand, forKeyedSubscript: "send_command" as NSString)
            context.setObject(
                prepareMemoryRegion,
                forKeyedSubscript: "prepare_memory_region" as NSString
            )
            context.setObject(log, forKeyedSubscript: "log" as NSString)

            let script = try XCTUnwrap(
                String(data: JITBootstrapAssetBundle.liveContainerScriptData, encoding: .utf8)
            )
            context.evaluateScript(script)

            XCTAssertNil(context.exception)
            XCTAssertTrue(debuggerCommands.contains(where: { $0.hasPrefix("vAttach;") }))
            XCTAssertTrue(debuggerCommands.contains("D"))

            let extensionResult = context.evaluateScript(
                "runScriptAndCapture(`iridiumCommands[3] = function() { return 7; }; 42`)"
            )
            XCTAssertTrue(extensionResult?.objectForKeyedSubscript("ok")?.toBool() == true)
            XCTAssertEqual(
                extensionResult?.objectForKeyedSubscript("value")?.toInt32(),
                42
            )
            XCTAssertTrue(
                context.evaluateScript("typeof iridiumCommands[3] === `function`")?.toBool()
                    == true
            )

            let failureResult = context.evaluateScript(
                "runScriptAndCapture(`throw new TypeError(\\`extension failed\\`)`)"
            )
            XCTAssertTrue(failureResult?.objectForKeyedSubscript("ok")?.toBool() == false)
            XCTAssertEqual(
                failureResult?.objectForKeyedSubscript("name")?.toString(),
                "TypeError"
            )
        }
    #endif

    func testSuccessfulScannedImportClearsReviewStateAndRefreshesLibrary() async throws {
        let fixture = try makeGameFixture(title: "Imported Game")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let viewModel = AppViewModel.makeForTesting(managedRootURL: fixture.root)
        let installRoot = URL(fileURLWithPath: fixture.game.installPath, isDirectory: true)
        viewModel.scanImportFolder(at: installRoot)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.importScanResult?.recommendedExecutable != nil
        }
        XCTAssertNotNil(viewModel.importScanResult?.recommendedExecutable)

        viewModel.registerScannedImport(title: "Imported Game")
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.games.contains(where: { $0.title == "Imported Game" })
                && viewModel.importScanResult == nil
        }

        XCTAssertNil(viewModel.importScanResult)
        XCTAssertTrue(viewModel.games.contains(where: { $0.title == "Imported Game" }))
        XCTAssertTrue(viewModel.importStatusMessage?.hasPrefix("Registered Imported Game") == true)
    }

    func testScannedImportStoresIdentifierMatchingFinalRegisterTitle() async throws {
        // Registration keeps the folder title used for scan-time metadata.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let installDir = root.appending(path: "HollowKnight", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try Data("fake-exe".utf8).write(
            to: installDir.appending(path: "hollow_knight.exe"))
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = AppViewModel.makeForTesting(managedRootURL: root)
        viewModel.scanImportFolder(at: installDir)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.importScanResult?.recommendedExecutable != nil
        }
        XCTAssertNotNil(viewModel.importScanResult?.recommendedExecutable)

        viewModel.registerScannedImport()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.games.contains(where: { $0.title == "HollowKnight" })
                && viewModel.importScanResult == nil
        }

        guard let game = viewModel.games.first(where: { $0.title == "HollowKnight" })
        else {
            XCTFail("Expected registered game titled HollowKnight")
            return
        }
        let expectedIdentifier = try FileSystemGameArtifactInventory().makeManagedArtifact(
            title: game.title,
            executablePath: game.launchProfile.executablePath,
            installPath: game.installPath
        ).identifier
        XCTAssertEqual(game.managedArtifactIdentifier, expectedIdentifier)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private func makeGameFixture(
    title: String,
    executableExists: Bool = true
) throws -> (root: URL, game: GameRecord) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let installRoot = root.appending(path: "game", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let executableURL = installRoot.appending(path: "\(title).exe")
    if executableExists {
        try Data(title.utf8).write(to: executableURL)
    }

    let launchProfile = GameLaunchProfile(
        executablePath: executableURL.path,
        arguments: [],
        prefixID: UUID(),
        rendererPreset: .metalOpenGLFallback,
        deviceTier: .tier1,
        titleFlags: ["manual-import"]
    )
    let fingerprint =
        executableExists
        ? try FileSystemGameArtifactInventory().fingerprintExecutable(at: executableURL.path).value
        : "missing-executable"
    let game = GameRecord(
        title: title,
        source: .manualImport,
        installPath: installRoot.path,
        savePathMapping: "Documents/Saves/\(title)",
        compatibilityProfileName: "\(title.lowercased())-default",
        inputProfileName: "Touch + Controller",
        touchOverlayName: "Default Layout",
        controllerPresetName: "Standard Gamepad",
        keyboardMouseEnabled: true,
        prefixState: .clean,
        deviceTier: .tier1,
        rendererPreset: .metalOpenGLFallback,
        launchProfile: launchProfile,
        installedSizeGB: 1.0,
        executableFingerprint: fingerprint,
        summary: "AppViewModel test fixture"
    )

    return (root, game)
}

private func makePendingLaunch(for game: GameRecord) -> PendingLaunchRecord {
    PendingLaunchRecord(
        launchEntryID: UUID(),
        gameID: game.id,
        gameTitle: game.title,
        prefixID: game.launchProfile.prefixID,
        resolvedExecutablePath: game.launchProfile.executablePath,
        workingDirectory: game.installPath,
        launchArguments: game.launchProfile.arguments,
        environment: ["IRIDIUM_NO_DESKTOP": "1"],
        resolvedPolicySummary: "Queued for JIT.",
        status: .waitingForJIT,
        detail:
            "Iridium saved this launch request and will resume it automatically once JIT becomes available."
    )
}

private func degradedPlayabilityRuntimeHealth() -> RuntimeHealthReport {
    RuntimeHealthReport(
        status: .degraded,
        runtimeName: "Iridium Runtime Base",
        notes: ["Embedded launch bootstrap is ready, but the runtime is not yet playable on this host."]
    )
}

private struct FixedTestingHostCapabilityProvider: HostCapabilityProvider {
    let snapshotValue: HostCapabilitySnapshot

    func snapshot() async -> HostCapabilitySnapshot {
        snapshotValue
    }
}

private struct ProbedTestingHostCapabilityProvider: HostCapabilityProvider {
    let snapshotValue: HostCapabilitySnapshot
    let orderingProbe: LaunchOrderingProbe

    func snapshot() async -> HostCapabilitySnapshot {
        await orderingProbe.recordSnapshot()
        return snapshotValue
    }
}

private final class SlowSubsequentTestingHostCapabilityProvider: HostCapabilityProvider,
    @unchecked Sendable
{
    let snapshotValue: HostCapabilitySnapshot
    let delayAfterFirstSnapshot: TimeInterval
    private var snapshotCount = 0

    init(snapshotValue: HostCapabilitySnapshot, delayAfterFirstSnapshot: TimeInterval) {
        self.snapshotValue = snapshotValue
        self.delayAfterFirstSnapshot = delayAfterFirstSnapshot
    }

    func snapshot() async -> HostCapabilitySnapshot {
        snapshotCount += 1
        let shouldDelay = snapshotCount > 1

        if shouldDelay {
            let deadline = ProcessInfo.processInfo.systemUptime + delayAfterFirstSnapshot
            while ProcessInfo.processInfo.systemUptime < deadline {}
        }

        return snapshotValue
    }

    func snapshotCountSnapshot() -> Int {
        snapshotCount
    }
}

private struct ConditionalRuntimeValidationService: RuntimeValidationService {
    let healthyReport: RuntimeHealthReport

    func validate(snapshot: HostCapabilitySnapshot) async -> RuntimeHealthReport {
        if snapshot.playabilityReady == true {
            return healthyReport
        }

        return degradedPlayabilityRuntimeHealth()
    }
}

private struct FixedRuntimeValidationService: RuntimeValidationService {
    let report: RuntimeHealthReport

    func validate(snapshot: HostCapabilitySnapshot) async -> RuntimeHealthReport {
        _ = snapshot
        return report
    }
}

private struct TestRunningSessionObserver: RuntimeRunningSessionObserver {
    let terminalState: RuntimeHostSessionState

    func resolveTerminalState(
        from execution: RuntimeSessionResult,
        gameID: UUID,
        gameTitle: String
    ) async -> RuntimeHostSession {
        RuntimeHostSession(
            id: execution.sessionIdentifier,
            gameID: gameID,
            gameTitle: gameTitle,
            launchTicketPath: execution.launchTicketPath,
            sessionLogPath: execution.sessionLogPath,
            telemetryPath: execution.telemetryPath,
            runtimeBundleID: execution.runtimeBundleID,
            runtimeBundleVersion: execution.runtimeBundleVersion,
            state: terminalState,
            stateHistory: execution.stateHistory.compactMap(RuntimeHostSessionState.init(rawValue:)),
            statusSummary: "Observed terminal state \(terminalState.rawValue).",
            startedAt: execution.launchedAt,
            updatedAt: Date()
        )
    }
}

private final class TrackingRuntimePlayerServiceRegistry: RuntimePlayerServiceRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var reservations: [RuntimePlayerReservation] = []
    private var releasedSessionIdentifiers: [String] = []

    func reserve(_ reservation: RuntimePlayerReservation) -> Result<Void, RuntimeFailure> {
        lock.lock()
        defer { lock.unlock() }
        reservations.append(reservation)
        return .success(())
    }

    func setServiceLiveness(
        sessionIdentifier: String,
        serviceKind: RuntimePlayerServiceKind,
        isLive: Bool
    ) -> Result<Void, RuntimeFailure> {
        _ = sessionIdentifier
        _ = serviceKind
        _ = isLive
        return .success(())
    }

    func release(sessionIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        releasedSessionIdentifiers.append(sessionIdentifier)
    }

    func reserveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reservations.count
    }

    func latestReservation() -> RuntimePlayerReservation? {
        lock.lock()
        defer { lock.unlock() }
        return reservations.last
    }

    func releaseCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return releasedSessionIdentifiers.count
    }

    func releasedSessionIdentifierSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return releasedSessionIdentifiers
    }
}

private final class CapturingRunningRuntimeSessionExecutor: RuntimeSessionExecutor, @unchecked Sendable {
    private let store = CapturedRuntimeSessionRequestStore()
    private let orderingProbe: LaunchOrderingProbe?

    init(orderingProbe: LaunchOrderingProbe? = nil) {
        self.orderingProbe = orderingProbe
    }

    func execute(_ request: RuntimeSessionRequest) async -> Result<RuntimeSessionResult, RuntimeFailure> {
        await orderingProbe?.recordExecute()
        await store.set(request)

        let sessionIdentifier = request.preferredSessionIdentifier ?? UUID().uuidString
        return .success(
            RuntimeSessionResult(
                sessionIdentifier: sessionIdentifier,
                terminalStatus: RuntimeHostSessionState.running.rawValue,
                launchTicketPath: "/tmp/ticket-\(sessionIdentifier).json",
                sessionLogPath: "/tmp/session-\(sessionIdentifier).log",
                telemetryPath: "/tmp/telemetry-\(sessionIdentifier).json",
                prefixManifestPath: "/tmp/prefix-manifest.json",
                runtimeBundleID: FileSystemRuntimeBundleRegistry.defaultManifest.id,
                runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
                resolvedExecutablePath: request.session.executablePath,
                stateHistory: [
                    RuntimeHostSessionState.queued.rawValue,
                    RuntimeHostSessionState.bootstrappingPrefix.rawValue,
                    RuntimeHostSessionState.bootingRuntime.rawValue,
                    RuntimeHostSessionState.running.rawValue,
                ],
                environment: request.session.environment,
                telemetrySnapshot: nil,
                mitigationAction: .none
            )
        )
    }

    func lastRequest() async -> RuntimeSessionRequest? {
        await store.get()
    }
}

private actor LaunchOrderingProbe {
    private var snapshotCount = 0
    private var firstExecuteSnapshotCount: Int?

    func recordSnapshot() {
        snapshotCount += 1
    }

    func recordExecute() {
        if firstExecuteSnapshotCount == nil {
            firstExecuteSnapshotCount = snapshotCount
        }
    }

    func snapshotCountAtFirstExecute() -> Int? {
        firstExecuteSnapshotCount
    }
}

private actor CapturedRuntimeSessionRequestStore {
    private var request: RuntimeSessionRequest?

    func set(_ request: RuntimeSessionRequest) {
        self.request = request
    }

    func get() -> RuntimeSessionRequest? {
        request
    }
}

private func waitUntil(
    timeoutMS: UInt64 = 1_000,
    intervalMS: UInt64 = 20,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let iterations = max(1, Int(timeoutMS / intervalMS))
    for _ in 0..<iterations {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return await condition()
}

private func makeHostCapabilities(
    jitStatus: JITStatus = .ready,
    launchReady: Bool?,
    launchStatus: String? = nil,
    launchStatusSummary: String? = nil,
    jitToolRecommendation: JITToolRecommendation? = nil,
    jitToolBootstrapRequired: Bool? = nil,
    jitToolBootstrapKind: String? = nil,
    jitToolBootstrapSummary: String? = nil,
    jitSummary: String? = nil,
    jitSessionKind: JITSessionKind? = nil,
    jitFailureStage: String? = nil,
    constraints: [String] = [],
    presentation: RuntimeSubsystemReadiness?,
    input: RuntimeSubsystemReadiness?,
    audio: RuntimeSubsystemReadiness?
) -> HostCapabilitySnapshot {
    var runtimeBundle = FileSystemRuntimeBundleRegistry.defaultManifest
    runtimeBundle.bundleRootPath = "/tmp/iridium-runtime-base"

    return HostCapabilitySnapshot(
        jitStatus: jitStatus,
        availableManagedStorageGB: 64,
        deviceCapabilityClass: .balanced,
        deviceTier: .tier2,
        thermalState: .nominal,
        lowPowerModeEnabled: false,
        runtimeBundles: [runtimeBundle],
        selectedRuntimeBundle: runtimeBundle,
        constraints: constraints,
        runtimeBridgeAvailable: true,
        executionEnvironment: .nativeRuntime,
        launchReady: launchReady,
        launchStatus: launchStatus ?? (launchReady == true ? "ready" : "bootstrapMissing"),
        launchStatusSummary: launchStatusSummary
            ?? (launchReady == true
                ? "Runtime ready."
                : "Embedded runtime launch support is unavailable in this build."),
        jitSessionKind: jitSessionKind,
        jitFailureStage: jitFailureStage,
        jitToolRecommendation: jitToolRecommendation,
        jitToolBootstrapRequired: jitToolBootstrapRequired,
        jitToolBootstrapKind: jitToolBootstrapKind,
        jitToolBootstrapSummary: jitToolBootstrapSummary,
        jitSummary: jitSummary,
        presentationReadiness: presentation,
        inputReadiness: input,
        audioReadiness: audio
    )
}

private func blockedReadiness(status: String, summary: String) -> RuntimeSubsystemReadiness {
    RuntimeSubsystemReadiness(ready: false, status: status, statusSummary: summary)
}

private func readyReadiness(summary: String) -> RuntimeSubsystemReadiness {
    RuntimeSubsystemReadiness(ready: true, status: "ready", statusSummary: summary)
}
