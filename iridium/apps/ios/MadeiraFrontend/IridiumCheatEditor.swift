// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumCheatEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [IridiumCheat]
    let formats: [String]
    let apply: ([IridiumCheat]) -> Bool
    var title = "Cheats"
    @State private var error: String?

    init(draft: [IridiumCheat], formats: [String], title: String = "Cheats", apply: @escaping ([IridiumCheat]) -> Bool) {
        _draft = State(initialValue: draft); self.formats = formats; self.title = title; self.apply = apply
    }

    var body: some View {
        NavigationStack {
            List {
              Group {
                Section {
                    ForEach($draft) { $cheat in
                        NavigationLink {
                            Form {
                              Group {
                                TextField("Name", text: $cheat.name)
                                Picker("Format", selection: $cheat.format) {
                                    ForEach(formats, id: \.self) { Text(IridiumCheat.title($0)).tag($0) }
                                }
                                Toggle("Enabled", isOn: $cheat.enabled)
                                Section {
                                    TextEditor(text: $cheat.code)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 220)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .accessibilityLabel(title == "Game Patches" ? "Patch code" : "Cheat code")
                                } header: { Text("Code") }
                                footer: { Text(instructions(cheat.format)) }
                              }.iridiumRowSurface()
                            }.iridiumPageSurface().navigationTitle(cheat.name.isEmpty ? newItemTitle : cheat.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cheat.name.isEmpty ? newItemTitle : cheat.name)
                                Text(IridiumCheat.title(cheat.format) + (cheat.enabled ? " · On" : " · Off"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { draft.remove(atOffsets: $0) }
                    Button(title == "Game Patches" ? "Add Patch" : "Add Cheat", systemImage: "plus") { draft.append(.init(format: formats[0])) }
                        .disabled(draft.count >= 64 || formats.isEmpty)
                } footer: {
                    Text("Use codes for this game and version. Changes apply when you select Apply and Resume.")
                }
              }.iridiumRowSurface()
            }
            .iridiumPageSurface()
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply and Resume") {
                        do {
                            try IridiumCheat.validate(draft, formats: formats)
                            if apply(draft) { dismiss() }
                            else { error = "The game cannot accept this change now. Close this sheet and try again." }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert(title == "Game Patches" ? "Check Patches" : "Check Cheats", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private var newItemTitle: String { title == "Game Patches" ? "New Patch" : "New Cheat" }
    private func instructions(_ format: String) -> String {
        switch format {
        case "cwcheat": return "Enter the two numbers from each _L line, without _L."
        case "gameshark", "gamegenie": return "Enter one GameShark or Game Genie code per row."
        case "patch": return "Use address:type:value, for example 0x80000000:byte:0x00. Types are byte, word, and dword. Built-in code can only be enabled or disabled. Give an edited copy a new name."
        default: return "Enter one code line per row."
        }
    }
}
