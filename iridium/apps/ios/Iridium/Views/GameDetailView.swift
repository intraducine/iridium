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
    @State private var confirmRefresh = false

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
            if viewModel.usesMadeiraRuntime {
                Section {
                    MenuButton("Refresh Game Copy", systemImage: "arrow.clockwise") { confirmRefresh = true }
                        .disabled(viewModel.refreshingGameCopy || viewModel.isLaunchActionDisabled(for: game))
                } footer: {
                    Text("Refreshes the isolated runtime copy from the imported files. The current copy is kept as a backup. Restart Iridium before refreshing after a game session.")
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
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                Text("Game Options").font(.headline)
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .libraryGlass().buttonBorderShape(.circle)
                    .accessibilityLabel("Back")
                    Spacer()
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .confirmationDialog("Refresh the isolated game copy?", isPresented: $confirmRefresh, titleVisibility: .visible) {
            Button("Refresh and Keep Backup") { viewModel.refreshMadeiraGameCopy(game) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conflicting files, including any saves stored in the game folder, will be replaced by the imported versions. The complete previous copy is kept in Documents/MadeiraTestPrefixes/<game ID>/game-backup-<ID>. Windows profile saves are not replaced. Updating first copies the entire game and needs extra storage.")
        }
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
