// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageRoot = URL(filePath: #filePath).deletingLastPathComponent()

let sharedExcludes = [
    ".gitignore",
    "CMakeLists.txt",
    "README.md",
    "build",
    "docs",
    "samples",
    "scripts",
    "upstream",
].filter { FileManager.default.fileExists(atPath: packageRoot.appending(path: $0).path) }

let fexForkRoot =
    packageRoot
    .appending(path: "../iridium-fex-ios")
    .standardizedFileURL
    .path
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

enum AppleBuildPlatform: String {
    case host
    case device
    case simulator

    var buildRootName: String {
        switch self {
        case .host:
            return "build-iridium-ios-host"
        case .device:
            return "build-iridium-ios-iphoneos"
        case .simulator:
            return "build-iridium-ios-iphonesimulator"
        }
    }

    var rebuildArgument: String {
        rawValue
    }
}

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

func manifestValue(named key: String, in contents: String) -> String? {
    contents
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> String? in
            let line = String(line)
            guard line.hasPrefix("\(key)=") else {
                return nil
            }
            return String(line.dropFirst(key.count + 1))
        }
        .first
}

func hasValidManifest(at buildRoot: String, expectedPlatform: AppleBuildPlatform) -> Bool {
    let manifestURL = URL(filePath: buildRoot).appending(path: "iridium-ios-embedded-artifact.txt")
    guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
        return false
    }

    return manifestValue(named: "PLATFORM", in: contents) == expectedPlatform.rawValue
}

let hostBuildRoot = "\(fexForkRoot)/build-iridium-ios-host"
let hostFEXAvailable = hasValidManifest(at: hostBuildRoot, expectedPlatform: .host)

var sharedSettings: [CXXSetting] = [
    .headerSearchPath("include"),
    .headerSearchPath("include/public"),
    .define("IRIDIUM_RUNTIME_HOST_VERSION", to: "\"0.1.0-dev\""),
    // iOS consumers provide the platform-specific archive through the app
    // target's linker settings. Compiling the source fallback here would
    // satisfy the bridge symbols first and silently bypass FEXCore.
    .define("IRIDIUM_FEX_LINK_CANONICAL_ARCHIVE", to: "1", .when(platforms: [.iOS])),
    .define("IRIDIUM_WINE_LINK_EMBEDDED_SERVER", to: "1", .when(platforms: [.iOS])),
]
if hostFEXAvailable {
    sharedSettings.append(
        .define("IRIDIUM_FEX_LINK_CANONICAL_ARCHIVE", to: "1", .when(platforms: [.macOS]))
    )
}

let hostLinkerSettings: [LinkerSetting] = hostFEXAvailable
    ? [.unsafeFlags(linkerFlags(for: hostBuildRoot), .when(platforms: [.macOS]))]
    : []

let package = Package(
    name: "iridium-runtime-sdk",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "IridiumRuntimeHostSDK",
            targets: ["IridiumRuntimeHostSDK"]
        ),
        .executable(
            name: "runtime-host.bin",
            targets: ["IridiumRuntimeHostCLI"]
        ),
    ],
    targets: [
        .target(
            name: "IridiumRuntimeHostSDK",
            path: ".",
            exclude: sharedExcludes,
            sources: [
                "src/embedded_fex_bridge.cpp",
                "src/embedded_wine_bridge.cpp",
                "src/runtime_host_core.cpp",
            ],
            publicHeadersPath: "include/public",
            cxxSettings: sharedSettings,
            linkerSettings: hostLinkerSettings
        ),
        .executableTarget(
            name: "IridiumRuntimeHostCLI",
            dependencies: ["IridiumRuntimeHostSDK"],
            path: "src",
            sources: [
                "runtime_host_main.cpp"
            ]
        ),
        .testTarget(
            name: "IridiumRuntimeHostSDKTests",
            dependencies: ["IridiumRuntimeHostSDK", "IridiumRuntimeHostCLI"],
            path: "Tests/IridiumRuntimeHostSDKTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
