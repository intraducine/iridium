// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RuntimeDiagnosticsExportSection: View {
    @State private var exporting = false
    @State private var exportItem: ExportItem?
    @State private var failure: String?
    private struct ExportItem: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        Section("App Logs") {
            Button(action: export) {
                Label(exporting ? "Preparing Logs…" : "Export All App Logs", systemImage: "square.and.arrow.up")
            }
            .disabled(exporting)
            .accessibilityIdentifier("exportAllAppLogs")
            Text("Includes available Iridium, console, and native Wine/FEX/DXMT logs, including previous runs. Common credential fields, paths, and identifiers are redacted. Includes up to 40 recent native sessions and the latest 4 MiB per log. Review before sharing; original logs are kept.")
                .font(.footnote).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
        }
        #if canImport(UIKit)
        .sheet(item: $exportItem, onDismiss: removeExport) { item in
            RuntimeDiagnosticsShareSheet(url: item.url)
        }
        #endif
    }

    private func export() {
        guard !exporting, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        exporting = true; failure = nil
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    try RuntimeDiagnosticLogFiles.export(in: documents)
                }.value
                exporting = false
                exportItem = ExportItem(url: url)
            } catch {
                exporting = false
                failure = "Logs could not be prepared. Try again after a game has started. Original logs are kept."
            }
        }
    }

    // Share sheets may keep the file URL after dismissal. Leave the sanitized
    // export in temporary storage for the receiving extension to finish reading.
    private func removeExport() { exportItem = nil }
}

#if canImport(UIKit)
private struct RuntimeDiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// Reads existing files directly, including during a console boot. It does not
/// initialize Madeira's LogStore, which would rotate the log being diagnosed.
struct RuntimeDiagnosticsLogView: View {
    var title = "Runtime Log"
    var progress: IridiumRuntimeProgress? = nil
    var playbackTitle: String? = nil
    var togglePlayback: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let playbackTitle, let togglePlayback {
                        Button(playbackTitle, action: togglePlayback).buttonStyle(.bordered)
                    }
                    RuntimeDiagnosticsLogContent(progress: progress)
                }.padding()
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// Also embedded directly in the shared player menu. Navigation and dismissal
/// belong to the caller, so the Windows menu keeps its existing Back action.
struct RuntimeDiagnosticsLogContent: View {
    var progress: IridiumRuntimeProgress? = nil
    @State private var lines: [String] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let progress {
                Text("Runtime & Frames").font(.headline)
                Text(progress.summary).font(.callout.monospacedDigit())
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(progress.observation).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Runtime activity and changing images do not confirm that the game has finished loading. A static image can be a normal menu or a stalled game.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            RuntimeDiagnosticsExportSection()
            Divider()
            Text("Latest Entries").font(.headline)
            if lines.isEmpty { Text("No complete log entries are available yet.").foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            while !Task.isCancelled {
                let batch = await Task.detached(priority: .utility) {
                    RuntimeDiagnosticLogFiles.recentLines(in: documents)
                }.value
                guard !Task.isCancelled else { return }
                lines = batch
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
