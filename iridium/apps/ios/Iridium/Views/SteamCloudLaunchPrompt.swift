import SwiftUI

// Installed on the app's library, where every Play request reaches the shared
// AppViewModel launch method. An unresolved comparison never silently launches.
struct SteamCloudLaunchPrompt: ViewModifier {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var cloud = SteamCloudCoordinator.shared
    @ObservedObject private var steam = SteamLibraryModel.shared
    @State private var choosing: SteamCloudTarget?
    @Environment(\.menuController) private var controller

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if cloud.launchGameID != nil && cloud.launchProblem == nil {
                    HStack {
                        ProgressView("Checking saves before Play…")
                        Spacer()
                        MenuButton("Cancel Play", role: .cancel) { cloud.clearLaunch() }
                    }.padding().background(.regularMaterial)
                }
            }
            .alert("Steam Cloud Needs Attention", isPresented: Binding(
                get: { cloud.launchProblem != nil },
                set: { if !$0 { cloud.launchProblem = nil } }
            )) {
                Button("Choose Saves") {
                    if let game = viewModel.games.first(where: { $0.id == cloud.launchGameID }) {
                        choosing = SteamCloudTarget(game: game)
                    }
                    cloud.clearLaunch()
                }
                Button("Play with Device Saves") { cloud.launchWithoutSync() }
                    .disabled(!cloud.canLaunchWithoutSync)
                Button("Cancel", role: .cancel) { cloud.clearLaunch() }
            } message: {
                Text((cloud.launchProblem ?? "") + " Playing with device saves can create conflicts. Existing Cloud saves and backups are kept.")
            }
            .sheet(item: $choosing) { target in
                NavigationStack { SteamCloudView(target: target, viewModel: viewModel) }
            }
            .onChange(of: cloud.launchProblem != nil || choosing != nil) { _, presented in
                controller?.nativeMenuActive = presented
            }
    }
}
