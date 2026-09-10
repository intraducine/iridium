import IridiumCore
import IridiumRuntime
import SwiftUI

struct GameDetailView: View {
    let game: GameRecord
    @ObservedObject var viewModel: AppViewModel
    var locate: () -> Void = {}
    @ObservedObject private var artwork = LibraryArtwork.shared
    @Environment(\.dismiss) private var dismiss
    @State private var rename = false
    @State private var confirmRemoval = false

    var body: some View {
        List {
            Section {
                Text(artwork.title(game)).font(.title2.bold()).lineLimit(1)
                MenuButton(artwork.appearance(game.id).favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") {
                    do { try artwork.update(game.id) { $0.favorite.toggle() } } catch { artwork.error = error.localizedDescription }
                }
            }
            Section {
                MenuButton("Rename & Artwork", systemImage: "photo") { rename = true }
                MenuNavigationLink { GameControlsView(game: game) } label: { Label("Controls", systemImage: "gamecontroller") }
                    .accessibilityIdentifier("gameControlsLink")
                MenuNavigationLink { GameStorageView(game: game, usesMadeiraRuntime: viewModel.usesMadeiraRuntime) } label: {
                    Label("Files & Saves", systemImage: "folder")
                }
            }
            if viewModel.isLaunchActionDisabled(for: game) {
                Section("Before You Play") {
                    Text(viewModel.launchActionDetail(for: game) ?? "Check the game files and runtime settings.")
                    if viewModel.jitStatus != .ready {
                        MenuButton("Enable JIT") { viewModel.enableJITWithRecommendedTool() }
                    }
                    if !FileManager.default.fileExists(atPath: game.launchProfile.executablePath) {
                        MenuButton("Locate Game Folder", action: locate)
                        Text("Choose the folder containing this game and its executable. Iridium copies it to a new location and keeps your existing saves.").font(.footnote)
                    }
                    MenuButton("Check Game Files") { viewModel.verifyGameRegistration(game) }
                }
            }
            Section {
                MenuNavigationLink("Advanced") {
                    List {
                        Section("Launch") {
                            MenuValue("Executable", value: game.launchProfile.executablePath)
                            MenuValue("Arguments", value: game.launchProfile.arguments.isEmpty ? "None" : game.launchProfile.arguments.joined(separator: " "))
                            MenuNavigationLink("Launch Checks") { GameCompatibilityView(game: game, viewModel: viewModel) }
                        }
                        Section {
                            MenuNavigationLink("Runtime Settings") { SettingsView(viewModel: viewModel) }
                            if !viewModel.usesMadeiraRuntime { MenuNavigationLink("Windows Environment") { GameEnvironmentView(game: game, viewModel: viewModel) } }
                        }
                    }.iridiumListChrome().navigationTitle("Advanced")
                }
            }
            Section {
                MenuButton("Remove from Library", role: .destructive) { confirmRemoval = true }
                    .disabled(viewModel.activeRuntimePlayerSession?.gameID == game.id)
            } footer: { Text("Removes only this library entry. Game files, artwork, and saves stay on your device.") }
        }
        .iridiumListChrome().navigationTitle("Game Options").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $rename) { LibraryAppearanceEditor(game: game, artwork: artwork) }
        .sheet(isPresented: $confirmRemoval) {
            NavigationStack {
                List {
                    Section {
                        Text("Game files and saves will not be deleted.")
                        MenuButton("Cancel", role: .cancel) { confirmRemoval = false }
                        MenuButton("Remove", role: .destructive) {
                            viewModel.removeLibraryEntry(game); confirmRemoval = false; dismiss()
                        }
                    }
                }.iridiumListChrome().navigationTitle("Remove from Library?")
                    .navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium])
        }

    }
}
