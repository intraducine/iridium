import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import IridiumCore

struct LibraryAppearanceEditor: View {
    let game: GameRecord
    @ObservedObject var artwork: LibraryArtwork
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var query = ""
    @State private var matches: [ArtworkMatch] = []
    @State private var searching = false
    @State private var searched = false
    @State private var failure: String?
    @State private var photo: PhotosPickerItem?
    @State private var photosPresented = false
    @Environment(\.menuController) private var controller
    @State private var background = false
    @State private var files = false
    @State private var connection = false

    var body: some View {
        NavigationStack {
            List {
                Section("Display name") {
                    MenuTextField("Game name", text: $title)
                    MenuButton("Save Name") { perform { try artwork.update(game.id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines) } } }
                    MenuButton("Use Original Name") { perform { try artwork.update(game.id) { $0.title = nil }; title = game.title } }
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                Section {
                    Picker("Image", selection: $background) {
                        Text("Cover").tag(false)
                        Text("Background").tag(true)
                    }.pickerStyle(.segmented).menuFocusable(action: { background.toggle() }, adjust: { background = $0 > 0 })
                    ArtworkImage(image: artwork.displayImage(background ? item.background : item.cover), title: artwork.title(game), position: background ? item.backgroundY : item.coverY)
                        .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 16))
                    MenuButton("Choose from Photos", systemImage: "photo") { photosPresented = true }
                        .photosPicker(isPresented: $photosPresented, selection: $photo, matching: .images)
                    MenuButton { files = true } label: { Label("Choose from Files", systemImage: "folder") }
                    if (background ? item.background : item.cover) != nil {
                        Slider(value: Binding(get: { background ? item.backgroundY : item.coverY }, set: { value in
                            perform { try artwork.update(game.id) { if background { $0.backgroundY = value } else { $0.coverY = value } } }
                        }), in: 0...1) { Text("Crop position") }
                        .accessibilityLabel("Vertical crop position")
                        .menuFocusable(adjust: { direction in
                            perform { try artwork.update(game.id) {
                                if background { $0.backgroundY = min(1, max(0, $0.backgroundY + Double(direction) * 0.05)) }
                                else { $0.coverY = min(1, max(0, $0.coverY + Double(direction) * 0.05)) }
                            } }
                        })
                        MenuButton("Remove Image", role: .destructive) {
                            perform { try artwork.update(game.id) {
                                // An explicitly empty image is also a user choice.
                                if background { $0.background = nil; $0.customBackground = true } else { $0.cover = nil; $0.customCover = true }
                            } }
                        }
                        MenuButton("Use Matched Artwork") {
                            perform { try artwork.update(game.id) {
                                if background { $0.customBackground = false } else { $0.customCover = false }
                            } }
                            if let id = item.matchID, let name = item.matchName { select(ArtworkMatch(id: id, name: name, source: item.matchSource)) }
                        }.disabled(item.matchID == nil || searching)
                    }
                } header: { Text("Artwork") } footer: { Text("Your images stay on this iPhone. Online matches never replace your custom images.") }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                Section {
                    if let name = item.matchName {
                        MenuValue("Matched game", value: name)
                        if let id = item.matchID {
                            Link("Artwork Source", destination: URL(string: item.matchSource == "steam" ? "https://store.steampowered.com/app/\(id)" : "https://www.steamgriddb.com/game/\(id)")!)
                        }
                        MenuButton("Remove Match", role: .destructive) { perform { try artwork.removeMatch(game.id) } }
                    } else { Text("No online match. Artwork does not affect launch availability.").foregroundStyle(.secondary) }
                    MenuToggle("Automatic matching", isOn: Binding(get: { item.automaticLookup }, set: { value in perform { try artwork.update(game.id) { $0.automaticLookup = value } } }))
                    MenuTextField("Search game title", text: $query).onSubmit { search() }
                    MenuButton("Find Matches") { search() }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if searching { ProgressView("Finding artwork…") }
                    if searched && matches.isEmpty && !searching { Text("No matches. Keep your local name or use your own artwork.").foregroundStyle(.secondary) }
                    ForEach(matches) { match in
                        MenuButton(match.name) { select(match) }.disabled(searching)
                    }
                    MenuButton("Artwork Settings") { connection = true }
                } header: { Text("Game match") } footer: { Text("The game title or a local Steam app ID is sent to the artwork catalog. A match changes artwork only, never game files or saves.") }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                if let failure { Section { Text(failure).foregroundStyle(.red) }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden) }
            }
            .controllerMenuScope().listStyle(.insetGrouped).environment(\.defaultMinListRowHeight, 54)
            .iridiumPageSurface(artwork: artwork, gameID: game.id)
            .navigationTitle("Game Appearance").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .onAppear { title = artwork.title(game); query = LibraryArtwork.query(game.title) }
            .sheet(isPresented: $connection) { ArtworkConnectionView(artwork: artwork) }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
                perform {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25 * 1024 * 1024 else { throw ArtworkError.message("Choose an image smaller than 25 MB.") }
                    try artwork.setImage(Data(contentsOf: url), id: game.id, background: background)
                }
            }
            .onChange(of: files || photosPresented) { _, presented in controller?.nativeMenuActive = presented }
            .onChange(of: photo) { _, value in
                let target = background
                Task {
                    do {
                        guard let data = try await value?.loadTransferable(type: Data.self) else { return }
                        try artwork.setImage(data, id: game.id, background: target)
                        photo = nil
                    } catch { failure = error.localizedDescription }
                }
            }
        }
    }
    private var item: LibraryAppearance { artwork.appearance(game.id) }
    private func perform(_ action: () throws -> Void) { do { try action(); failure = nil } catch { failure = error.localizedDescription } }
    private func search() {
        searching = true; failure = nil; matches = []
        let requested = query
        Task {
            defer { searching = false }
            do {
                let results = try await artwork.search(requested)
                guard requested == query else { return }
                matches = results; searched = true
            } catch { failure = error.localizedDescription }
        }
    }
    private func select(_ match: ArtworkMatch) {
        searching = true; failure = nil
        Task {
            defer { searching = false }
            do { try await artwork.apply(match, to: game.id); matches = []; searched = false } catch { failure = error.localizedDescription }
        }
    }
}

