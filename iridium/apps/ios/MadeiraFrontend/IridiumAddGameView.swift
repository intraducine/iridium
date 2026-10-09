import SwiftUI

/// The same native destinations for touch, keyboard and controller.
struct IridiumAddGameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var guided = false
    @FocusState private var keyboardFocus: Bool
    var choose: (Int) -> Void
    private let titles = ["Steam Library", "Choose Executable", "Import Existing Iridium Games", "Windows Desktop", "Import Game Boy ROM"]

    var body: some View {
        NavigationStack {
            List(titles.indices, id: \.self) { index in
                Button(titles[index]) { choose(index) }
                    .foregroundStyle(.primary)
                    .listRowBackground(guided && selected == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
            }
            .iridiumPageSurface().navigationTitle("Add Game").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { choose(selected); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onReceive(LibraryController.shared.commands) { value in
                if value == "up" || value == "left" { move(-1) }
                else if value == "down" || value == "right" { move(1) }
                else if value == "accept" { choose(selected) }
                else if value == "back" { dismiss() }
            }
        }
    }
    private func move(_ step: Int) { guided = true; selected = min(max(selected + step, 0), titles.count - 1) }
}
