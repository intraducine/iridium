// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum IridiumAddGameSource: Int, CaseIterable { case files, steam }

struct IridiumAddGameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var guided = false
    @FocusState private var keyboardFocus: Bool
    var choose: (IridiumAddGameSource) -> Void
    var chooseSystem: (IridiumPlatform) -> Void = { _ in }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    source(.files, title: "Choose Files", subtitle: "Add a game file or a folder. Iridium finds the system.", symbol: "folder")
                    source(.steam, title: "Steam", subtitle: "Browse and download your Steam games.", symbol: "network")
                }
            }.iridiumPageSurface().navigationTitle("Add Game").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .focusable().focusEffectDisabled().focused($keyboardFocus)
                .onAppear { keyboardFocus = true }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.return) { accept(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onReceive(LibraryController.shared.commands) { command in
                    if command == "back" { dismiss() }
                    else if command == "up" || command == "left" { move(-1) }
                    else if command == "down" || command == "right" { move(1) }
                    else if command == "accept" { accept() }
                }
        }
    }
    private func source(_ source: IridiumAddGameSource, title: String, subtitle: String, symbol: String) -> some View {
        Button { choose(source) } label: {
            Label { VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            } } icon: { Image(systemName: symbol) }
        }.foregroundStyle(.primary)
            .listRowBackground(guided && selected == source.rawValue ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
    }
    private func move(_ step: Int) { guided = true; selected = min(max(selected + step, 0), 1) }
    private func accept() { choose(IridiumAddGameSource(rawValue: selected) ?? .files) }
}
