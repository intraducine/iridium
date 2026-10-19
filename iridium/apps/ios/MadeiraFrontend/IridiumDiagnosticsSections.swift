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
            LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
            #if IRIDIUM_UX_PREVIEW
            LabeledContent("Platform", value: "iOS Simulator")
            #endif
        }
        Section("Current Status") {
            LabeledContent("Session", value: session)
            IridiumExecutionStatusRows()
            #if !IRIDIUM_UX_PREVIEW
            ForEach(IridiumRuntimeRegistry.all, id: \.id) { runtime in
                LabeledContent(runtime.name, value: "Included")
            }
            #endif
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
        if library.current == nil, !["Unknown", "Not reported"].contains(status.mode) {
            LabeledContent(status.mode == "Allocator verified" ? "Executable memory" : status.mode == "Interpreter requested" ? "CPU preference" : "Execution",
                value: status.mode == "Allocator verified" ? "Available" : status.mode == "Interpreter requested" ? "Interpreter" : status.mode)
                .accessibilityIdentifier("currentSessionExecutionMode")
        }
    }
}

struct IridiumLegalNoticesSection: View {
    var body: some View {
        Section { NavigationLink("Licenses & Notices") { IridiumSoftwareNoticesView() } }
    }
}

struct IridiumSoftwareCreditsSections: View {
    var body: some View {
        Section("App & Emulators") { ForEach(IridiumSoftwareCredit.engines.filter { $0.name == "Iridium" } + IridiumSoftwareCredit.engines.filter { $0.name != "Iridium" }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { credit($0) } }
        Section("Supporting Software") { ForEach(IridiumSoftwareCredit.supporting.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { credit($0) } }
        Section {
            NavigationLink("All Libraries & Notices") { IridiumSoftwareNoticesView() }
        } footer: { Text("Original authors, dependency credits and full license texts are preserved in the bundled notices.") }
    }
    private func credit(_ item: IridiumSoftwareCredit) -> some View {
        Link(destination: URL(string: item.source)!) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                    Text(item.purpose).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 3)
        }.accessibilityHint("Opens the project's source website")
    }
}

struct IridiumAboutView: View {
    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown" }
    var body: some View {
        Form {
                Group {

            Section("Iridium") {
                LabeledContent("Version", value: info("CFBundleShortVersionString"))
                LabeledContent("Build", value: info("CFBundleVersion"))
            }
            Section {
                NavigationLink("Credits") { Form {
                Group {
 IridiumCreditsSections()
                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Credits") }
                NavigationLink("Licenses & Notices") { IridiumSoftwareNoticesView() }
                NavigationLink("Build Details & Diagnostics") {
                    Form {
                Group {
 IridiumDiagnosticsSections(); RuntimeDiagnosticsExportSection()
                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Diagnostics")
                }
            }
            Section("Support") {
                Link("Source Code", destination: URL(string: "https://github.com/intraducine/iridium")!)
                Link("Report a Problem", destination: URL(string: "https://github.com/intraducine/iridium/issues")!)
            }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("About")
    }
}

struct IridiumSoftwareNoticesView: View {
    @State private var query = ""
    private var notices: [IridiumSoftwareNotice] {
        IridiumSoftwareNotice.catalog(roots: ["licenses", "legal"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: nil).map { (name, $0) }
        })
    }
    private var groups: [(String, [IridiumSoftwareNotice])] {
        Dictionary(grouping: notices, by: \.software).map { ($0.key, $0.value) }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || $0.1.contains(where: { $0.title.localizedCaseInsensitiveContains(query) }) }
    }
    var body: some View {
        List {
                Group {

            if groups.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(groups, id: \.0) { name, entries in
                NavigationLink {
                    List {
                Group {

                        if let credit = (IridiumSoftwareCredit.engines + IridiumSoftwareCredit.supporting).first(where: { $0.name == name }) {
                            Section { Link("Project & Source", destination: URL(string: credit.source)!) }
                        }
                        Section("Notices") {
                            ForEach(entries) { notice in
                                NavigationLink {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 16) {
                                            Text(notice.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                            Text((try? String(contentsOf: notice.url, encoding: .utf8)) ?? "This notice could not be read. Its original file remains in the app bundle.")
                                                .font(.footnote.monospaced()).textSelection(.enabled)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                                    }.iridiumPageSurface().navigationTitle(notice.title)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(notice.title)
                                        Text(notice.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle(name)
                } label: { LabeledContent(name, value: entries.count == 1 ? "1 notice" : "\(entries.count) notices") }
            }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Licenses & Notices").searchable(text: $query, prompt: "Find software or a notice")
    }
}
