// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumDiagnosticsSections: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var console = IridiumConsoleSession.shared
    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown" }
    private var revisions: [String: String] { Bundle.main.object(forInfoDictionaryKey: "IridiumRuntimeRevisions") as? [String: String] ?? [:] }
    private var session: String {
        if library.current != nil { return "Windows session active" }
        switch console.phase {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopping: return "Stopping"
        case .restartRequired: return "Restart required"
        }
    }
    var body: some View {
        Section("App & Build") {
            LabeledContent("Version", value: info("CFBundleShortVersionString"))
            LabeledContent("Build", value: info("CFBundleVersion"))
            revision("Root commit", info("IridiumRootRevision"))
            LabeledContent("Source", value: info("IridiumSourceState"))
        }
        Section("Current Status") {
            LabeledContent("Session", value: session)
            IridiumExecutionStatusRows()
            ForEach(IridiumRuntimeRegistry.all, id: \.id) { runtime in
                LabeledContent(runtime.name, value: ["dolphin", "azahar", "play", "flycast"].contains(runtime.id) ? "Included · device unverified" : "Included")
            }
            if console.game?.platform == .psp, console.isActive {
                LabeledContent("PSP CPU", value: console.pspCPUMode)
            }
        }
        Section("Runtime Sources") {
            ForEach(["Madeira", "FEX", "wine", "dxmt", "madeira-dock", "PPSSPP", "SameBoy", "Dolphin", "Azahar", "Play!", "Flycast"].filter { revisions[$0] != nil }, id: \.self) { name in
                revision(["wine": "Wine", "dxmt": "DXMT", "madeira-dock": "Madeira Dock"][name] ?? name, revisions[name] ?? "Unknown")
            }
        }
    }
    private func revision(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(value).font(.footnote.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IridiumExecutionStatusRows: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var console = IridiumConsoleSession.shared
    private var status: IridiumExecutionStatus {
        library.current != nil ? .madeira : console.executionStatus
    }
    var body: some View {
        LabeledContent("Runtime", value: status.runtime)
        LabeledContent("Execution", value: status.mode)
            .accessibilityIdentifier("currentSessionExecutionMode")
        Text(status.detail).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct IridiumLegalNoticesSection: View {
    private var notices: [URL] {
        guard let root = Bundle.main.url(forResource: "licenses", withExtension: nil),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { $0 as? URL }.filter { url in
            (["txt", "md", "html"].contains(url.pathExtension.lowercased()) ||
             ["license", "copying", "notice", "copyright", "authors"].contains(where: { url.lastPathComponent.lowercased().hasPrefix($0) })) &&
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    }
    var body: some View {
        Section {
            NavigationLink("Licenses & Notices") {
                List {
                    if notices.isEmpty { Text("No bundled notices are available in this build.").foregroundStyle(.secondary) }
                    ForEach(notices, id: \.self) { url in
                        NavigationLink(url.deletingPathExtension().lastPathComponent) {
                            ScrollView {
                                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "This notice could not be read.")
                                    .font(.footnote.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                            }.navigationTitle(url.deletingPathExtension().lastPathComponent).iridiumPageSurface()
                        }
                    }
                }.navigationTitle("Licenses & Notices").iridiumPageSurface()
            }
        }
    }
}
