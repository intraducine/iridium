import SwiftUI
import IridiumCore

struct LibraryShelf: View {
    let games: [GameRecord]
    @ObservedObject var artwork: LibraryArtwork
    @ObservedObject var controller: LibraryController
    let play: (GameRecord) -> Void
    let disabled: (GameRecord) -> Bool
    let launchTitle: (GameRecord) -> String
    var launchDetail: (GameRecord) -> String? = { _ in nil }
    let details: (GameRecord) -> Void
    @Binding var search: String
    @Binding var favorites: Bool
    @Binding var selectedID: UUID?
    var importGame: () -> Void = {}
    var settings: () -> Void = {}
    var acceptsControllerInput = true
    @State private var visible = false
    private enum MenuFocus: Int { case filter, search, add, settings, play, options, covers }
    @State private var menuFocus: MenuFocus = .covers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var searching: Bool
    @State private var searchPresented = false
    @State private var carouselPosition = ScrollPosition(idType: Int.self)
    @State private var carouselIsUserDriven = false
    private var filtered: [GameRecord] {
        games.filter { (!favorites || artwork.appearance($0.id).favorite) && (search.isEmpty || artwork.title($0).localizedCaseInsensitiveContains(search)) }
    }
    private var selected: GameRecord? { filtered.first { $0.id == selectedID } ?? filtered.first }
    var body: some View {
        GeometryReader { safeGeometry in
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height && !typeSize.isAccessibilitySize
            let sideInset: CGFloat = (landscape ? 32 : 24) + max(0, (geometry.size.width - safeGeometry.size.width) / 2)
            ZStack {
                LibraryBackdrop(image: selected.flatMap { artwork.displayImage(artwork.appearance($0.id).background) },
                    isLoading: selected.map { artwork.appearance($0.id).background != nil } ?? false,
                    position: selected.map { artwork.appearance($0.id).backgroundY } ?? 0.5,
                    reduceMotion: reduceMotion)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.6), location: 0),
                        .init(color: .black.opacity(0.6), location: 0.3),
                        .init(color: .black.opacity(0.12), location: 0.6),
                        .init(color: .black.opacity(0.5), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }.overlay {
                    LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                }.ignoresSafeArea()
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: landscape ? 10 : 24) {
                        header(landscape: landscape)
                        if searchPresented {
                        HStack(spacing: 16) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                TextField("Search games", text: $search, prompt: Text("Search games").foregroundStyle(.white.opacity(0.7)))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($searching).submitLabel(.search)
                                    .onSubmit { searching = false }
                                    .onKeyPress(.escape) { search = ""; searching = false; searchPresented = false; return .handled }
                                    .frame(height: 44)
                                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                            }.padding(.horizontal, 16).frame(minHeight: 48).libraryPanel()
                            Button("Done") {
                                search = ""
                                searching = false
                                searchPresented = false
                            }.libraryGlass().frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("closeLibrarySearch").keyboardShortcut(.cancelAction)
                        }
                        }
                        if let selected {
                            if !searchPresented {
                            if landscape {
                                HStack(spacing: 24) {
                                    Text(artwork.title(selected)).font(.title2.bold())
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    actions(selected, landscape: true, showReason: false).fixedSize()
                                }
                                if let reason = launchDetail(selected) {
                                    Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text(artwork.title(selected)).font(.largeTitle.bold())
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    actions(selected, landscape: false)
                                }
                            }
                            }

                            GeometryReader { shelfGeometry in
                                let coverHeight = max(1, min(max(1, geometry.size.width - 2 * sideInset - 8) * 1.5, shelfGeometry.size.height - (filtered.contains { artwork.appearance($0.id).cover == nil } ? 52 : 16)))
                                carousel(selected, coverHeight: coverHeight, width: geometry.size.width, sideInset: sideInset, landscape: landscape)
                            }

                        } else {
                            if !search.isEmpty {
                                ContentUnavailableView.search(text: search)
                            } else if favorites {
                                ContentUnavailableView("No Favorites Yet", systemImage: "heart",
                                    description: Text("Add games through Game Options."))
                            } else {
                                ContentUnavailableView("Add Your First Game", systemImage: "gamecontroller",
                                    description: Text("Use Add Game (+) above to choose a Windows game folder. Include its .exe file and game data. Artwork is optional."))
                            }
                        }
                    }.padding(.horizontal, sideInset).padding(.vertical, 8)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    if !searchPresented && controller.showingControllerHints {
                        ControllerHelp().padding(.horizontal, sideInset).padding(.bottom, 8)
                            .opacity(controller.showingControllerHints ? 1 : 0)
                            .accessibilityHidden(!controller.showingControllerHints)
                    }
                }
            }.preferredColorScheme(.dark)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if controller.showingControllerHints { controller.showingControllerHints = false }
        })
        .onChange(of: searchPresented) { _, open in
            controller.backAction = open ? { search = ""; searching = false; searchPresented = false } : nil
        }
        .onDisappear { visible = false; controller.libraryNavigationActive = false; controller.backAction = nil }
        .onChange(of: acceptsControllerInput) { _, accepts in controller.libraryNavigationActive = visible && accepts }
        .onReceive(controller.input) { action in
            guard visible && acceptsControllerInput else { return }
            handleController(action)
        }
        .onKeyPress(.escape) {
            guard searchPresented else { return .ignored }
            search = ""; searching = false; searchPresented = false
            return .handled
        }
        .onAppear { visible = true; controller.libraryNavigationActive = acceptsControllerInput; artwork.backdropGameID = selected?.id }
        .onChange(of: selected?.id) { _, id in artwork.backdropGameID = id }

    }
    private func carousel(_ selected: GameRecord, coverHeight: CGFloat, width: CGFloat, sideInset: CGFloat, landscape: Bool) -> some View {
        let compact = searchPresented && landscape
        let itemWidth = compact ? min(240, width * 0.4) : coverHeight * 2 / 3 + 8

        return                             Group {
                                ScrollView(.horizontal) {
                                    // ponytail: exact shelf widths avoid estimated scroll targets after keyboard and rotation changes.
                                    // Use a collection view if very large libraries need view virtualization.
                                    HStack(alignment: .top, spacing: 18) {
                                        ForEach(filtered.indices, id: \.self) { slot in
                                            let game = filtered[slot]
                                            Button {
                                                searching = false; searchPresented = false; search = ""
                                                selectedID = game.id; menuFocus = .covers
                                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) { carouselPosition.scrollTo(id: slot, anchor: .leading) }
                                            } label: {
                                                if compact {
                                                    HStack(spacing: 10) {
                                                        ArtworkImage(image: artwork.displayImage(artwork.appearance(game.id).cover), title: "", fit: true)
                                                            .frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 4))
                                                        Text(artwork.title(game)).font(.body).lineLimit(1)
                                                    }.padding(.horizontal, 8).frame(width: itemWidth, height: 44)
                                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                                } else {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    ArtworkImage(image: artwork.displayImage(artwork.appearance(game.id).cover), title: "", position: artwork.appearance(game.id).coverY, fit: !artwork.appearance(game.id).customCover)
                                                        .frame(height: coverHeight)
                                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                                        .padding(4)
                                                        .overlay { RoundedRectangle(cornerRadius: 22).stroke(game.id == selected.id && (!controller.showingControllerHints || menuFocus == .covers) ? .white : .clear, lineWidth: 3) }
                                                    if artwork.appearance(game.id).cover == nil {
                                                        Text(artwork.title(game)).font(.headline).lineLimit(1).truncationMode(.tail).padding(.horizontal, 5)
                                                    }
                                                }.frame(width: itemWidth)
                                                }
                                            }.buttonStyle(.plain).id(slot)
                                                .focusable(interactions: .edit)

                                                .accessibilityLabel(artwork.title(game))
                                                .accessibilityIdentifier(game.id == selected.id ? "selectedGameCover" : "gameCover-\(slot)")
                                                .accessibilityAddTraits(game.id == selected.id ? [.isSelected] : [])
                                                .accessibilityHint("Select game. Use Play to launch.")
                                        }
                                    }.scrollTargetLayout().padding(.vertical, 4)
                                        .padding(.trailing, max(0, width - 2 * sideInset - itemWidth))
                                }.scrollIndicators(.hidden)
                                    .scrollTargetBehavior(.viewAligned)
                                    .contentMargins(.horizontal, sideInset, for: .scrollContent)
                                    .scrollPosition($carouselPosition, anchor: .leading)
                                    .scrollClipDisabled()
                                    .frame(width: width, height: compact ? 52 : coverHeight + 16)
                                    .padding(.horizontal, -sideInset)
                                    .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
                                    .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
                                    .accessibilityIdentifier("gameCarousel")
                                    .id(filtered.map(\.id))
                                    .onAppear { resetCarousel() }
                                    .onChange(of: filtered.map(\.id)) { _, _ in resetCarousel() }
                                    .onScrollGeometryChange(for: Int.self) { scroll in
                                        Int(((scroll.contentOffset.x + scroll.contentInsets.leading) / (itemWidth + 18)).rounded())
                                    } action: { _, slot in
                                        guard carouselIsUserDriven, filtered.indices.contains(slot) else { return }
                                        selectedID = filtered[slot].id
                                    }
                                    .onChange(of: selectedID) { _, _ in
                                        if !carouselIsUserDriven {
                                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) { resetCarousel() }
                                        }
                                    }
                                    .onScrollPhaseChange { _, phase in
                                        carouselIsUserDriven = phase == .tracking || phase == .interacting || phase == .decelerating
                                        if phase == .idle { resetCarousel() }
                                    }
                                    .onChange(of: width) { _, _ in resetCarousel() }
                            }
    }
    private func resetCarousel() {
        if let slot = filtered.firstIndex(where: { $0.id == selected?.id }) {
            carouselPosition.scrollTo(id: slot, anchor: .leading)
        }
    }
    private func handleController(_ input: LibraryController.Input) {
        if input == .back {
            if searchPresented { search = ""; searching = false; searchPresented = false }
            menuFocus = .covers
            return
        }
        if input == .previousTab || input == .nextTab {
            favorites = input == .nextTab
            menuFocus = .covers
            return
        }
        if input == .play {
            if !searchPresented, let selected, !disabled(selected) { play(selected) }
            return
        }

        if input == .options, !searchPresented, let selected { details(selected); return }
        switch input {
        case .left, .right:
            let step = input == .left ? -1 : 1
            if menuFocus == .covers { moveSelection(step) }
            else if menuFocus == .filter {
                if step > 0 && favorites { menuFocus = .search }
                else { favorites = step > 0 }
            }
            else {
                let range = menuFocus.rawValue <= MenuFocus.settings.rawValue ? 0...3 : 4...5
                menuFocus = MenuFocus(rawValue: min(range.upperBound, max(range.lowerBound, menuFocus.rawValue + step)))!
            }
        case .up:
            switch menuFocus {
            case .covers: menuFocus = .play
            case .play, .options: menuFocus = .search
            default: break
            }
        case .down:
            menuFocus = menuFocus.rawValue < MenuFocus.play.rawValue && selected != nil ? .play : .covers
            if selected == nil { menuFocus = .add }
        case .select:
            switch menuFocus {
            case .filter: favorites.toggle()
            case .search: searchPresented = true; searching = true
            case .add: importGame()
            case .settings: settings()
            case .covers:
                if searchPresented { search = ""; searching = false; searchPresented = false }
                menuFocus = .play
            case .play: if let selected, !disabled(selected) { play(selected) }
            case .options: if let selected { details(selected) }
            }
        default: break
        }
    }
    private func controllerFocus(_ target: MenuFocus) -> some View {
        Capsule()
            .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
            .padding(-5)
            .opacity(controller.showingControllerHints && menuFocus == target ? 1 : 0)
            .allowsHitTesting(false)
    }
    private func moveSelection(_ offset: Int) {
        guard filtered.count > 1 else { return }
        let index = filtered.firstIndex(where: { $0.id == selected?.id }) ?? 0
        let next = min(filtered.count - 1, max(0, index + offset))
        guard next != index else { return }
        carouselIsUserDriven = false
        selectedID = filtered[next].id
    }

    private func header(landscape: Bool) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Text("Iridium").font(landscape ? .title2.bold() : .title.bold())
                if landscape { libraryFilter.frame(minWidth: 180, maxWidth: 300) }
                Spacer(minLength: 8)
                Button { menuFocus = .search; searchPresented.toggle(); searching = searchPresented } label: {
                    Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                }.overlay { controllerFocus(.search) }.onHover { if $0 { menuFocus = .search } }.accessibilityLabel("Search")
                Button { menuFocus = .add; importGame() } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .overlay { controllerFocus(.add) }.onHover { if $0 { menuFocus = .add } }.focusable(interactions: .edit).accessibilityLabel("Add Game").keyboardShortcut("o", modifiers: .command)
                Button { menuFocus = .settings; settings() } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .overlay { controllerFocus(.settings) }.onHover { if $0 { menuFocus = .settings } }.focusable(interactions: .edit).accessibilityLabel("Settings")
            }.buttonStyle(.plain)
            if !landscape { libraryFilter }
        }
    }
    private var libraryFilter: some View {
        HStack(spacing: 10) {
        if controller.showingControllerHints { shoulderHint("LB") }
        Picker("Library filter", selection: Binding(get: { favorites }, set: { menuFocus = .filter; favorites = $0 })) {
            Text("All Games").tag(false)
            Text("Favorites").tag(true)
        }.pickerStyle(.segmented).overlay { controllerFocus(.filter) }.onHover { if $0 { menuFocus = .filter } }
        if controller.showingControllerHints { shoulderHint("RB") }
        }
    }
    private func shoulderHint(_ label: String) -> some View {
        Text(label).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 3)
            .overlay { UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 7, bottomTrailingRadius: 7, topTrailingRadius: 4).stroke(.white.opacity(0.7), lineWidth: 1) }
            .accessibilityHidden(true)
    }
    private func actions(_ game: GameRecord, landscape: Bool, showReason: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button { menuFocus = .play; searching = false; play(game) } label: {
                    Label { Text(launchTitle(game)).fontWeight(.semibold) } icon: { inputIcon("play.fill", position: 1) }
                        .padding(.horizontal, 12).frame(minHeight: 34)
                }.libraryGlass(prominent: true).disabled(disabled(game)).overlay { controllerFocus(.play) }.onHover { if $0 { menuFocus = .play } }
                Button { menuFocus = .options; details(game) } label: {
                    Label { Text("Game Options") } icon: { Group {
                        if controller.showingControllerHints { Image(systemName: "line.3.horizontal.circle") }
                        else { Image(systemName: "ellipsis") }
                    } }
                        .frame(minHeight: 44)
                }.buttonStyle(.plain).overlay { controllerFocus(.options) }.onHover { if $0 { menuFocus = .options } }.focusable(interactions: .edit).accessibilityIdentifier("gameOptions")
            }
            if showReason, let reason = launchDetail(game) {
                Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(landscape ? 1 : 2)
            }
        }
    }
    @ViewBuilder private func inputIcon(_ touchSymbol: String, position: Int?) -> some View {
        if controller.showingControllerHints, let position {
            ZStack {
                ForEach(0..<4) { index in
                    Circle().fill(.primary.opacity(index == position ? 1 : 0.25))
                        .frame(width: 7, height: 7)
                        .offset(x: index == 1 ? -7 : index == 3 ? 7 : 0,
                                y: index == 0 ? 7 : index == 2 ? -7 : 0)
                }
            }.frame(width: 24, height: 24).accessibilityHidden(true)
        } else { Image(systemName: touchSymbol) }
    }
}

