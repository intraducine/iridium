// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct IridiumArtworkEditor: View {
    let game: IridiumGame
    var embedded = false
    var onBack: (() -> Void)?
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var query = ""
    @State private var background = false
    @State private var matches: [IridiumArtworkCandidate] = []
    @State private var busy = false
    @State private var searched = false
    @State private var failure: String?
    @State private var photo: PhotosPickerItem?
    @State private var photos = false
    @State private var files = false
    @State private var operation: Task<Void, Never>?
    @State private var request = UUID()
    @State private var focus = "name"
    @State private var guided = false
    @State private var backPending = false
    @FocusState private var field: String?
    @FocusState private var keyboard: Bool
    private var item: IridiumArtworkAppearance { artwork.appearance(game.id) }
    private var actions: [String] {
        ["name", "saveName", "image", "photos", "files", "crop", "remove", "restore", "automatic", "query", "search"]
            + matches.map { "match:" + $0.id } + (item.match == nil ? [] : ["removeMatch"])
    }
    var body: some View {
        Group {
            if embedded { content }
            else {
                NavigationStack {
                    content.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
        .onAppear { backPending = false; title = artwork.title(game); query = game.title; keyboard = true }
        .onDisappear { operation?.cancel(); request = UUID() }
    }
    private var content: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Display name") {
                    TextField("Game name", text: $title).focused($field, equals: "name").id("name")
                    row("saveName", "Save Name", icon: "checkmark") {
                        saveName()
                    }
                }
                Section {
                    Picker("Image", selection: $background) { Text("Cover").tag(false); Text("Background").tag(true) }
                        .pickerStyle(.segmented).id("image")
                    IridiumGameArtwork(game: game, backdrop: background)
                        .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 16))
                    row("photos", "Choose from Photos", icon: "photo") { photos = true }
                        .photosPicker(isPresented: $photos, selection: $photo, matching: .images)
                    row("files", "Choose from Files", icon: "folder") { files = true }
                    Slider(value: Binding(get: { background ? item.backgroundY : item.coverY }, set: { value in
                        perform { try artwork.update(game.id) { if background { $0.backgroundY = value } else { $0.coverY = value } } }
                    }), in: 0...1) { Text("Crop position") }.id("crop").accessibilityLabel("Vertical crop position")
                    row("remove", "Remove Image", icon: "trash") {
                        perform { try artwork.update(game.id) {
                            if background { $0.background = nil; $0.customBackground = true }
                            else { $0.cover = nil; $0.customCover = true }
                        } }
                    }
                    row("restore", "Use Automatic Artwork", icon: "arrow.counterclockwise") {
                        perform { try artwork.update(game.id) {
                            if background { $0.customBackground = false; $0.ignoreLegacyBackground = true }
                            else { $0.customCover = false; $0.ignoreLegacyCover = true }
                            $0.match = nil; $0.automaticLookup = true
                        } }
                        run { await artwork.prepare(game, retry: true) }
                    }
                } header: { Text("Artwork") } footer: {
                    Text("Custom images stay on this device. Existing artwork is kept until you choose automatic artwork for that image. Removing an image keeps it empty until you choose another image or automatic artwork.")
                }
                Section {
                    Toggle("Automatic matching", isOn: Binding(get: { item.automaticLookup }, set: { value in
                        perform { try artwork.update(game.id) { $0.automaticLookup = value } }
                        if value { run { await artwork.prepare(game, retry: true) } }
                    })).id("automatic")
                    if let match = item.match {
                        LabeledContent("Matched game", value: match.title)
                        Text(match.source == "steam" ? "Source: Steam public catalog" : "Source: Libretro thumbnails")
                            .font(.caption).foregroundStyle(.secondary)
                        row("removeMatch", "Remove Match", icon: "xmark.circle") { perform { try artwork.removeMatch(game.id) } }
                    }
                    TextField("Search game title", text: $query).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($field, equals: "query").id("query").onSubmit(search)
                    row("search", "Find Matches", icon: "magnifyingglass", action: search)
                    if busy { ProgressView("Finding artwork…") }
                    if let note = artwork.statuses[game.id], !busy {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if searched && matches.isEmpty && !busy { Text("No matches. Try another title or choose your own image.").foregroundStyle(.secondary) }
                    ForEach(matches) { candidate in
                        row("match:" + candidate.id, candidate.title, icon: "photo") {
                            run { try await artwork.select(candidate, for: game); matches = []; searched = false }
                        }
                    }
                } header: { Text("Game match") } footer: {
                    Text(game.platform == .windows ?
                        "Title searches use Steam's public catalog. A match changes appearance only; game files, saves and runtime settings are unchanged." :
                        "Matches come from Libretro's public artwork catalog for \(game.platform.title). Ambiguous titles need your choice. Artwork is optional and games remain playable offline.")
                }
                if let failure = failure ?? artwork.error { Section { Text(failure).foregroundStyle(.red) } }
            }
            .iridiumPageSurface().navigationTitle("Rename & Artwork")
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { command("back") }
                    }
                }
            }
            .focusable().focusEffectDisabled().focused($keyboard)
            .onChange(of: focus) { _, id in proxy.scrollTo(id, anchor: .center) }
            .onChange(of: query) { _, _ in
                operation?.cancel(); request = UUID(); busy = false; matches = []; searched = false
            }
            .onReceive(LibraryController.shared.commands) { command($0) }
            .onKeyPress(.upArrow) { guard field == nil else { return .ignored }; command("up"); return .handled }
            .onKeyPress(.downArrow) { guard field == nil else { return .ignored }; command("down"); return .handled }
            .onKeyPress(.leftArrow) { guard field == nil else { return .ignored }; command("left"); return .handled }
            .onKeyPress(.rightArrow) { guard field == nil else { return .ignored }; command("right"); return .handled }
            .onKeyPress(.return) { guard field == nil else { return .ignored }; command("accept"); return .handled }
            .onKeyPress(.escape, phases: .down) { _ in command("back"); return .handled }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    let target = background
                    run {
                        let data = try await Task.detached(priority: .utility) {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                            guard let size, size <= 25 * 1024 * 1024 else { throw LibraryError.message("Choose an image smaller than 25 MB.") }
                            return try Data(contentsOf: url)
                        }.value
                        try Task.checkCancellation()
                        try await artwork.setImage(data, for: game.id, background: target)
                    }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
                }
            }
            .onChange(of: photo) { _, value in
                guard let value else { return }
                let target = background
                run {
                    defer { photo = nil }
                    guard let data = try await value.loadTransferable(type: Data.self) else { return }
                    try Task.checkCancellation()
                    try await artwork.setImage(data, for: game.id, background: target)
                }
            }
        }
    }
    private func row(_ id: String, _ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }.id(id)
            .listRowBackground(guided && focus == id ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
    }
    private func saveName() {
        perform { try artwork.update(game.id) { $0.title = IridiumArtworkAppearance.titleOverride(title) } }
        field = nil; keyboard = true
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = error.localizedDescription }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        operation?.cancel(); let token = UUID(); request = token; busy = true; failure = nil
        operation = Task {
            defer { if request == token { busy = false } }
            do { try await action() }
            catch is CancellationError { }
            catch { if request == token, !Task.isCancelled, (error as? URLError)?.code != .cancelled { failure = error.localizedDescription } }
        }
    }
    private func search() {
        let requested = query
        field = nil; keyboard = true
        run {
            let found = try await artwork.search(requested, platform: game.platform)
            try Task.checkCancellation()
            guard query == requested else { return }
            matches = found; searched = true
        }
    }
    private func command(_ value: String) {
        if value == "back" {
            switch IridiumArtworkBackPolicy.action(pickerPresented: files || photos, fieldFocused: field != nil) {
            case .ignore: break
            case .endEditing: field = nil; keyboard = true
            case .leaveEditor:
                if embedded {
                    guard !backPending else { return }
                    backPending = true
                    IridiumArtworkBackPolicy.leaveAfterCurrentDelivery { onBack?() }
                } else { dismiss() }
            }
            return
        }
        guard !files, !photos, field == nil else { return }
        guided = true
        if value == "up" || value == "down" {
            let index = actions.firstIndex(of: focus) ?? 0
            focus = actions[min(max(index + (value == "up" ? -1 : 1), 0), actions.count - 1)]
        } else if ["left", "right"].contains(value), focus == "crop" {
            let amount = value == "left" ? -0.05 : 0.05
            perform { try artwork.update(game.id) {
                if background { $0.backgroundY = min(1, max(0, $0.backgroundY + amount)) }
                else { $0.coverY = min(1, max(0, $0.coverY + amount)) }
            } }
        } else if value == "accept" {
            switch focus {
            case "name", "query": field = focus
            case "saveName": saveName()
            case "image": background.toggle()
            case "photos": photos = true
            case "files": files = true
            case "search": search()
            case "automatic":
                perform { try artwork.update(game.id) { $0.automaticLookup.toggle() } }
                if item.automaticLookup { run { await artwork.prepare(game, retry: true) } }
            case "removeMatch": perform { try artwork.removeMatch(game.id) }
            case "remove": perform { try artwork.update(game.id) {
                if background { $0.background = nil; $0.customBackground = true }
                else { $0.cover = nil; $0.customCover = true }
            } }
            case "restore":
                perform { try artwork.update(game.id) {
                    if background { $0.customBackground = false; $0.ignoreLegacyBackground = true }
                    else { $0.customCover = false; $0.ignoreLegacyCover = true }
                    $0.match = nil; $0.automaticLookup = true
                } }
                run { await artwork.prepare(game, retry: true) }
            default:
                if let candidate = matches.first(where: { "match:" + $0.id == focus }) {
                    run { try await artwork.select(candidate, for: game); matches = []; searched = false }
                }
            }
        }
    }
}
