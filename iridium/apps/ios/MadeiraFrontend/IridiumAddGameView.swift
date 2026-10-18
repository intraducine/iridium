import SwiftUI

enum IridiumAddGameSource: Int, CaseIterable { case files, steam }

/// The same native destinations for touch, keyboard and controller.
struct IridiumAddGameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var guided = false
    @FocusState private var keyboardFocus: Bool
    var choose: (IridiumAddGameSource) -> Void
    private let titles = ["Files", "Steam"]
    private var descriptions: [String] {
        [IridiumConsoleLibrary.supportsPSP ?
            "Windows game folders or EXE files, Game Boy ROMs, and PSP games. Runtime detected automatically." :
            "Windows game folders or EXE files and Game Boy ROMs. Runtime detected automatically.",
         "Sign in to your Steam library to browse, download, and play Windows games."]
    }

    var body: some View {
        NavigationStack {
            List(titles.indices, id: \.self) { index in
                Button { choose(IridiumAddGameSource(rawValue: index) ?? .files) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(titles[index])
                        Text(descriptions[index]).font(.caption).foregroundStyle(.secondary)
                    }
                }.foregroundStyle(.primary)
                    .listRowBackground(guided && selected == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
            }
            .iridiumPageSurface().navigationTitle("Add Game").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { choose(IridiumAddGameSource(rawValue: selected) ?? .files); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onReceive(LibraryController.shared.commands) { value in
                if value == "up" || value == "left" { move(-1) }
                else if value == "down" || value == "right" { move(1) }
                else if value == "accept" { choose(IridiumAddGameSource(rawValue: selected) ?? .files) }
                else if value == "back" { dismiss() }
            }
        }
    }
    private func move(_ step: Int) { guided = true; selected = min(max(selected + step, 0), titles.count - 1) }
}
