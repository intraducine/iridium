// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Setup and format guidance is shared with each system's Settings page.
struct IridiumSystemSetupSections: View {
    let system: IridiumConsoleSystem
    var platform: IridiumPlatform? = nil
    var body: some View {
        Section("System") {
            LabeledContent("Emulator", value: system.runtime.name)
            Text(system.subtitle).foregroundStyle(.secondary)
            Text(system.guidance).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        Section("Game Files") {
            Text((platform.map { system.formats(for: $0) } ?? system.extensions)
                .map { "." + $0 }.joined(separator: ", "))
                .font(.footnote.monospaced()).fixedSize(horizontal: false, vertical: true)
            Text("Choose a file you are entitled to use. Files are copied into Iridium; originals stay in place. Save and controller options are stored per game.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if system.primaryPlatform.isPhase3 {
            Section("Saves & System Files") {
                Text(system.storageGuidance + " No games, keys or BIOS files are included.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct IridiumSystemImportView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyboardFocus: Bool
    let system: IridiumConsoleSystem
    let choose: (IridiumPlatform) -> Void
    @State private var platform: IridiumPlatform
    init(system: IridiumConsoleSystem, choose: @escaping (IridiumPlatform) -> Void) {
        self.system = system; self.choose = choose
        _platform = State(initialValue: system.primaryPlatform)
    }
    var body: some View {
        Form {
            if system.importPlatforms.count > 1 {
                Section {
                    Picker("Game system", selection: $platform) {
                        ForEach(system.importPlatforms, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Button("Choose Game File") { choose(platform) }
                    .accessibilityIdentifier("chooseSystemGameFile")
            }
            IridiumSystemSetupSections(system: system, platform: platform)
        }.iridiumRowSurface().iridiumPageSurface().navigationTitle(system.title)
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.return) { choose(platform); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onReceive(LibraryController.shared.commands) { command in
                if command == "accept" { choose(platform) }
                else if ["left", "right", "up", "down"].contains(command) {
                    let step = command == "left" || command == "up" ? -1 : 1
                    move(step)
                }
            }
    }
    private func move(_ step: Int) {
        let values = system.importPlatforms
        guard values.count > 1 else { return }
        let index = values.firstIndex(of: platform) ?? 0
        platform = values[min(max(index + step, 0), values.count - 1)]
    }
}