struct ArtworkConnectionView: View {
    @ObservedObject var artwork: LibraryArtwork
    @State private var key = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Game artwork uses the public Steam catalog by default, with no login. Connect SteamGridDB below to use its artwork catalog instead.")
                    Link("Get a SteamGridDB API Key", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                    MenuTextField("API key", text: $key, secure: true).textInputAutocapitalization(.never).autocorrectionDisabled()
                    MenuButton("Save Connection") {
                        do { try artwork.connect(key); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if artwork.connected {
                        MenuButton("Disconnect", role: .destructive) {
                            do { try artwork.connect(""); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                } footer: { Text("The key is stored in Keychain. Disconnecting keeps downloaded artwork and returns to the public catalog. Custom images always work offline.") }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .controllerMenuScope().listStyle(.insetGrouped).environment(\.defaultMinListRowHeight, 54)
            .iridiumPageSurface(artwork: artwork)
            .navigationTitle("Artwork Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
    }
}

struct ArtworkImage: View {
    let image: UIImage?
    let title: String
    var position = 0.5
    var fit = false
    var body: some View {
        GeometryReader { geometry in
            if let image, fit {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
            } else if let image {
                let scale = max(geometry.size.width / max(image.size.width, 1), geometry.size.height / max(image.size.height, 1))
                Image(uiImage: image).resizable()
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .offset(x: (geometry.size.width - image.size.width * scale) / 2, y: (geometry.size.height - image.size.height * scale) * position)
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    VStack(spacing: 12) {
                        Image(systemName: "gamecontroller").resizable().scaledToFit()
                            .frame(width: min(48, geometry.size.width * 0.5)).accessibilityHidden(true)
                        if !title.isEmpty { Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).lineLimit(1).truncationMode(.tail) }
                    }.padding(min(24, geometry.size.width * 0.1)).frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}
