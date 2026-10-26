// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumImportFolderView: View {
    var automaticallyScan = true
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var imports = IridiumImportCoordinator.shared
    @State private var selected = 0
    @State private var guided = false
    @State private var choosingFiles = false
    @State private var selectionError: String?
    @FocusState private var keyboardFocus: Bool

    private var actions: [(id: String, run: () -> Void)] {
        [(":files", { choosingFiles = true })] + imports.choices.values.sorted { $0.receipt.path < $1.receipt.path }.flatMap { choice in
            choice.options.map { option in (choice.receipt.path + "\n" + option.value, { imports.choose(choice, value: option.value) }) }
        } + [(":retry", { imports.scan(retry: true) })]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Choose Files") { choosingFiles = true }.disabled(!automaticallyScan)
                        .listRowBackground(highlight(":files"))
                    Text("Put game files, game folders, ZIP or 7z archives, and pairing files in Iridium’s Import folder in Files.")
                    Text("Import runs while Iridium is open and no game is running. Each game gets a folder in Games. Pairing files go to secure device storage.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.iridiumRowSurface()
                Section {
                    if let selectionError { Text(selectionError).foregroundStyle(.red) }
                    if imports.isWorking { ProgressView("Importing files") }
                    else if let error = imports.migrationError { Text(error).foregroundStyle(.red) }
                    else { Text(imports.imported == 0 ? "Ready to import" : "Imported: \(imports.imported)") }
                    if !imports.choices.isEmpty { Text("Some files need a choice below.").foregroundStyle(.secondary) }
                }.iridiumRowSurface()
                ForEach(imports.choices.values.sorted { $0.receipt.path < $1.receipt.path }) { choice in
                    Section {
                        Text(choice.receipt.path).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(choice.title).foregroundStyle(.secondary)
                        ForEach(choice.options, id: \.value) { option in
                            Button(option.title) { imports.choose(choice, value: option.value) }
                                .disabled(imports.isWorking || !automaticallyScan)
                                .accessibilityHint(choice.receipt.path)
                                .listRowBackground(highlight(choice.receipt.path + "\n" + option.value))
                        }
                    }.iridiumRowSurface()
                }
                if !imports.failures.isEmpty {
                    Section("Could not import") {
                        ForEach(imports.failures.keys.sorted(), id: \.self) { path in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(path).font(.headline)
                                Text(imports.failures[path] ?? "").foregroundStyle(.secondary)
                            }
                        }
                    }.iridiumRowSurface()
                }
                Section {
                    Button("Retry Import") { selectionError = nil; imports.scan(retry: true) }.disabled(imports.isWorking || !automaticallyScan)
                        .listRowBackground(highlight(":retry"))
                }.iridiumRowSurface()
                if !imports.remaining.isEmpty {
                    Section("Files left in Import") {
                        ForEach(Array(imports.remaining.prefix(200)), id: \.self) { Text($0) }
                        if imports.remaining.count > 200 { Text("\(imports.remaining.count - 200) more files").foregroundStyle(.secondary) }
                        Text("Files stay here until import succeeds. Other files stay here for you to keep or remove.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.iridiumRowSurface()
                }
            }.iridiumPageSurface().navigationTitle("Import Folder").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .focusable().focusEffectDisabled().focused($keyboardFocus)
                .onAppear { keyboardFocus = true; if automaticallyScan { imports.scan() } }
                .onKeyPress(.upArrow) { guard !choosingFiles else { return .ignored }; move(-1); return .handled }
                .onKeyPress(.downArrow) { guard !choosingFiles else { return .ignored }; move(1); return .handled }
                .onKeyPress(.return) { guard !choosingFiles else { return .ignored }; accept(); return .handled }
                .onKeyPress(.escape) { guard !choosingFiles else { return .ignored }; dismiss(); return .handled }
                .onReceive(LibraryController.shared.commands) { value in
                    guard !choosingFiles else { return }
                    if value == "back" { dismiss() }
                    else if value == "up" || value == "left" { move(-1) }
                    else if value == "down" || value == "right" { move(1) }
                    else if value == "accept" { accept() }
                }
                .fileImporter(isPresented: $choosingFiles, allowedContentTypes: IridiumImportSource.contentTypes, allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): selectionError = nil; imports.receive(urls)
                    case .failure(let error):
                        if (error as NSError).code != NSUserCancelledError { selectionError = error.localizedDescription }
                    }
                    keyboardFocus = true
                }
                .onChange(of: actions.count) { _, count in selected = min(selected, max(0, count - 1)) }
        }
    }
    private func highlight(_ id: String) -> Color {
        Color.white.opacity(guided && actions.indices.contains(selected) && actions[selected].id == id ? 0.2 : 0.07)
    }
    private func move(_ step: Int) { guided = true; selected = min(max(0, selected + step), max(0, actions.count - 1)) }
    private func accept() {
        guard automaticallyScan, actions.indices.contains(selected), !imports.isWorking || actions[selected].id == ":files" else { return }
        actions[selected].run()
    }
}