private struct LibraryGlass: ViewModifier {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent && isEnabled { content.buttonStyle(.glassProminent).tint(.white).foregroundStyle(.black) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent && isEnabled { content.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black) }
            else { content.buttonStyle(.bordered) }
        }
    }
}
extension View {
    func libraryGlass(prominent: Bool = false) -> some View { modifier(LibraryGlass(prominent: prominent)) }
}

private struct LibraryPanel: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}
private extension View {
    func libraryPanel() -> some View { modifier(LibraryPanel()) }
}

/// Shared backdrop for native settings, editors, activity and game details.
struct IridiumPageSurface: ViewModifier {
    @ObservedObject var artwork: LibraryArtwork
    var gameID: UUID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                ZStack {
                    Color.black
                    if !reduceTransparency, let id = gameID ?? artwork.backdropGameID,
                       let image = artwork.displayImage(artwork.appearance(id).background) {
                        ArtworkImage(image: image, title: "", position: artwork.appearance(id).backgroundY)
                            .blur(radius: 14).overlay(.black.opacity(0.62))
                    }
                }.ignoresSafeArea()
            }
            // Leave native controls on their semantic tint. White is only a local
            // Play button fill, paired with black text, never a page-wide accent.
            .preferredColorScheme(.dark)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
extension View {
    @MainActor func iridiumPageSurface(artwork: LibraryArtwork? = nil, gameID: UUID? = nil) -> some View {
        modifier(IridiumPageSurface(artwork: artwork ?? .shared, gameID: gameID))
    }
    @MainActor func iridiumListChrome(onBack: (() -> Void)? = nil) -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 54)
            .iridiumPageSurface()
            .controllerMenuScope(onBack: onBack)
    }
}


