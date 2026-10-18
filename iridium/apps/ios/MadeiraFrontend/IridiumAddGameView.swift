import SwiftUI

enum IridiumAddGameSource: Int, CaseIterable { case files, steam }

/// The same native destinations for touch, keyboard and controller.
struct IridiumAddGameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var guided = false
    @State private var pages: [String] = []
    @FocusState private var keyboardFocus: Bool
    var choose: (IridiumAddGameSource) -> Void
    var chooseSystem: (IridiumPlatform) -> Void
    private var systems: [IridiumConsoleSystem] { IridiumConsoleSystem.all }
    private var descriptions: [String] {
        ["Import Windows game folders, EXE files or supported console games. See Systems below for formats and setup.",
         "Sign in to your Steam library to browse, download, and play Windows games."]
    }

    var body: some View {
        NavigationStack(path: $pages) {
          ScrollViewReader { proxy in
            List {
              Section("Sources") {
              ForEach(0..<2) { index in
                Button { choose(IridiumAddGameSource(rawValue: index) ?? .files) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index == 0 ? "Files" : "Steam")
                        Text(descriptions[index]).font(.caption).foregroundStyle(.secondary)
                    }
                }.foregroundStyle(.primary).id(index)
                    .listRowBackground(guided && selected == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
              }
              }
              Section("Systems") {
                ForEach(Array(systems.enumerated()), id: \.element.id) { index, system in
                    NavigationLink(value: system.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(system.title)
                            Text(system.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }.id(index + 2)
                        .listRowBackground(guided && selected == index + 2 ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                }
              }
            }
            .iridiumPageSurface().navigationTitle("Add Game").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                if let system = systems.first(where: { $0.id == id }) {
                    IridiumSystemImportView(system: system, choose: chooseSystem)
                }
            }
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            .onChange(of: pages) { _, value in if value.isEmpty { keyboardFocus = true } }
            .onKeyPress(.upArrow) { guard pages.isEmpty else { return .ignored }; move(-1); return .handled }
            .onKeyPress(.downArrow) { guard pages.isEmpty else { return .ignored }; move(1); return .handled }
            .onKeyPress(.return) { guard pages.isEmpty else { return .ignored }; accept(); return .handled }
            .onKeyPress(.escape) { back(); return .handled }
            .onReceive(LibraryController.shared.commands) { value in
                if value == "back" { back(); return }
                guard pages.isEmpty else { return }
                if value == "up" || value == "left" { move(-1) }
                else if value == "down" || value == "right" { move(1) }
                else if value == "accept" { accept() }
            }
          }
        }
    }
    private func move(_ step: Int) { guided = true; selected = min(max(selected + step, 0), systems.count + 1) }
    private func accept() {
        if selected < 2 { choose(IridiumAddGameSource(rawValue: selected) ?? .files) }
        else if systems.indices.contains(selected - 2) { pages.append(systems[selected - 2].id) }
    }
    private func back() { if pages.isEmpty { dismiss() } else { pages.removeLast() } }
}
