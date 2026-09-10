import SwiftUI
import UniformTypeIdentifiers

struct BuiltinJITSettings: View {
    @Environment(\.menuController) private var controller
    @AppStorage(BuiltinJIT.settingKey) private var enabled = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Section("Built-in JIT · Experimental") {
            MenuToggle("Enable JIT inside Iridium", isOn: $enabled)
                .disabled(BuiltinJIT.isHosted)
            MenuButton("Import Pairing File") { importing = true }
            Text(BuiltinJIT.isHosted
                 ? "Use standalone Iridium for built-in JIT. External StikDebug remains available."
                 : "Requires iOS 27, debugging permission, a pairing file, and connected LocalDevVPN. Device verification is pending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote) }
        }
        .onChange(of: importing) { _, presented in controller?.nativeMenuActive = presented }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                try BuiltinJIT.importPairing(result.get())
                message = "Pairing file imported. Connect LocalDevVPN before playing."
            } catch { message = "Could not import this pairing file. Choose a valid pairing plist." }
        }
    }
}
