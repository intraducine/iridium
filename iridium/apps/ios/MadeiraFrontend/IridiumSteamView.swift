import SwiftUI

/// Madeira owns account state, game detection, transfers, cloud saves and Dock.
struct IridiumSteamView: View {
    var startDock: (DockGame, Bool) -> Void
    var open: (LibraryEntry) -> Void
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @State private var search = ""
    @State private var account = false
    @State private var dock = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if SteamGamesSection.shown {
                    ScrollView {
                        SteamGamesSection(search: search, layout: "cards", width: geo.size.width - 40, open: open)
                            .padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                    }.refreshable { await SteamGamesSection.refresh() }
                } else {
                    ContentUnavailableView {
                        Label("Steam Library", systemImage: "gamecontroller")
                    } description: {
                        Text("Sign in to view and download your games.")
                    } actions: {
                        Button("Sign in to Steam") { account = true }.buttonStyle(.bordered)
                    }
                }
            }
            .iridiumPageSurface().navigationTitle("Steam Library")
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Steam games")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { account = true } label: { Label("Steam Account", systemImage: "person.crop.circle") }
                    if MadeiraDock.enabled {
                        Button { dock = true } label: { Label("Madeira Dock", systemImage: "shippingbox") }
                    }
                    Button { Task { await SteamGamesSection.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.disabled(steam.refreshing)
                }
            }
            .sheet(isPresented: $account) { SteamSignInView() }
            .sheet(isPresented: $dock) { MadeiraDockView(start: startDock) }
        }
    }
}
