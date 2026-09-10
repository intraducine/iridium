import Combine
import SwiftUI

struct RootTabView: View {
    @ObservedObject var viewModel: AppViewModel
    private let usesExternalInput: Bool
    @StateObject private var controller: LibraryController
    init(viewModel: AppViewModel, controller: LibraryController? = nil) {
        self.viewModel = viewModel
        usesExternalInput = controller != nil
        _controller = StateObject(wrappedValue: controller ?? LibraryController())
    }
    @Environment(\.scenePhase) private var scenePhase
    private let menuTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        ControllerMenuHost(nativeNavigation: controller.nativeMenuActive || (viewModel.activeRuntimePlayerSession == nil && !controller.libraryNavigationActive && !controller.hasMenuScope), backAction: controller.backAction) { tabs }.ignoresSafeArea()
    }

    private var tabs: some View {
        NavigationStack {
            LibraryView(viewModel: viewModel)
        }
        .environmentObject(controller)
        .environment(\.menuController, controller)
        .onReceive(menuTimer) { _ in
            if !usesExternalInput && scenePhase == .active && viewModel.activeRuntimePlayerSession == nil { controller.poll() }
        }
        .background {
            #if MADEIRA_RUNTIME
            if viewModel.usesMadeiraRuntime { MadeiraPlayerPresentation(viewModel: viewModel).frame(width: 0, height: 0) }
            #endif
        }
        .fullScreenCover(
            item: Binding(
                get: { viewModel.usesMadeiraRuntime ? nil : viewModel.activeRuntimePlayerSession },
                set: { newValue in
                    if newValue == nil {
                        viewModel.dismissActiveRuntimePlayer()
                    }
                }
            )
        ) { session in
            RuntimePlayerView(session: session, viewModel: viewModel)
        }
    }


}

private struct IridiumGlassBadgeModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular.tint(tint.opacity(0.22)),
                        in: Capsule()
                    )
            } else {
                content.background(tint.opacity(0.12), in: Capsule())
            }
        }
    }
}

extension View {
    func iridiumGlassBadge(tint: Color = .orange) -> some View {
        modifier(IridiumGlassBadgeModifier(tint: tint))
    }
}
