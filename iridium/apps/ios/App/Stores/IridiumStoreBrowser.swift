// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumStoreBrowser: View {
    let startDock: (DockGame, Bool) -> Void
    let open: (LibraryEntry) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            IridiumSteamView(startDock: startDock, open: open)
                .tabItem { Label("Steam", systemImage: "shippingbox") }
            NavigationStack {
                ScrollView {
                    EpicGamesSection(search: search, layout: "list", open: open).padding()
                }
                .navigationTitle("Epic Games")
                .searchable(text: $search)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }.tabItem { Label("Epic Games", systemImage: "bag") }
            NavigationStack {
                ScrollView {
                    EAGamesSection(search: search, layout: "list", open: open).padding()
                }
                .navigationTitle("EA")
                .searchable(text: $search)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }.tabItem { Label("EA", systemImage: "gamecontroller") }
            NavigationStack {
                ScrollView {
                    ItchGamesSection(search: search, layout: "list", open: open).padding()
                }
                .navigationTitle("itch.io")
                .searchable(text: $search)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }.tabItem { Label("itch.io", systemImage: "square.stack") }
        }
    }
}
