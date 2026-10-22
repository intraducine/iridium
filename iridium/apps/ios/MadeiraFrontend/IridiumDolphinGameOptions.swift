// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct IridiumDolphinGameOptions: View {
    let game: IridiumConsoleGame
    @ObservedObject private var session = IridiumConsoleSession.shared
    @State private var settings: IridiumDolphinSettings
    init(game: IridiumConsoleGame) { self.game = game; _settings = State(initialValue: .load(game.id)) }
    private func value<T>(_ key: WritableKeyPath<IridiumDolphinSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0; settings.save(game.id) })
    }
    var body: some View {
        Section("Dolphin") {
            Picker("Resolution", selection: value(\.resolution)) {
                ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
            }
            Picker("Aspect Ratio", selection: value(\.aspect)) {
                Text("Auto").tag(0); Text("16:9").tag(1); Text("4:3").tag(2)
            }
            if game.platform == .wii {
                Picker("Wii Controls", selection: value(\.remote)) {
                    Text("Sideways Wii Remote").tag(0)
                    Text("Wii Remote and Nunchuk").tag(1)
                    Text("Classic Controller").tag(2)
                }
                Toggle("Phone Motion", isOn: value(\.motion))
            }
            Picker("Players", selection: value(\.players)) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Dual Core", isOn: value(\.dualCore))
            Toggle("Mute Game", isOn: Binding(get: { settings.muted == true }, set: { settings.muted = $0; settings.save(game.id) }))
            NavigationLink { IridiumDolphinFiles(game: game) } label: {
                Label("Save and Wii System Files", systemImage: "folder")
            }
        }
        .disabled(session.isActive || session.dolphinMaintenance)
    }
}

private struct IridiumDolphinFiles: View {
    let game: IridiumConsoleGame
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = IridiumConsoleSession.shared
    @State private var importing = false
    @State private var export: URL?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text("These files belong to \(game.title). Dolphin keeps this game's memory cards, Wii storage, settings, and save states together.")
                Button("Export Save and System Files", systemImage: "square.and.arrow.up") {
                    do { export = try IridiumConsoleLibrary.shared.store.saveDirectory(game) }
                    catch { self.error = error.localizedDescription }
                }
                Button("Export Dolphin Backups", systemImage: "externaldrive") {
                    do {
                        let save = try IridiumConsoleLibrary.shared.store.saveDirectory(game)
                        let backup = save.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
                        guard backup.resolvingSymlinksInPath() == backup.standardizedFileURL else { throw IridiumRuntimeError.unsafePath }
                        guard FileManager.default.fileExists(atPath: backup.path) else { self.error = "No Dolphin backups have been made."; return }
                        export = backup
                    } catch { self.error = error.localizedDescription }
                }
            }
            if game.platform == .wii {
                Section("Wii System Content") {
                    Button("Install WAD from Files", systemImage: "square.and.arrow.down") { importing = true }
                    Text("Choose Wii content that you own. Iridium makes a backup before installation. Dolphin checks and installs the content. The original files are restored if installation fails.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if session.dolphinMaintenance { ProgressView("Working on Wii files…") }
            if let status = session.dolphinSystemStatus { Text(status).accessibilityLabel(status) }
        }
        .disabled(session.dolphinMaintenance)
        .navigationTitle("Dolphin Files")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(session.dolphinMaintenance) } }
        .navigationBarBackButtonHidden(session.dolphinMaintenance)
        .interactiveDismissDisabled(session.dolphinMaintenance)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "wad") ?? .data]) { result in
            switch result {
            case .success(let url): session.installDolphinWAD(url, game: game)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } })) {
            if let export { IridiumDolphinExport(url: export) }
        }
        .alert("Dolphin Files", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct IridiumDolphinExport: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