// Keep image layers alive while fading, so another selection can reverse their current opacity.
private struct LibraryBackdrop: UIViewRepresentable {
    let image: UIImage?
    let isLoading: Bool
    let position: Double
    let reduceMotion: Bool

    func makeUIView(context: Context) -> Canvas { Canvas() }
    func updateUIView(_ view: Canvas, context: Context) {
        guard image != nil || !isLoading else { return }
        view.show(image, position: position, animated: !reduceMotion)
    }

    final class Canvas: UIView {
        private var target: CroppedImage?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show(_ image: UIImage?, position: Double, animated: Bool) {
            guard target != nil || image != nil else { return }
            guard target?.image !== image || target?.position != position else { return }
            let hadImage = target != nil
            let layers = subviews.compactMap { $0 as? CroppedImage }
            var next = layers.first { $0.image === image && $0.position == position }
            if next == nil, let image {
                let layer = CroppedImage(image: image)
                layer.position = position
                layer.alpha = 0
                addSubview(layer)
                next = layer
            }
            target = next
            setNeedsLayout()
            layoutIfNeeded()
            UIView.animate(withDuration: animated && hadImage ? 0.24 : 0, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                for layer in self.subviews { layer.alpha = layer === next ? 1 : 0 }
            } completion: { [weak self] finished in
                guard finished, let self, self.target === next else { return }
                self.subviews.filter { $0 !== next }.forEach { $0.removeFromSuperview() }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            for case let layer as CroppedImage in subviews {
                guard let image = layer.image else { continue }
                let scale = max(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                layer.frame = CGRect(x: (bounds.width - size.width) / 2,
                    y: (bounds.height - size.height) * layer.position, width: size.width, height: size.height)
            }
        }
        private final class CroppedImage: UIImageView { var position = 0.5 }
    }
}
