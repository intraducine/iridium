// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

private struct IridiumNativePSPSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// PPSSPP keeps its native touch/controller/keyboard input and advanced screens.
/// Iridium supplies the library boundary and an always-reachable return action.
struct IridiumNativePSPPlayer: View {
    @ObservedObject var session: IridiumConsoleSession
    @State private var confirmingClose = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let controller = session.nativePSPController {
                IridiumNativePSPSurface(controller: controller).ignoresSafeArea()
            } else {
                ProgressView("Opening PPSSPP…").tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                Button { ir_psp_native_menu() } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("PPSSPP menu and settings")
                Button { confirmingClose = true } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Return to Iridium library")
            }.buttonStyle(.bordered).tint(.white).controlSize(.large)
                .padding(.top, 8).padding(.trailing, 12)
                .disabled(session.phase == .stopping)
            if session.phase == .stopping {
                ProgressView("Closing PPSSPP…").tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.5))
            }
            if session.phase == .restartRequired {
                VStack(spacing: 16) {
                    Text("PPSSPP has not finished closing. Restart Iridium before launching another game.")
                    Button("Return to Library") { session.returnToLibraryAfterTimeout() }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .interactiveDismissDisabled().statusBarHidden()
        .confirmationDialog("Close this PSP session?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Close Game", role: .destructive) { session.stop() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("PPSSPP will stop before Iridium releases ownership. Memory-stick saves are kept.") }
        .alert("PPSSPP", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}
