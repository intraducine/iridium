// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageRoot = URL(filePath: #filePath).deletingLastPathComponent()
let fexForkRoot = packageRoot.appending(path: "../iridium-fex-ios").standardizedFileURL.path
let canonicalFEXLibraries = [
    "iridium-fex-ios-embedded",
    "CommonTools",
    "Common",
    "cpp-optparse",
    "FEXCore",
    "FEXCore_Base",
    "JemallocLibs",
    "fmt",
    "xxhash",
    "rpmalloc",
    "tiny-json",
    "cephes_128bit",
    "softfloat_3e",
]

func linkerFlags(for buildRoot: String) -> [String] {
    let librarySearchPaths = [
        "\(buildRoot)/artifacts",
        "\(buildRoot)/Source/Tools/CommonTools",
        "\(buildRoot)/Source/Common",
        "\(buildRoot)/Source/Common/cpp-optparse",
        "\(buildRoot)/FEXCore/Source",
        "\(buildRoot)/External/fmt",
        "\(buildRoot)/External/xxhash/cmake_unofficial",
        "\(buildRoot)/External/rpmalloc",
        "\(buildRoot)/External/tiny-json",
        "\(buildRoot)/External/cephes",
        "\(buildRoot)/External/SoftFloat-3e",
    ]

    return librarySearchPaths.flatMap { ["-L", $0] } + canonicalFEXLibraries.map { "-l\($0)" }
}

let simulatorFEXBuildRoot = "\(fexForkRoot)/build-iridium-ios-iphonesimulator"

let package = Package(
    name: "Iridium",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "IridiumCore", targets: ["IridiumCore"]),
        .library(name: "IridiumRuntime", targets: ["IridiumRuntime"]),
        .library(name: "IridiumProfiles", targets: ["IridiumProfiles"]),
        .executable(name: "IridiumBridgeHost", targets: ["IridiumBridgeHost"]),
        .executable(name: "IridiumAcceptanceHarness", targets: ["IridiumAcceptanceHarness"]),
    ],
    dependencies: [
        .package(path: "../iridium-runtime-sdk")
    ],
    targets: [
        .target(
            name: "IridiumCore",
            path: "packages/core/Sources/IridiumCore"
        ),
        .testTarget(
            name: "IridiumCoreTests",
            dependencies: ["IridiumCore"],
            path: "packages/core/Tests/IridiumCoreTests"
        ),
        .target(
            name: "IridiumRuntime",
            dependencies: [
                "IridiumCore",
                .product(name: "IridiumRuntimeHostSDK", package: "iridium-runtime-sdk"),
            ],
            path: "packages/runtime/Sources/IridiumRuntime",
            resources: [
                .copy("Resources/BundledRuntime")
            ]
        ),
        .testTarget(
            name: "IridiumRuntimeTests",
            dependencies: ["IridiumRuntime"],
            path: "packages/runtime/Tests/IridiumRuntimeTests",
            linkerSettings: [
                .unsafeFlags(linkerFlags(for: simulatorFEXBuildRoot), .when(platforms: [.iOS]))
            ]
        ),
        .target(
            name: "IridiumAppSupport",
            dependencies: [
                "IridiumCore",
                "IridiumRuntime",
                "IridiumProfiles",
            ],
            path: "apps/ios/Iridium",
            exclude: [
                "Info.plist",
                "IridiumApp.swift",
                "Iridium.entitlements",
                "LaunchScreen.storyboard",
                "RuntimeLogCapture.swift",
                "Views",
            ],
            sources: [
                "AppRuntimeLaunchPhaseTimer.swift",
                "AppRuntimeTestingSupport.swift",
                "AppViewModel.swift",
                "ExternalJITProviders.swift",
                "JITBootstrapAssets.swift",
                "LiveContainerIntegration.swift",
                "ProductExperience.swift",
            ]
        ),
        .testTarget(
            name: "IridiumAppSupportTests",
            dependencies: [
                "IridiumAppSupport",
                "IridiumCore",
                "IridiumRuntime",
            ],
            path: "apps/ios/IridiumAppSupportTests",
            linkerSettings: [
                .unsafeFlags(linkerFlags(for: simulatorFEXBuildRoot), .when(platforms: [.iOS]))
            ]
        ),
        .target(
            name: "IridiumRuntimeLogCapture",
            path: "apps/ios/Iridium",
            exclude: [
                "Info.plist",
                "IridiumApp.swift",
                "Iridium.entitlements",
                "LaunchScreen.storyboard",
                "AppRuntimeLaunchPhaseTimer.swift",
                "AppRuntimeTestingSupport.swift",
                "AppViewModel.swift",
                "ExternalJITProviders.swift",
                "JITBootstrapAssets.swift",
                "LiveContainerIntegration.swift",
                "ProductExperience.swift",
                "Views",
            ],
            sources: ["RuntimeLogCapture.swift"]
        ),
        .testTarget(
            name: "IridiumRuntimeLogCaptureTests",
            dependencies: ["IridiumRuntimeLogCapture"],
            path: "apps/ios/IridiumRuntimeLogCaptureTests"
        ),
        .target(
            name: "IridiumProfiles",
            dependencies: ["IridiumCore"],
            path: "packages/profiles/Sources/IridiumProfiles"
        ),
        .executableTarget(
            name: "IridiumBridgeHost",
            dependencies: ["IridiumRuntime"],
            path: "packages/runtime/BridgeHost"
        ),
        .executableTarget(
            name: "IridiumAcceptanceHarness",
            dependencies: ["IridiumRuntime"],
            path: "packages/runtime/AcceptanceHarness"
        ),
        .testTarget(
            name: "IridiumProfilesTests",
            dependencies: ["IridiumProfiles"],
            path: "packages/profiles/Tests/IridiumProfilesTests"
        ),
    ]
)
