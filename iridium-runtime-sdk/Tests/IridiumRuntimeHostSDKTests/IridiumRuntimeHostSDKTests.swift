import Foundation
import IridiumRuntimeHostSDK
import XCTest

final class IridiumRuntimeHostSDKTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var builtRuntimeHostPath: String {
        let fileManager = FileManager.default
        let candidates = [
            repoRoot.appending(path: ".build/arm64-apple-macosx/debug/runtime-host.bin").path,
            repoRoot.appending(path: ".build/debug/runtime-host.bin").path,
            repoRoot.appending(path: ".build/x86_64-apple-macosx/debug/runtime-host.bin").path,
            repoRoot.appending(path: "build/runtime-host.bin").path,
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate) {
            return candidate
        }

        return candidates[0]
    }

    func testBlockedEntrypointFailsClosedAndWritesHonestCapabilities() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let runtimeHost = bundleRoot.appending(path: "Runtime/runtime-host.bin")
        try FileManager.default.createDirectory(
            at: runtimeHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: builtRuntimeHostPath, toPath: runtimeHost.path)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        let directLaunchProfile = bundleRoot.appending(path: "Metadata/direct-launch.json")
        try FileManager.default.createDirectory(
            at: directLaunchProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "blockedEntryPoints": ["explorer.exe"],
              "directLaunchOnly": true,
              "supportedArchitectures": ["x64"]
            }
            """.utf8
        ).write(to: directLaunchProfile)

        let manifest = bundleRoot.appending(path: "manifest.json")
        try Data(
            """
            {
              "version": "2026.03.20-test"
            }
            """.utf8
        ).write(to: manifest)

        let gameRoot = tempRoot.appending(path: "Game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let executable = gameRoot.appending(path: "explorer.exe")
        try Data("game".utf8).write(to: executable)

        let prefixRoot = tempRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let environmentFile = tempRoot.appending(path: "environment.env")
        try Data(
            """
            WINEPREFIX=\(prefixRoot.path)
            WINEARCH=win64
            IRIDIUM_NO_DESKTOP=1
            IRIDIUM_HOST_JIT_STATUS=required
            """.utf8
        ).write(to: environmentFile)

        let launchPackage = tempRoot.appending(path: "launch-package.json")
        try writeLaunchPackage(
            to: launchPackage,
            id: "blocked-launch",
            title: "Blocked Launch",
            executablePath: executable.path,
            workingDirectory: gameRoot.path,
            runtimeBundleRootPath: bundleRoot.path,
            environmentFilePath: environmentFile.path
        )

        let sessionUpdate = tempRoot.appending(path: "session-update.json")
        let terminalResult = tempRoot.appending(path: "terminal-result.json")
        let telemetry = tempRoot.appending(path: "telemetry.json")
        let hostLog = tempRoot.appending(path: "host.log")

        setenv("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1", 1)
        defer { unsetenv("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY") }

        let result = try runProcess(
            executable: runtimeHost.path,
            arguments: [
                "--launch-package", launchPackage.path,
                "--session-update", sessionUpdate.path,
                "--terminal-result", terminalResult.path,
                "--telemetry", telemetry.path,
                "--host-log", hostLog.path,
            ],
            environment: [
                "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
                "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
                "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionUpdate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminalResult.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: telemetry.path))

        let capabilitiesURL =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]

        XCTAssertEqual(capabilities?["translatorPresent"] as? Bool, true)
        XCTAssertEqual(capabilities?["translatorReady"] as? Bool, false)
        XCTAssertEqual(capabilities?["launchReady"] as? Bool, false)
        XCTAssertEqual(capabilities?["jitStatus"] as? String, "required")
        XCTAssertTrue(capabilities?["deviceCapabilityClass"] is NSNull)
    }

    func testCapabilityRefreshWritesHostCapabilitiesWithoutLaunchPackage() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let managedRoot = tempRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let bundleRoot =
            managedRoot
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        defer { unsetenv("IRIDIUM_HOST_JIT_STATUS") }

        let result = bundleRoot.path.withCString { bundleRootCString -> Int32 in
            var invocation = IridiumRuntimeHostCapabilityRefreshPaths(
                runtime_bundle_root_path: bundleRootCString
            )
            return iridium_runtime_host_refresh_capabilities(&invocation)
        }
        XCTAssertEqual(result, 0)

        let capabilitiesURL = managedRoot.appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]

        XCTAssertEqual(capabilities?["jitStatus"] as? String, "ready")
        XCTAssertEqual(capabilities?["translatorPresent"] as? Bool, true)
        XCTAssertEqual(capabilities?["launchReady"] as? Bool, true)
        XCTAssertEqual(capabilities?["launchStatus"] as? String, "bootstrapReady")
        XCTAssertEqual(
            capabilities?["launchStatusSummary"] as? String,
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        )
        XCTAssertEqual(capabilities?["jitSessionKind"] as? String, "debugger-backed")
        XCTAssertEqual(capabilities?["jitFailureStage"] as? String, nil)
        XCTAssertEqual(capabilities?["jitToolRecommendation"] as? String, "none")
        XCTAssertEqual(capabilities?["jitToolBootstrapRequired"] as? Bool, false)
        XCTAssertEqual(capabilities?["jitToolBootstrapKind"] as? String, nil)
        XCTAssertEqual(capabilities?["jitToolBootstrapSummary"] as? String, nil)
        XCTAssertEqual(
            capabilities?["jitSummary"] as? String,
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        )
        XCTAssertEqual(capabilities?["exceptionPortsActive"] as? Bool, false)
    }

    func testCapabilityRefreshPrefersEmbeddedProbeJITStatusOverReadyHint() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let managedRoot = tempRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let bundleRoot =
            managedRoot
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_FEX_IOS_FORCE_JIT_UNAVAILABLE", "1", 1)
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_FEX_IOS_FORCE_JIT_UNAVAILABLE")
        }

        let result = bundleRoot.path.withCString { bundleRootCString -> Int32 in
            var invocation = IridiumRuntimeHostCapabilityRefreshPaths(
                runtime_bundle_root_path: bundleRootCString
            )
            return iridium_runtime_host_refresh_capabilities(&invocation)
        }
        XCTAssertEqual(result, 0)

        let capabilitiesURL = managedRoot.appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]

        XCTAssertEqual(capabilities?["jitStatus"] as? String, "unavailable")
        XCTAssertEqual(capabilities?["launchReady"] as? Bool, false)
        XCTAssertEqual(capabilities?["launchStatus"] as? String, "jitUnavailable")
        XCTAssertEqual(capabilities?["translatorPresent"] as? Bool, true)
        XCTAssertEqual(capabilities?["translatorReady"] as? Bool, false)
        XCTAssertEqual(capabilities?["jitSessionKind"] as? String, "debugger-backed")
        XCTAssertEqual(
            capabilities?["jitFailureStage"] as? String, "forced unavailable for testing")
        XCTAssertEqual(capabilities?["jitToolRecommendation"] as? String, "stikdebug")
        XCTAssertEqual(capabilities?["jitToolBootstrapRequired"] as? Bool, false)
        XCTAssertEqual(capabilities?["jitToolBootstrapKind"] as? String, nil)
        XCTAssertEqual(capabilities?["jitToolBootstrapSummary"] as? String, nil)
        XCTAssertEqual(
            capabilities?["jitSummary"] as? String,
            "Debugger session detected, but executable code allocation still failed: forced unavailable for testing."
        )
        XCTAssertEqual(capabilities?["exceptionPortsActive"] as? Bool, false)
        XCTAssertEqual(
            capabilities?["launchStatusSummary"] as? String,
            "Debugger session detected, but executable code allocation still failed: forced unavailable for testing."
        )
    }

    func testCapabilityRefreshSurfacesHelperBootstrapMetadata() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let managedRoot = tempRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let bundleRoot =
            managedRoot
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED", "1", 1)
        setenv("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND", "stikdebug-script", 1)
        setenv(
            "IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY",
            "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script.",
            1
        )
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED")
            unsetenv("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND")
            unsetenv("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY")
        }

        let result = bundleRoot.path.withCString { bundleRootCString -> Int32 in
            var invocation = IridiumRuntimeHostCapabilityRefreshPaths(
                runtime_bundle_root_path: bundleRootCString
            )
            return iridium_runtime_host_refresh_capabilities(&invocation)
        }
        XCTAssertEqual(result, 0)

        let capabilitiesURL = managedRoot.appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]

        XCTAssertEqual(capabilities?["jitStatus"] as? String, "unavailable")
        XCTAssertEqual(capabilities?["launchStatus"] as? String, "jitBootstrapRequired")
        XCTAssertEqual(capabilities?["jitToolRecommendation"] as? String, "stikdebug")
        XCTAssertEqual(capabilities?["jitToolBootstrapRequired"] as? Bool, true)
        XCTAssertEqual(capabilities?["jitToolBootstrapKind"] as? String, "stikdebug-script")
        XCTAssertEqual(
            capabilities?["jitToolBootstrapSummary"] as? String,
            "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script."
        )
        XCTAssertEqual(
            capabilities?["launchStatusSummary"] as? String,
            "Debugger-backed helper bootstrap is not available on this host build."
        )
    }

    func testCapabilityRefreshIncludesAllocatorBackendAndSessionDiagnostics() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let managedRoot = tempRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let bundleRoot =
            managedRoot
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        // This covers the debugger-backed skip-execution-probe path, not the physical-device split allocator path.
        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_HOST_INCLUDE_DEBUG_DIAGNOSTICS", "1", 1)
        setenv("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1", 1)
        setenv("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE", "1", 1)
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_HOST_INCLUDE_DEBUG_DIAGNOSTICS")
            unsetenv("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST")
            unsetenv("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE")
        }

        let result = bundleRoot.path.withCString { bundleRootCString -> Int32 in
            var invocation = IridiumRuntimeHostCapabilityRefreshPaths(
                runtime_bundle_root_path: bundleRootCString
            )
            return iridium_runtime_host_refresh_capabilities(&invocation)
        }
        XCTAssertEqual(result, 0)

        let capabilitiesURL = managedRoot.appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]

        XCTAssertEqual(capabilities?["jitStatus"] as? String, "ready")
        XCTAssertEqual(capabilities?["launchStatus"] as? String, "bootstrapReady")
        XCTAssertEqual(
            capabilities?["launchStatusSummary"] as? String,
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        )
        XCTAssertEqual(capabilities?["allocatorBackend"] as? String, "split-rx-rw-debugger")
        XCTAssertEqual(capabilities?["jitSessionKind"] as? String, "debugger-backed")
        XCTAssertEqual(
            capabilities?["jitFailureStage"] as? String,
            "execution probe skipped for debugger-backed session"
        )
        XCTAssertEqual(capabilities?["jitToolRecommendation"] as? String, "none")
        XCTAssertEqual(capabilities?["jitToolBootstrapRequired"] as? Bool, false)
        XCTAssertEqual(
            capabilities?["jitSummary"] as? String,
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        )
        XCTAssertEqual(capabilities?["exceptionPortsActive"] as? Bool, false)
    }

    func testPlayableSessionRegistryDrivesCapabilityRefreshAndLifecycleLogs() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot = try makeCapabilityBundleRoot(at: tempRoot)
        let hostLog = tempRoot.appending(path: "player-session.log")

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1", 1)
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION")
        }

        let acquireResult = "player-session".withCString { sessionID in
            bundleRoot.path.withCString { bundleRootCString in
                hostLog.path.withCString { hostLogCString in
                    var reservation = IridiumRuntimeHostPlayableSessionReservation(
                        session_identifier: sessionID,
                        runtime_bundle_root_path: bundleRootCString,
                        host_log_path: hostLogCString
                    )
                    return iridium_runtime_host_acquire_playable_session(&reservation)
                }
            }
        }
        XCTAssertEqual(acquireResult, 0)

        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            sessionID: "player-session",
            handle: "surface.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            sessionID: "player-session",
            handle: "input.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
            sessionID: "player-session",
            handle: "audio.player"
        )

        let reservedCapabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(
            (reservedCapabilities["presentationReadiness"] as? [String: Any])?["ready"] as? Bool,
            false)
        XCTAssertEqual(
            (reservedCapabilities["inputReadiness"] as? [String: Any])?["ready"] as? Bool, false)
        XCTAssertEqual(
            (reservedCapabilities["audioReadiness"] as? [String: Any])?["ready"] as? Bool, false)

        try setPlayableServiceLiveness(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            sessionID: "player-session",
            isLive: true
        )
        try setPlayableServiceLiveness(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            sessionID: "player-session",
            isLive: true
        )
        try setPlayableServiceLiveness(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
            sessionID: "player-session",
            isLive: true
        )

        let readyCapabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(readyCapabilities["launchReady"] as? Bool, true)
        XCTAssertEqual(
            (readyCapabilities["presentationReadiness"] as? [String: Any])?["ready"] as? Bool, true)
        XCTAssertEqual(
            (readyCapabilities["inputReadiness"] as? [String: Any])?["ready"] as? Bool, true)
        XCTAssertEqual(
            (readyCapabilities["audioReadiness"] as? [String: Any])?["ready"] as? Bool, true)

        try setPlayableServiceLiveness(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
            sessionID: "player-session",
            isLive: false
        )
        let audioBlockedCapabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(
            (audioBlockedCapabilities["audioReadiness"] as? [String: Any])?["ready"] as? Bool, false
        )
        XCTAssertEqual(
            (audioBlockedCapabilities["audioReadiness"] as? [String: Any])?["status"] as? String,
            "audioBridgeMissing"
        )

        let releaseResult = "player-session".withCString { sessionID in
            iridium_runtime_host_release_playable_session(sessionID)
        }
        XCTAssertEqual(releaseResult, 0)

        let releasedCapabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(
            (releasedCapabilities["presentationReadiness"] as? [String: Any])?["status"] as? String,
            "presentationServiceMissing"
        )

        let logContents = try String(contentsOf: hostLog, encoding: .utf8)
        XCTAssertTrue(logContents.contains("session-acquired id=player-session"))
        XCTAssertTrue(
            logContents.contains(
                "render-service-registered session=player-session handle=surface.player"))
        XCTAssertTrue(
            logContents.contains(
                "input-service-registered session=player-session handle=input.player"))
        XCTAssertTrue(
            logContents.contains(
                "audio-service-registered session=player-session handle=audio.player"))
        XCTAssertTrue(
            logContents.contains(
                "service-live session=player-session kind=render handle=surface.player"))
        XCTAssertTrue(
            logContents.contains(
                "service-live session=player-session kind=input handle=input.player"))
        XCTAssertTrue(
            logContents.contains(
                "service-live session=player-session kind=audio handle=audio.player"))
        XCTAssertTrue(
            logContents.contains("service-liveness-failure session=player-session kind=audio"))
        XCTAssertTrue(logContents.contains("guest-stop-request-failed id=player-session"))
        XCTAssertTrue(logContents.contains("session-released id=player-session"))
    }

    func testPlayableSessionRegistryBlocksPresentationWithoutGraphicsBackendContract() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot = try makeCapabilityBundleRoot(
            at: tempRoot,
            includePresentationBackendContract: false
        )
        let hostLog = tempRoot.appending(path: "player-session.log")

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1", 1)
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION")
        }

        let acquireResult = "player-session".withCString { sessionID in
            bundleRoot.path.withCString { bundleRootCString in
                hostLog.path.withCString { hostLogCString in
                    var reservation = IridiumRuntimeHostPlayableSessionReservation(
                        session_identifier: sessionID,
                        runtime_bundle_root_path: bundleRootCString,
                        host_log_path: hostLogCString
                    )
                    return iridium_runtime_host_acquire_playable_session(&reservation)
                }
            }
        }
        XCTAssertEqual(acquireResult, 0)

        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            sessionID: "player-session",
            handle: "surface.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            sessionID: "player-session",
            handle: "input.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
            sessionID: "player-session",
            handle: "audio.player"
        )

        for service in [
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
        ] {
            try setPlayableServiceLiveness(
                service,
                sessionID: "player-session",
                isLive: true
            )
        }

        let capabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(capabilities["launchReady"] as? Bool, true)
        XCTAssertEqual(
            (capabilities["presentationReadiness"] as? [String: Any])?["ready"] as? Bool,
            false)
        XCTAssertEqual(
            (capabilities["presentationReadiness"] as? [String: Any])?["status"] as? String,
            "graphicsBackendMissing")
        XCTAssertTrue(
            ((capabilities["presentationReadiness"] as? [String: Any])?["statusSummary"] as? String)?
                .contains("does not include an iOS Wine graphics backend contract") == true
        )
        XCTAssertEqual(
            (capabilities["inputReadiness"] as? [String: Any])?["ready"] as? Bool,
            true)
        XCTAssertEqual(
            (capabilities["audioReadiness"] as? [String: Any])?["ready"] as? Bool,
            true)

        let releaseResult = "player-session".withCString { sessionID in
            iridium_runtime_host_release_playable_session(sessionID)
        }
        XCTAssertEqual(releaseResult, 0)
    }

    func testPlayableSessionRegistryBlocksPresentationWithoutOpenGLBackendPayload() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot = try makeCapabilityBundleRoot(
            at: tempRoot,
            includePresentationBackendContract: true,
            includeOpenGLBackendPayload: false
        )
        let hostLog = tempRoot.appending(path: "player-session.log")

        setenv("IRIDIUM_HOST_JIT_STATUS", "ready", 1)
        setenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1", 1)
        defer {
            unsetenv("IRIDIUM_HOST_JIT_STATUS")
            unsetenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION")
        }

        let acquireResult = "player-session".withCString { sessionID in
            bundleRoot.path.withCString { bundleRootCString in
                hostLog.path.withCString { hostLogCString in
                    var reservation = IridiumRuntimeHostPlayableSessionReservation(
                        session_identifier: sessionID,
                        runtime_bundle_root_path: bundleRootCString,
                        host_log_path: hostLogCString
                    )
                    return iridium_runtime_host_acquire_playable_session(&reservation)
                }
            }
        }
        XCTAssertEqual(acquireResult, 0)

        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            sessionID: "player-session",
            handle: "surface.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            sessionID: "player-session",
            handle: "input.player"
        )
        try registerPlayableService(
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
            sessionID: "player-session",
            handle: "audio.player"
        )

        for service in [
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER,
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT,
            IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO,
        ] {
            try setPlayableServiceLiveness(
                service,
                sessionID: "player-session",
                isLive: true
            )
        }

        let capabilities = try loadCapabilities(from: tempRoot)
        XCTAssertEqual(
            (capabilities["presentationReadiness"] as? [String: Any])?["ready"] as? Bool,
            false)
        XCTAssertEqual(
            (capabilities["presentationReadiness"] as? [String: Any])?["status"] as? String,
            "graphicsBackendMissing")
        XCTAssertTrue(
            ((capabilities["presentationReadiness"] as? [String: Any])?["statusSummary"] as? String)?
                .contains("does not include a staged Wine userland OpenGL backend") == true
        )

        let releaseResult = "player-session".withCString { sessionID in
            iridium_runtime_host_release_playable_session(sessionID)
        }
        XCTAssertEqual(releaseResult, 0)
    }

    func testPlayableSessionRegistryRejectsSecondActiveSession() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot = try makeCapabilityBundleRoot(at: tempRoot)

        let firstAcquire = "primary-session".withCString { primarySessionID in
            bundleRoot.path.withCString { bundleRootCString in
                var reservation = IridiumRuntimeHostPlayableSessionReservation(
                    session_identifier: primarySessionID,
                    runtime_bundle_root_path: bundleRootCString,
                    host_log_path: nil
                )
                return iridium_runtime_host_acquire_playable_session(&reservation)
            }
        }
        XCTAssertEqual(firstAcquire, 0)

        let secondAcquire = "secondary-session".withCString { secondarySessionID in
            bundleRoot.path.withCString { bundleRootCString in
                var reservation = IridiumRuntimeHostPlayableSessionReservation(
                    session_identifier: secondarySessionID,
                    runtime_bundle_root_path: bundleRootCString,
                    host_log_path: nil
                )
                return iridium_runtime_host_acquire_playable_session(&reservation)
            }
        }
        XCTAssertEqual(secondAcquire, 65)

        let releaseResult = "primary-session".withCString { sessionID in
            iridium_runtime_host_release_playable_session(sessionID)
        }
        XCTAssertEqual(releaseResult, 0)
    }

    func testEmbeddedRuntimeHostCompletesDirectLaunchPath() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let runtimeHost = bundleRoot.appending(path: "Runtime/runtime-host.bin")
        try FileManager.default.createDirectory(
            at: runtimeHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: builtRuntimeHostPath, toPath: runtimeHost.path)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        let directLaunchProfile = bundleRoot.appending(path: "Metadata/direct-launch.json")
        try FileManager.default.createDirectory(
            at: directLaunchProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "blockedEntryPoints": ["explorer.exe"],
              "directLaunchOnly": true,
              "supportedArchitectures": ["x64"]
            }
            """.utf8
        ).write(to: directLaunchProfile)

        let manifest = bundleRoot.appending(path: "manifest.json")
        try Data(
            """
            {
              "version": "2026.03.27-test"
            }
            """.utf8
        ).write(to: manifest)

        try writeLaunchableUserlandRoot(
            at: bundleRoot.appending(path: "Support/wine-userland", directoryHint: .isDirectory))

        let gameRoot = tempRoot.appending(path: "Game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let executable = gameRoot.appending(path: "SampleGame.exe")
        try Data("game".utf8).write(to: executable)

        let prefixRoot = tempRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let environmentFile = tempRoot.appending(path: "environment.env")
        try Data(
            """
            WINEPREFIX=\(prefixRoot.path)
            WINEARCH=win64
            IRIDIUM_NO_DESKTOP=1
            IRIDIUM_HOST_JIT_STATUS=ready
            """.utf8
        ).write(to: environmentFile)

        let launchPackage = tempRoot.appending(path: "launch-package.json")
        try writeLaunchPackage(
            to: launchPackage,
            id: "successful-launch",
            title: "Successful Launch",
            executablePath: executable.path,
            workingDirectory: gameRoot.path,
            runtimeBundleRootPath: bundleRoot.path,
            environmentFilePath: environmentFile.path
        )

        let sessionUpdate = tempRoot.appending(path: "session-update.json")
        let terminalResult = tempRoot.appending(path: "terminal-result.json")
        let telemetry = tempRoot.appending(path: "telemetry.json")
        let hostLog = tempRoot.appending(path: "host.log")

        let result = try runProcess(
            executable: runtimeHost.path,
            arguments: [
                "--launch-package", launchPackage.path,
                "--session-update", sessionUpdate.path,
                "--terminal-result", terminalResult.path,
                "--telemetry", telemetry.path,
                "--host-log", hostLog.path,
            ],
            environment: [
                "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
                "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
                "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
            ]
        )

        guard result.exitCode == 0 else {
            XCTFail(
                "runtime-host exited with \(result.exitCode)\nstderr:\n\(result.stderr)\nstdout:\n\(result.stdout)"
            )
            return
        }

        let sessionData = try Data(contentsOf: sessionUpdate)
        let sessionPayload = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
        XCTAssertEqual(sessionPayload?["state"] as? String, "running")

        let terminalData = try Data(contentsOf: terminalResult)
        let terminalPayload = try JSONSerialization.jsonObject(with: terminalData) as? [String: Any]
        XCTAssertEqual(terminalPayload?["terminalStatus"] as? String, "completed")
        XCTAssertTrue(terminalPayload?["failureCode"] is NSNull)

        let capabilitiesURL =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "host-capabilities.json")
        let capabilitiesData = try Data(contentsOf: capabilitiesURL)
        let capabilities =
            try JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any]
        XCTAssertEqual(capabilities?["launchReady"] as? Bool, true)

        // This covers the smoke/assume-bootstrap-ready ready path, not the physical-device bootstrap flow.
        let hostLogText = try String(contentsOf: hostLog, encoding: .utf8)
        XCTAssertTrue(hostLogText.contains("jit-status=ready"), hostLogText)
        XCTAssertTrue(hostLogText.contains("jit-backend=none"), hostLogText)
        XCTAssertTrue(hostLogText.contains("jit-session-kind=debugger-backed"), hostLogText)
        XCTAssertTrue(hostLogText.contains("jit-failure-stage=none"), hostLogText)
        XCTAssertTrue(hostLogText.contains("jit-tool-recommendation=none"), hostLogText)
        XCTAssertTrue(hostLogText.contains("jit-tool-bootstrap-required=false"), hostLogText)
        XCTAssertTrue(hostLogText.contains("exception-ports-active=false"), hostLogText)
        XCTAssertTrue(
            hostLogText.contains(
                "jit-summary=JIT is attached and the embedded bootstrap is ready; runtime milestones are pending."
            ),
            hostLogText
        )
    }

    func testEmbeddedRuntimeHostSmokeLaunchWritesLifecycleFiles() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundleRoot =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let runtimeHost = bundleRoot.appending(path: "Runtime/runtime-host.bin")
        try FileManager.default.createDirectory(
            at: runtimeHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: builtRuntimeHostPath, toPath: runtimeHost.path)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        let directLaunchProfile = bundleRoot.appending(path: "Metadata/direct-launch.json")
        try FileManager.default.createDirectory(
            at: directLaunchProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "blockedEntryPoints": ["explorer.exe"],
              "directLaunchOnly": true,
              "supportedArchitectures": ["x64"]
            }
            """.utf8
        ).write(to: directLaunchProfile)

        let manifest = bundleRoot.appending(path: "manifest.json")
        try Data(
            """
            {
              "version": "2026.03.27-test"
            }
            """.utf8
        ).write(to: manifest)

        try writeLaunchableUserlandRoot(
            at: bundleRoot.appending(path: "Support/wine-userland", directoryHint: .isDirectory))

        let gameRoot = tempRoot.appending(path: "Game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let executable = gameRoot.appending(path: "SampleGame.exe")
        try Data("game".utf8).write(to: executable)

        let prefixRoot = tempRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let environmentFile = tempRoot.appending(path: "environment.env")
        try Data(
            """
            WINEPREFIX=\(prefixRoot.path)
            WINEARCH=win64
            IRIDIUM_NO_DESKTOP=1
            IRIDIUM_HOST_JIT_STATUS=ready
            """.utf8
        ).write(to: environmentFile)

        let launchPackage = tempRoot.appending(path: "launch-package.json")
        try writeLaunchPackage(
            to: launchPackage,
            id: "smoke-launch",
            title: "Smoke Launch",
            executablePath: executable.path,
            workingDirectory: gameRoot.path,
            runtimeBundleRootPath: bundleRoot.path,
            environmentFilePath: environmentFile.path
        )

        let sessionUpdate = tempRoot.appending(path: "session-update.json")
        let terminalResult = tempRoot.appending(path: "terminal-result.json")
        let telemetry = tempRoot.appending(path: "telemetry.json")
        let hostLog = tempRoot.appending(path: "host.log")

        let result = try runProcess(
            executable: runtimeHost.path,
            arguments: [
                "--launch-package", launchPackage.path,
                "--session-update", sessionUpdate.path,
                "--terminal-result", terminalResult.path,
                "--telemetry", telemetry.path,
                "--host-log", hostLog.path,
            ],
            environment: [
                "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
                "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
                "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: telemetry.path))

        let sessionData = try Data(contentsOf: sessionUpdate)
        let sessionPayload = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
        XCTAssertEqual(sessionPayload?["state"] as? String, "running")
        XCTAssertEqual(sessionPayload?["failureCode"] as? String, nil)
        XCTAssertEqual(sessionPayload?["failureReason"] as? String, nil)

        let terminalData = try Data(contentsOf: terminalResult)
        let terminalPayload = try JSONSerialization.jsonObject(with: terminalData) as? [String: Any]
        XCTAssertEqual(terminalPayload?["terminalStatus"] as? String, "completed")
        XCTAssertEqual(terminalPayload?["failureCode"] as? String, nil)
        XCTAssertEqual(terminalPayload?["failureReason"] as? String, nil)
    }

    func testEmbeddedRuntimeHostDoesNotReportRunningBeforeEmbeddedGuestExecutionStarts() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fixture = try makeEmbeddedRuntimeHostDirectLaunchFixture(
            in: tempRoot,
            id: "handoff-gated-launch",
            title: "Handoff Gated Launch"
        )
        let sessionUpdate = tempRoot.appending(path: "session-update.json")
        let terminalResult = tempRoot.appending(path: "terminal-result.json")
        let telemetry = tempRoot.appending(path: "telemetry.json")
        let hostLog = tempRoot.appending(path: "host.log")

        let process = Process()
        process.executableURL = fixture.runtimeHost
        process.arguments = [
            "--launch-package", fixture.launchPackage.path,
            "--session-update", sessionUpdate.path,
            "--terminal-result", terminalResult.path,
            "--telemetry", telemetry.path,
            "--host-log", hostLog.path,
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["IRIDIUM_TEST_HARNESS": "1"]) { _, new in new }
            .merging([
                "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
                "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
                "IRIDIUM_FEX_IOS_TEST_INITIALIZATION_HOLD_MS": "900",
            ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        var observedStates: [String] = []
        var observedPrematureRunning = false
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            if let state = try readSessionStateIfPresent(at: sessionUpdate),
               observedStates.last != state
            {
                observedStates.append(state)
                if state == "running" {
                    observedPrematureRunning = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        process.waitUntilExit()
        let stdout =
            String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let stderr =
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""

        XCTAssertFalse(
            observedPrematureRunning,
            "runtime-host reported running before embedded guest execution started; observed states: \(observedStates)"
        )
        XCTAssertFalse(observedStates.isEmpty, "expected at least one session update before terminal exit")
        _ = stdout
        _ = stderr
    }

    func testEmbeddedRuntimeHostDoesNotContainPreMonitorRunningHandoff() throws {
        let source = try String(
            contentsOf: repoRoot.appending(path: "src/runtime_host_core.cpp"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("Embedded Wine/FEX runtime entered shell-free execution."),
            "runtime-host must not publish running before monitor_embedded_execution_until_terminal observes embedded execution"
        )
        XCTAssertFalse(
            source.contains("const std::vector<std::string> running_history"),
            "runtime-host should derive running history from embedded poll states, not an unconditional pre-monitor update"
        )
    }

    func testPackagerSmokeCheckAcceptsStructurallyValidBundle() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(at: userland, includeWineServer: true, includePrefixSeed: true)

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputRoot.appending(path: "manifest.json").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputRoot.appending(path: "Runtime/runtime-host.bin").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputRoot.appending(path: "Graphics/ios-presentation-backend.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputRoot.appending(path: "Userland/extracted").path),
            "Smoke validation must not leak an extracted Wine tree into the packaged bundle"
        )
    }

    func testPackagerSmokeCheckRejectsArchiveMissingWineServer() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(at: userland, includeWineServer: false, includePrefixSeed: true)

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("bin/wineserver"), result.stderr)
    }

    func testPackagerSmokeCheckRejectsArchiveMissingWineIOSDriver() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            includeWineIOSDriver: false
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("wineios.drv Unix driver"), result.stderr)
    }

    func testPackagerSmokeCheckRejectsArchiveMissingOpenGLBackend() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            includeOpenGLBackend: false
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("Wine OpenGL backend"), result.stderr)
    }

    func testPackagerSmokeCheckRejectsArchiveMissingPrefixSeed() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(at: userland, includeWineServer: true, includePrefixSeed: false)

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("prefix-seed"), result.stderr)
    }

    func testPackagerSmokeCheckRejectsArchiveWithoutEmbeddedGuestWineLoader() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            wineBinaryData: fakeMachOBinaryData()
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.contains("embedded-FEX-compatible x86_64 ELF Wine loader"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Mach-O"), result.stderr)
    }

    func testPackagerSmokeCheckRejectsArchiveWithPTInterpWineLoaderOnly() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            wineBinaryData: fakeMachOBinaryData(),
            unixWineBinaryData: fakeX8664ELFDataWithProgramInterpreter()
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("without PT_INTERP"), result.stderr)
        XCTAssertTrue(result.stderr.contains("PT_INTERP"), result.stderr)
        XCTAssertTrue(result.stderr.contains("lib/wine/x86_64-unix/wine"), result.stderr)
    }

    func testPackagerSmokeCheckAcceptsArchiveWithWinePreloaderWhenWineHasPTInterp() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            wineBinaryData: fakeMachOBinaryData(),
            unixWineBinaryData: fakeX8664ELFDataWithProgramInterpreter(),
            winePreloaderData: fakeX8664ELFData(),
            elfInterpreterData: fakeX8664ELFData()
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputRoot.appending(path: "Userland/wine-userland.tar.zst").path)
        )
    }

    func testPackagerSmokeCheckRejectsWinePreloaderWithoutCompanionUnixWineBinary() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            wineBinaryData: fakeMachOBinaryData(),
            winePreloaderData: fakeX8664ELFData()
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.contains("wine-preloader requires a sibling Unix Wine loader"),
            result.stderr)
    }

    func testPackagerSmokeCheckRejectsWinePreloaderWhenCompanionInterpreterIsMissing() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(
            at: userland,
            includeWineServer: true,
            includePrefixSeed: true,
            wineBinaryData: fakeMachOBinaryData(),
            unixWineBinaryData: fakeX8664ELFDataWithProgramInterpreter(),
            winePreloaderData: fakeX8664ELFData()
        )

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
                "--smoke-check",
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.contains("PT_INTERP ELF interpreter"),
            result.stderr)
    }

    func testBuildRuntimeBundleScriptValidatesForkRootsWithoutLegacyUserlandSourceRoot() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let result = try runProcess(
            executable: "/bin/zsh",
            arguments: [
                repoRoot.appending(path: "scripts/build_runtime_bundle.sh").path,
                "--bundle-version", "2026.03.20-test",
                "--output-root", tempRoot.appending(path: "bundle").path,
                "--build-from-forks",
                "--fex-fork-root", tempRoot.appending(path: "fex-fork").path,
                "--wine-fork-root", tempRoot.appending(path: "wine-fork").path,
            ]
        )

        XCTAssertEqual(result.exitCode, 66, result.stderr)
        XCTAssertTrue(result.stderr.contains("fex fork root does not exist"), result.stderr)
    }

    func testPackagerRejectsEmptyBundleIDAsMalformedMetadata() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let translator = tempRoot.appending(path: "translator.bin")
        try Data("translator".utf8).write(to: translator)

        let userland = tempRoot.appending(path: "wine-userland.tar.zst")
        try makeUserlandArchive(at: userland, includeWineServer: true, includePrefixSeed: true)

        let outputRoot = tempRoot.appending(path: "bundle", directoryHint: .isDirectory)
        let result = try runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                repoRoot.appending(path: "scripts/package_runtime_bundle.py").path,
                "--bundle-id", "",
                "--bundle-version", "2026.03.20-test",
                "--runtime-host", builtRuntimeHostPath,
                "--translator", translator.path,
                "--userland", userland.path,
                "--graphics-config",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
                ).path,
                "--direct-launch-profile",
                repoRoot.appending(
                    path: "samples/runtime-bundle-template/Metadata/direct-launch.json"
                ).path,
                "--output-root", outputRoot.path,
            ]
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("bundle id"), result.stderr)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct EmbeddedRuntimeHostDirectLaunchFixture {
        let runtimeHost: URL
        let launchPackage: URL
    }

    private func makeEmbeddedRuntimeHostDirectLaunchFixture(
        in tempRoot: URL,
        id: String,
        title: String
    ) throws -> EmbeddedRuntimeHostDirectLaunchFixture {
        let bundleRoot =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let runtimeHost = bundleRoot.appending(path: "Runtime/runtime-host.bin")
        try FileManager.default.createDirectory(
            at: runtimeHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: builtRuntimeHostPath, toPath: runtimeHost.path)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("translator".utf8).write(to: translator)

        let directLaunchProfile = bundleRoot.appending(path: "Metadata/direct-launch.json")
        try FileManager.default.createDirectory(
            at: directLaunchProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "blockedEntryPoints": ["explorer.exe"],
              "directLaunchOnly": true,
              "supportedArchitectures": ["x64"]
            }
            """.utf8
        ).write(to: directLaunchProfile)

        let manifest = bundleRoot.appending(path: "manifest.json")
        try Data(
            """
            {
              "version": "2026.03.27-test"
            }
            """.utf8
        ).write(to: manifest)

        try writeLaunchableUserlandRoot(
            at: bundleRoot.appending(path: "Support/wine-userland", directoryHint: .isDirectory))

        let gameRoot = tempRoot.appending(path: "Game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let executable = gameRoot.appending(path: "SampleGame.exe")
        try Data("game".utf8).write(to: executable)

        let prefixRoot = tempRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let environmentFile = tempRoot.appending(path: "environment.env")
        try Data(
            """
            WINEPREFIX=\(prefixRoot.path)
            WINEARCH=win64
            IRIDIUM_NO_DESKTOP=1
            IRIDIUM_HOST_JIT_STATUS=ready
            """.utf8
        ).write(to: environmentFile)

        let launchPackage = tempRoot.appending(path: "launch-package.json")
        try writeLaunchPackage(
            to: launchPackage,
            id: id,
            title: title,
            executablePath: executable.path,
            workingDirectory: gameRoot.path,
            runtimeBundleRootPath: bundleRoot.path,
            environmentFilePath: environmentFile.path
        )

        return EmbeddedRuntimeHostDirectLaunchFixture(
            runtimeHost: runtimeHost,
            launchPackage: launchPackage
        )
    }

    private func readSessionStateIfPresent(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?["state"] as? String
    }

    private func makeCapabilityBundleRoot(
        at tempRoot: URL,
        includePresentationBackendContract: Bool = true,
        includeOpenGLBackendPayload: Bool = true
    ) throws -> URL {
        let managedRoot = tempRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let bundleRoot =
            managedRoot
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "iridium-runtime-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let translator = bundleRoot.appending(path: "Translator/x64-jit.bin")
        try FileManager.default.createDirectory(
            at: translator.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("translator".utf8).write(to: translator)

        if includePresentationBackendContract {
            let contract = bundleRoot.appending(path: "Graphics/ios-presentation-backend.json")
            try FileManager.default.createDirectory(
                at: contract.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                {
                  "presentable": true,
                  "supportedGraphicsAPIs": ["opengl"]
                }
                """.utf8
            ).write(to: contract)
        }
        if includeOpenGLBackendPayload {
            let unixWineRoot = bundleRoot.appending(
                path: "Support/wine-userland/lib/wine/x86_64-unix",
                directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: unixWineRoot,
                withIntermediateDirectories: true
            )
            try Data("wineios".utf8).write(to: unixWineRoot.appending(path: "wineios.so"))
            try Data("ELF egl_handle eglGetProcAddress".utf8).write(
                to: unixWineRoot.appending(path: "opengl32.so"))
            try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
                to: unixWineRoot.appending(path: "win32u.so"))
        }
        return bundleRoot
    }

    private func loadCapabilities(from tempRoot: URL) throws -> [String: Any] {
        let capabilitiesURL =
            tempRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "host-capabilities.json")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: capabilitiesURL))
                as? [String: Any]
        )
    }

    private func registerPlayableService(
        _ serviceKind: IridiumRuntimeHostPlayableServiceKind,
        sessionID: String,
        handle: String
    ) throws {
        let result = sessionID.withCString { sessionIDCString in
            handle.withCString { handleCString in
                var registration = IridiumRuntimeHostPlayableServiceRegistration(
                    session_identifier: sessionIDCString,
                    service_kind: serviceKind,
                    service_handle: handleCString,
                    service_metadata: nil
                )
                return iridium_runtime_host_register_playable_service(&registration)
            }
        }
        XCTAssertEqual(result, 0)
    }

    private func setPlayableServiceLiveness(
        _ serviceKind: IridiumRuntimeHostPlayableServiceKind,
        sessionID: String,
        isLive: Bool
    ) throws {
        let result = sessionID.withCString { sessionIDCString in
            var liveness = IridiumRuntimeHostPlayableServiceLiveness(
                session_identifier: sessionIDCString,
                service_kind: serviceKind,
                service_live: isLive ? 1 : 0
            )
            return iridium_runtime_host_set_playable_service_liveness(&liveness)
        }
        XCTAssertEqual(result, 0)
    }

    private func unregisterPlayableService(
        _ serviceKind: IridiumRuntimeHostPlayableServiceKind,
        sessionID: String
    ) throws -> Int32 {
        sessionID.withCString { sessionIDCString in
            var registration = IridiumRuntimeHostPlayableServiceRegistration(
                session_identifier: sessionIDCString,
                service_kind: serviceKind,
                service_handle: nil,
                service_metadata: nil
            )
            return iridium_runtime_host_unregister_playable_service(&registration)
        }
    }

    private func writeLaunchPackage(
        to url: URL,
        id: String,
        title: String,
        executablePath: String,
        workingDirectory: String,
        runtimeBundleRootPath: String,
        environmentFilePath: String
    ) throws {
        let payload: [String: Any] = [
            "id": id,
            "gameTitle": title,
            "executablePath": executablePath,
            "workingDirectory": workingDirectory,
            "runtimeBundleRootPath": runtimeBundleRootPath,
            "environmentFilePath": environmentFilePath,
            "directLaunchOnly": true,
            "launchArguments": [],
            "environment": [:],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func makeUserlandArchive(
        at destination: URL,
        includeWineServer: Bool,
        includePrefixSeed: Bool,
        includeWineIOSDriver: Bool = true,
        includeOpenGLBackend: Bool = true,
        wineBinaryData: Data? = nil,
        unixWineBinaryData: Data? = nil,
        winePreloaderData: Data? = nil,
        elfInterpreterData: Data? = nil
    ) throws {
        let stagingRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let requiredDirectories = [
            stagingRoot.appending(path: "bin", directoryHint: .isDirectory),
            stagingRoot.appending(path: "lib/wine", directoryHint: .isDirectory),
            stagingRoot.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory),
            stagingRoot.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory),
            stagingRoot.appending(path: "share/wine", directoryHint: .isDirectory),
            stagingRoot.appending(path: "share/wine/nls", directoryHint: .isDirectory),
        ]
        for directory in requiredDirectories {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        if includePrefixSeed {
            let prefixSeed = stagingRoot.appending(path: "prefix-seed", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: prefixSeed, withIntermediateDirectories: true)
            try Data("system".utf8).write(to: prefixSeed.appending(path: "system.reg"))
            try Data("user".utf8).write(to: prefixSeed.appending(path: "user.reg"))
            try Data("userdef".utf8).write(to: prefixSeed.appending(path: "userdef.reg"))
        }

        try (wineBinaryData ?? fakeX8664ELFData()).write(
            to: stagingRoot.appending(path: "bin/wine64"))
        if let unixWineBinaryData {
            try unixWineBinaryData.write(
                to: stagingRoot.appending(path: "lib/wine/x86_64-unix/wine"))
        }
        if let winePreloaderData {
            try winePreloaderData.write(
                to: stagingRoot.appending(path: "lib/wine/x86_64-unix/wine-preloader"))
        }
        if let elfInterpreterData {
            let interpreter = stagingRoot.appending(path: "lib64/ld-linux-x86-64.so.2")
            try FileManager.default.createDirectory(
                at: interpreter.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try elfInterpreterData.write(to: interpreter)
        }
        if includeWineServer {
            try Data("wineserver".utf8).write(to: stagingRoot.appending(path: "bin/wineserver"))
        }
        if includeWineIOSDriver {
            try Data("wineios".utf8).write(
                to: stagingRoot.appending(path: "lib/wine/x86_64-unix/wineios.so"))
        }
        if includeOpenGLBackend {
            try Data("ELF egl_handle eglGetProcAddress".utf8).write(
                to: stagingRoot.appending(path: "lib/wine/x86_64-unix/opengl32.so"))
            try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
                to: stagingRoot.appending(path: "lib/wine/x86_64-unix/win32u.so"))
        }
        try Data("dll".utf8).write(to: stagingRoot.appending(path: "lib/wine/x86_64-windows/kernel32.dll"))
        try Data("dll".utf8).write(to: stagingRoot.appending(path: "lib/wine/x86_64-windows/kernelbase.dll"))
        try Data("share".utf8).write(to: stagingRoot.appending(path: "share/wine/readme.txt"))
        try Data("intl".utf8).write(to: stagingRoot.appending(path: "share/wine/nls/l_intl.nls"))

        let result = try runProcess(
            executable: "/usr/bin/tar",
            arguments: ["-cf", destination.path, "-C", stagingRoot.path, "."]
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private func writeLaunchableUserlandRoot(at root: URL) throws {
        let directories = [
            root.appending(path: "bin", directoryHint: .isDirectory),
            root.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory),
            root.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory),
            root.appending(path: "share/wine", directoryHint: .isDirectory),
            root.appending(path: "share/wine/nls", directoryHint: .isDirectory),
            root.appending(path: "prefix-seed", directoryHint: .isDirectory),
        ]
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        let wine64URL = root.appending(path: "bin/wine64")
        try writeExecutableScript(
            "#!/bin/zsh\nexit 0\n",
            to: wine64URL
        )
        try fakeX8664ELFData().write(
            to: root.appending(path: "lib/wine/x86_64-unix/wine"),
            options: .atomic
        )
        try writeExecutableScript(
            "#!/bin/zsh\nexit 0\n",
            to: root.appending(path: "bin/wineserver")
        )

        try Data("dll".utf8).write(to: root.appending(path: "lib/wine/x86_64-windows/kernel32.dll"))
        try Data("dll".utf8).write(to: root.appending(path: "lib/wine/x86_64-windows/kernelbase.dll"))
        try Data("share".utf8).write(to: root.appending(path: "share/wine/readme.txt"))
        try Data("intl".utf8).write(to: root.appending(path: "share/wine/nls/l_intl.nls"))

        let prefixSeedPayload = "WINE REGISTRY Version 2\n#arch=win64\n"
        try Data(prefixSeedPayload.utf8).write(to: root.appending(path: "prefix-seed/system.reg"))
        try Data(prefixSeedPayload.utf8).write(to: root.appending(path: "prefix-seed/user.reg"))
        try Data(prefixSeedPayload.utf8).write(to: root.appending(path: "prefix-seed/userdef.reg"))
    }

    private func writeExecutableScript(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fakeX8664ELFData() -> Data {
        var bytes = Array(repeating: UInt8(0), count: 64)
        bytes[0] = 0x7f
        bytes[1] = 0x45
        bytes[2] = 0x4c
        bytes[3] = 0x46
        bytes[4] = 0x02
        bytes[5] = 0x01
        bytes[18] = 0x3e
        bytes[19] = 0x00
        return Data(bytes)
    }

    private func fakeX8664ELFDataWithProgramInterpreter() -> Data {
        let interpreter = Array("/lib64/ld-linux-x86-64.so.2\0".utf8)
        var bytes = Array(repeating: UInt8(0), count: 160)
        bytes[0] = 0x7f
        bytes[1] = 0x45
        bytes[2] = 0x4c
        bytes[3] = 0x46
        bytes[4] = 0x02
        bytes[5] = 0x01
        bytes[16] = 0x02
        bytes[18] = 0x3e
        bytes[32] = 0x40
        bytes[52] = 0x40
        bytes[54] = 0x38
        bytes[56] = 0x01
        bytes[64] = 0x03
        bytes[72] = 0x80
        bytes[96] = UInt8(interpreter.count)
        bytes[104] = UInt8(interpreter.count)
        for (index, byte) in interpreter.enumerated() {
            bytes[128 + index] = byte
        }
        return Data(bytes)
    }

    private func fakeMachOBinaryData() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["IRIDIUM_TEST_HARNESS": "1"]) { _, new in new }
            .merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout =
            String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let stderr =
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
