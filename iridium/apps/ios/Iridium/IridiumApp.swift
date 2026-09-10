import SwiftUI

@main
struct IridiumApp: App {
    private static let buildMarker = "Version 57 contained-PE-arena-and-terminal-monitor"
    private static let logFileURL = RuntimeLogCapture.install()
    private static let bundleVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown"
    private static let bundleBuild = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"
    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: AppViewModel?

    init() {
        // Install capture before recording host/JIT launch diagnostics.
        _ = Self.logFileURL
        // Snapshot host-owned settings before any UI can repair them. They only
        // become active when LiveContainer creates the next guest process.
        LiveContainerIntegration.configureProcessLaunchEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let viewModel {
                    RootTabView(viewModel: viewModel)
                } else {
                    AppLaunchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .task {
                guard viewModel == nil else {
                    return
                }

                if let logFileURL = Self.logFileURL {
                    print("[IridiumRuntime] Log file: \(logFileURL.path)")
                } else {
                    print("[IridiumRuntime] Log file: unavailable")
                }
                print(
                    "[IridiumRuntime] App build identity: marker=\(Self.buildMarker) version=\(Self.bundleVersion) build=\(Self.bundleBuild) bundle=\(Self.bundleIdentifier)"
                )

                viewModel = await AppViewModel.make()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard let viewModel else {
                    return
                }

                switch newPhase {
                case .active:
                    viewModel.requestRefresh()
                case .background:
                    break
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

private struct AppLaunchView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView("Loading Iridium")
                .controlSize(.large)

            Text("Preparing your library and runtime status.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
