// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum IridiumStorefront: String, CaseIterable, Identifiable {
    case steam = "Steam", epic = "Epic Games", ea = "EA", itch = "itch.io"
    var id: Self { self }
    @MainActor var signedIn: Bool {
        switch self {
        case .steam: SteamOwnedLibrary.shared.signedIn
        case .epic: EpicLibrary.shared.signedIn
        case .ea: EALibrary.shared.signedIn
        case .itch: ItchLibrary.shared.signedIn
        }
    }
}

struct IridiumStoreBrowser: View {
    let startDock: (DockGame, Bool) -> Void
    let open: (LibraryEntry) -> Void
    @State private var store = IridiumStorefront.steam
    @State private var search = ""
    @State private var accounts = false
    @State private var dock = false
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var ea = EALibrary.shared
    @ObservedObject private var itch = ItchLibrary.shared
    @Environment(\.dismiss) private var dismiss

    private var noMatches: Bool {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch store {
        case .steam: return SteamGamesRules.items(installed: games.games, owned: steam.owned, search: search).isEmpty
        case .epic: return EpicGamesRules.items(epic, search: search).isEmpty
        case .ea: return EAGamesRules.items(ea, search: search).isEmpty
        case .itch: return ItchGamesRules.items(itch, search: search).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 24) {
                            ForEach(IridiumStorefront.allCases) { item in
                                Button { store = item } label: {
                                    Text(item.rawValue).fontWeight(store == item ? .semibold : .regular)
                                        .foregroundStyle(store == item ? .white : .secondary)
                                        .frame(minHeight: 44)
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(store == item ? .isSelected : [])
                                    .accessibilityIdentifier("store-" + item.id.rawValue)
                            }
                        }.padding(.horizontal, 20)
                    }.scrollIndicators(.hidden)
                    ScrollView {
                        Group {
                            switch store {
                            case .steam:
                                if SteamGamesSection.shown {
                                    SteamGamesSection(search: search, layout: "list", width: geometry.size.width - 40, open: open, standalone: true)
                                } else {
                                    ContentUnavailableView {
                                        Label("Steam", systemImage: "gamecontroller")
                                    } description: { Text("Sign in to see your games.") } actions: {
                                        Button("Accounts") { accounts = true }
                                    }
                                }
                            case .epic: EpicGamesSection(search: search, layout: "list", open: open, standalone: true)
                            case .ea: EAGamesSection(search: search, layout: "list", open: open, standalone: true)
                            case .itch: ItchGamesSection(search: search, layout: "list", open: open, standalone: true)
                            }
                        }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                        if noMatches { ContentUnavailableView.search(text: search) }
                    }.refreshable { await SteamGamesSection.refresh() }
                }
            }.iridiumPageSurface().navigationTitle("Stores")
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search games")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { accounts = true } label: { Label("Accounts", systemImage: "person.crop.circle") }
                        if store == .steam, MadeiraDock.enabled {
                            Button { dock = true } label: { Label("Steam Client", systemImage: "shippingbox") }
                        }
                        Button { Task { await SteamGamesSection.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(steam.refreshing)
                    }
                }
                .sheet(isPresented: $accounts) { IridiumStoreAccounts() }
                .sheet(isPresented: $dock) { MadeiraDockView(start: startDock) }
                .task { await SteamGamesSection.refresh() }
        }
    }
}

struct IridiumStoreAccounts: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: IridiumStorefront?
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var ea = EALibrary.shared
    @ObservedObject private var itch = ItchLibrary.shared
    var body: some View {
        NavigationStack {
            List(IridiumStorefront.allCases) { store in
                Button { selected = store } label: {
                    LabeledContent(store.rawValue, value: store.signedIn ? "Signed in" : "Sign in")
                }.iridiumRowSurface()
            }.iridiumPageSurface().navigationTitle("Accounts")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $selected) { store in
                    switch store {
                    case .steam: SteamSignInView()
                    case .epic: EpicSignInView()
                    case .ea: EASignInView()
                    case .itch: ItchSignInView()
                    }
                }
        }
    }
}
