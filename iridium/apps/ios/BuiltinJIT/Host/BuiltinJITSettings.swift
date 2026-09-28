import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BuiltinJITSettings: View {
    @Environment(\.menuController) private var controller
    @AppStorage(BuiltinJIT.settingKey) private var enabled = false
    @State private var importing = false
    @State private var choosingImport = false
    @State private var importingPairing = false
    @State private var message: String?

    var body: some View {
        Section("Built-in JIT · Experimental") {
            MenuToggle("Enable JIT inside Iridium", isOn: $enabled)
                .disabled(BuiltinJIT.isHosted)
            MenuButton("Import Pairing File") { choosingImport = true }
                .disabled(importingPairing)
            Text(BuiltinJIT.isHosted
                 ? "Use standalone Iridium for built-in JIT. External StikDebug remains available."
                 : "Requires iOS 18, debugging permission, a pairing file, and connected LocalDevVPN.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote) }
        }
        .task {
            do {
                try await Task.detached(priority: .utility) {
                    try JITPairingStore.live.prepareFilesFolder()
                }.value
            } catch {
                message = "Could not prepare the pairing file folder in Iridium."
            }
        }
        .onChange(of: importing) { _, _ in controller?.nativeMenuActive = importing || choosingImport }
        .onChange(of: choosingImport) { _, _ in controller?.nativeMenuActive = importing || choosingImport }
        .confirmationDialog("Import Pairing File", isPresented: $choosingImport) {
            Button("Choose File") { importing = true }
            Button("Use File in Iridium Folder") { usePairingFileInFolder() }
        } message: {
            Text("In Files, copy your pairing file to \(pairingFolderLocation), then rename it pairingFile.plist.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                try BuiltinJIT.importPairing(result.get())
                message = "Pairing file imported. Connect LocalDevVPN before playing."
            } catch { message = "Could not import this pairing file. Choose a valid pairing plist." }
        }
    }

    private func usePairingFileInFolder() {
        guard !importingPairing else { return }
        importingPairing = true
        Task {
            defer { importingPairing = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BuiltinJIT.importPairing(BuiltinJIT.filesPairingURL)
                }.value
                message = "Pairing file imported. Connect LocalDevVPN before playing."
            } catch {
                message = "Could not import pairingFile.plist. Copy a valid file to \(pairingFolderLocation), then try again."
            }
        }
    }

    private var pairingFolderLocation: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
        return "\(device) → Iridium → StikJIT"
    }
}
