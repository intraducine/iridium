// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumMeloNXSystemFiles: View {
    static let route = "Keys & Firmware"
    @ObservedObject private var imports = IridiumImportCoordinator.shared
    static let importAction = "Import System Files"
    var focus: String?
    let showImport: () -> Void
    @State private var keys = false
    @State private var firmware = false

    var body: some View {
        Form {
            Group {
                Section {
                    LabeledContent("Switch Keys", value: keys ? "Imported" : "Missing")
                    LabeledContent("Switch Firmware", value: firmware ? "Installed" : "Missing")
                    Button(Self.importAction, systemImage: "tray.and.arrow.down", action: showImport)
                        .id(Self.importAction)
                        .listRowBackground(focus == Self.importAction ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                } footer: {
                    Text("Import prod.keys before the firmware ZIP. title.keys is optional.")
                }
            }.iridiumRowSurface()
        }
        .iridiumPageSurface()
        .navigationTitle(Self.route)
        .onAppear(perform: refresh)
        .onChange(of: imports.imported) { _, _ in refresh() }
    }

    private func refresh() {
        let status = try? IridiumConsoleLibrary.shared.store.switchSystemFiles()
        keys = status?.keys == true
        firmware = status?.firmware == true
    }

    nonisolated static func importFile(_ file: URL, firmware: Bool, store: IridiumConsoleStore,
                                      frameworks: URL?) throws {
        if !firmware {
            try importKey(file, store: store)
            return
        }
        guard let frameworks else { throw IridiumRuntimeError.unavailable }
        let root = try store.systemDirectory(runtimeID: "melonx")
        let remaining = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard remaining >= 1_500_000_000 else {
            throw IridiumImportFailure.message("Free at least 1.5 GB before installing firmware.")
        }
        // The native installer expects a lowercase extension.
        let alias = root.appendingPathComponent(".firmware-" + UUID().uuidString + ".zip")
        let input = file.pathExtension == "zip" ? file : alias
        if input == alias { try FileManager.default.linkItem(at: file, to: alias) }
        defer { if input == alias { try? FileManager.default.removeItem(at: alias) } }
        switch ir_phase3_melonx_install_firmware(frameworks.path, root.path, input.path) {
        case 0: return
        case 1: throw IridiumImportFailure.message("Reopen Iridium and try again.")
        case 2: throw IridiumImportFailure.message("Choose a valid Switch firmware ZIP.")
        case 3: throw IridiumRuntimeError.missingSwitchKeys
        default: throw IridiumImportFailure.message("Firmware installation failed.")
        }
    }

    nonisolated private static func importKey(_ file: URL, store: IridiumConsoleStore) throws {
        let name = file.lastPathComponent
        guard name == "prod.keys" || name == "title.keys" else { throw IridiumImportFailure.message("Choose prod.keys or title.keys.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let limit = 1024 * 1024
        guard let bytes = try handle.read(upToCount: limit + 1), bytes.count <= limit,
              let text = String(data: bytes, encoding: .utf8) else { throw IridiumImportFailure.message("Could not read the key file.") }
        let lines = text.split(whereSeparator: \.isNewline)
        let pattern = name == "title.keys" ? #"^[0-9a-fA-F]{32}\s*=\s*[0-9a-fA-F]{32}$"# :
            #"^[a-z0-9_]+\s*=\s*([0-9a-fA-F]{2})+$"#
        guard !lines.isEmpty, lines.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) else {
            throw IridiumImportFailure.message("The key file format is invalid.")
        }
        var folder = try store.checked(["System", "melonx", "system"], createDirectory: true)
        var metadata = URLResourceValues()
        metadata.isExcludedFromBackup = true
        try folder.setResourceValues(metadata)
        let target = try store.checked(["System", "melonx", "system", name])
        try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
