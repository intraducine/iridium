// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import GameController

struct IridiumControlTarget: Identifiable {
    let platform: IridiumPlatform
    let title: String
    var gameID: UUID?
    var windowsLayout: IridiumControlLayoutState?
    var id: String { platform.rawValue + ":" + (gameID?.uuidString ?? "default") }
}

struct IridiumControlsSettingsView: View {
    var back: () -> Void = {}
    @State private var target: IridiumControlTarget?
    @State private var pending: IridiumControlTarget?
    @State private var pickingGame = false
    @State private var mapping = false
    @ObservedObject private var devices = IridiumPhysicalController.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    private var systems: [IridiumPlatform] { [.windows] + IridiumConsoleSystem.all.flatMap(\.platforms).filter { $0 != .gameBoyColor } }
    private var choices: [IridiumControlTarget] {
        library.entries.filter { $0.desktop != true }.map { entry in
            IridiumControlTarget(platform: .windows, title: artwork.title(IridiumGame(windows: entry)), gameID: entry.id,
                windowsLayout: entry.controls.map { IridiumControlLayoutState(controls: $0, visible: entry.touchControls,
                    size: entry.controlSize ?? 1, opacity: entry.controlOpacity ?? 0.7) })
        } + consoles.games.map { .init(platform: $0.platform, title: artwork.title(IridiumGame(console: $0)), gameID: $0.id) }
    }
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Group {

                Section {
                    ForEach(Array(systems.enumerated()), id: \.element) { index, platform in
                        Button { target = .init(platform: platform, title: platform.title) } label: {
                            HStack { Text(platform == .gameBoy ? "Game Boy / Color" : platform.title); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        }.id("controls.layout.\(platform.rawValue)").setupControllerTarget("controls.layout.\(platform.rawValue)", order: index, action: {
                            target = .init(platform: platform, title: platform.title)
                        })
                    }
                } header: { Text("Default Touch Layouts") } footer: { Text("Set a layout for a system, or save reusable profiles. Games can have their own controls.") }
                Section {
                    Button("Game Overrides", systemImage: "gamecontroller") { pickingGame = true }
                        .id("controls.games")
                        .setupControllerTarget("controls.games", order: 100, action: { pickingGame = true })
                }
                Section {
                    if devices.connectedDevices.isEmpty { Text("No devices connected").foregroundStyle(.secondary) }
                    ForEach(devices.connectedDevices) { device in
                        LabeledContent {
                            #if targetEnvironment(simulator)
                            Text("Forwarded by Mac").foregroundStyle(.secondary)
                            #else
                            Text("Connected").foregroundStyle(.secondary)
                            #endif
                        } label: {
                            Label(device.name, systemImage: device.symbol)
                        }
                    }
                } header: { Text("Connected Devices") } footer: { Text("Connect a controller, keyboard or mouse to use it here.") }
                Section("Controller Mapping") {
                    Button { mapping = true } label: {
                        HStack { Text("Windows Games"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }.id("controls.mapping").setupControllerTarget("controls.mapping", order: 200, action: { mapping = true })
                }
                Section("Touch Mouse · Windows") { LibraryPointerSettings() }
                Section("Haptics") { IridiumControlFeedbackSettings() }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Controls")
        .modifier(IridiumControlsNavigation(page: "controls", suspended: target != nil || pickingGame || mapping, back: back,
            knownTargets: { targets(reveal: { proxy.scrollTo($0, anchor: .center) }) }))
        }
        .navigationDestination(isPresented: $mapping) { IridiumWindowsControllerSettings() }
        .sheet(isPresented: $pickingGame, onDismiss: { target = pending; pending = nil }) {
            NavigationStack {
              ScrollViewReader { proxy in
                List {
                Group {

                    if choices.isEmpty { ContentUnavailableView("No Games Yet", systemImage: "gamecontroller", description: Text("Add a game to customize its controls. System defaults are available now.")) }
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        Button { selectGame(choice.id) } label: {
                            VStack(alignment: .leading) { Text(choice.title); Text(choice.platform.title).font(.caption).foregroundStyle(.secondary) }
                        }
                        .id("controls.game.\(choice.id)")
                        .setupControllerTarget("controls.game.\(choice.id)", order: index, action: { selectGame(choice.id) })
                    }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Game Controls")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { pickingGame = false }
                        .setupControllerTarget("controls.games.done", order: Int.max, action: { pickingGame = false })
                    } }
                    .modifier(IridiumControlsNavigation(page: "controlGames", suspended: !pickingGame, back: { pickingGame = false },
                        knownTargets: { choices.enumerated().map { index, choice in
                            .init(id: "controls.game.\(choice.id)", page: "controlGames", order: index, frame: .zero, enabled: true,
                                action: { selectGame(choice.id) }, reveal: { proxy.scrollTo("controls.game.\(choice.id)", anchor: .center) })
                        } + [.init(id: "controls.games.done", page: "controlGames", order: Int.max, frame: .zero, enabled: true,
                            action: { pickingGame = false })] }))
              }
            }
        }
        .fullScreenCover(item: $target) { IridiumTouchLayoutEditor(target: $0) }
    }
    private func selectGame(_ id: String) {
        guard let current = choices.first(where: { $0.id == id }) else { return }
        pending = current; pickingGame = false
    }
    private func targets(reveal: @escaping (String) -> Void) -> [SetupControllerTarget] {
        func row(_ id: String, _ order: Int, action: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) -> SetupControllerTarget {
            .init(id: id, page: "controls", order: order, frame: .zero, enabled: true, action: action, adjust: adjust, reveal: { reveal(id) })
        }
        var rows = systems.enumerated().map { index, platform in
            row("controls.layout.\(platform.rawValue)", index, action: { target = .init(platform: platform, title: platform.title) })
        }
        rows += [row("controls.games", 100, action: { pickingGame = true }), row("controls.mapping", 200, action: { mapping = true })]
        rows += LibraryPointerSettings().controllerTargets(page: "controls", reveal: reveal)
        rows.append(IridiumControlFeedbackSettings().controllerTarget(page: "controls", reveal: reveal))
        return rows
    }
}

/// Lists realize only nearby rows. Data supplies the complete order and current
/// actions; realized preferences supply geometry without dropping offscreen IDs.
enum IridiumControlsRows {
    static func merged(known: [SetupControllerTarget], rendered: [SetupControllerTarget], page: String) -> [SetupControllerTarget] {
        let geometry = Dictionary(rendered.filter { $0.page == page }.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let rows = known.isEmpty ? rendered : known
        var seen = Set<String>()
        return rows.filter { $0.page == page && seen.insert($0.id).inserted }.map { row in
            .init(id: row.id, page: page, order: row.order, frame: geometry[row.id] ?? row.frame, enabled: row.enabled,
                role: row.role, action: row.action, adjust: row.adjust, reveal: row.reveal)
        }
    }
}

/// Each visible Controls page routes only its own live registrations. Child
/// navigation and presented editors suspend the page behind them.
private struct IridiumControlsNavigation: ViewModifier {
    let page: String
    let suspended: Bool
    let back: () -> Void
    var knownTargets: () -> [SetupControllerTarget] = { [] }
    @StateObject private var focus = SetupControllerFocus()
    @State private var rendered: [SetupControllerTarget] = []
    @State private var visible = false
    @FocusState private var keyboard: Bool
    @Environment(\.scenePhase) private var scenePhase
    private var ownsCommands: Bool { visible && !suspended && scenePhase == .active }
    func body(content: Content) -> some View {
        content
            .environment(\.setupControllerFocus, focus)
            .environment(\.setupControllerPage, page)
            .onPreferenceChange(SetupControllerTargetsKey.self) { rendered = $0; updateTargets() }
            .focusable().focusEffectDisabled().focused($keyboard)
            .onAppear { visible = true; keyboard = true; updateTargets() }
            .onChange(of: knownTargets()) { _, _ in updateTargets() }
            .onDisappear { visible = false }
            .onReceive(LibraryController.shared.commands) { receive($0) }
            .onKeyPress(.upArrow) { key("up") }
            .onKeyPress(.downArrow) { key("down") }
            .onKeyPress(.leftArrow) { key("left") }
            .onKeyPress(.rightArrow) { key("right") }
            .onKeyPress(.return) { key("accept") }
            .onKeyPress(.escape) { key("back") }
            .modifier(SetupControllerReviewPad(focus: focus, suspended: !ownsCommands))
    }
    private func updateTargets() { focus.update(IridiumControlsRows.merged(known: knownTargets(), rendered: rendered, page: page), page: page) }
    private func receive(_ command: String) {
        updateTargets()
        focus.receive(command, page: page, suspended: !ownsCommands, back: back)
    }
    private func key(_ command: String) -> KeyPress.Result {
        guard ownsCommands else { return .ignored }
        receive(command); return .handled
    }
}

struct IridiumGameControlsButton: View {
    let target: IridiumControlTarget
    var label = "Touch Layout & Profiles"
    @State private var editing = false
    var body: some View {
        Button(label, systemImage: "hand.draw") { editing = true }
            .fullScreenCover(isPresented: $editing) { IridiumTouchLayoutEditor(target: target) }
    }
}

struct IridiumWindowsControllerSettings: View {
    @ObservedObject private var library = LibraryModel.shared
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss
    private var entries: [LibraryEntry] { library.entries.filter { $0.desktop != true } }
    var body: some View {
      ScrollViewReader { proxy in
        List {
                Group {

            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button { selectGame(entry.id) } label: {
                        HStack { Text(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }.id("controls.mapping.\(entry.id)")
                        .setupControllerTarget("controls.mapping.\(entry.id)", order: index, action: { selectGame(entry.id) })
                }
                if library.entries.filter({ $0.desktop != true }).isEmpty {
                    Text("Add a Windows game to customize its controller mapping.").foregroundStyle(.secondary)
                }
            } header: { Text("Windows Games") } footer: { Text("Console games use their system's standard gamepad mapping. Windows games can use a gamepad or keyboard and mouse inputs.") }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Controller Mapping")
        .modifier(IridiumControlsNavigation(page: "controlMapping", suspended: selection != nil, back: { dismiss() },
            knownTargets: { entries.enumerated().map { index, entry in
                .init(id: "controls.mapping.\(entry.id)", page: "controlMapping", order: index, frame: .zero, enabled: true,
                    action: { selectGame(entry.id) }, reveal: { proxy.scrollTo("controls.mapping.\(entry.id)", anchor: .center) })
            } }))
      }
        .navigationDestination(item: $selection) { id in
            if let entry = library.entries.first(where: { $0.id == id }) { IridiumWindowsMappingEditor(entry: entry) }
        }
    }
    private func selectGame(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selection = id
    }
}

private struct IridiumWindowsMappingEditor: View {
    @State var entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      ScrollViewReader { proxy in
        Form {
                Group {

            Section("Controller Input") {
                ControllerModeChoice(mode: $entry.controllerMode)
            }
            if entry.controllerMode == "keys" { ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical) }
            Section { Text("Changes apply the next time this game starts.").font(.footnote).foregroundStyle(.secondary) }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle(IridiumArtworkModel.shared.title(IridiumGame(windows: entry)))
            .modifier(IridiumControlsNavigation(page: "controlMappingEditor", suspended: false, back: { dismiss() },
                knownTargets: { mappingTargets(reveal: { proxy.scrollTo($0, anchor: .center) }) }))
      }
            .onDisappear {
                guard var latest = LibraryModel.shared.entries.first(where: { $0.id == entry.id }) else { return }
                latest.controllerMode = entry.controllerMode; latest.controllerBinds = entry.controllerBinds
                latest.padMouseVertical = entry.padMouseVertical; LibraryModel.shared.save(latest)
            }
    }
    private func mappingTargets(reveal: @escaping (String) -> Void) -> [SetupControllerTarget] {
        let mode = ControllerModeChoice(mode: $entry.controllerMode).controllerTarget(page: "controlMappingEditor", reveal: reveal)
        guard entry.controllerMode == "keys" else { return [mode] }
        return [mode] + ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical)
            .controllerTargets(page: "controlMappingEditor", reveal: reveal)
    }
}

struct IridiumTouchLayoutEditor: View {
    var editing: any IridiumControlEditing = IridiumMadeiraControlAdapter()
    let target: IridiumControlTarget
    @ObservedObject private var model = TouchControlsModel.shared
    @ObservedObject private var profiles = IridiumControlProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var owner = UUID()
    @State private var ready = false
    @State private var failure: String?
    @State private var name = ""
    @State private var naming = false
    @State private var selectedProfile: UUID?
    @State private var inherited = false
    @State private var initial: IridiumControlLayoutState?
    @State private var builtIn: IridiumControlLayoutState?
    @State private var selectedControl = 0
    private var state: IridiumControlLayoutState {
        .init(controls: model.controls, visible: model.visible, size: model.sizeScale, automatic: nil, opacity: model.iridiumSettingsOpacity)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
              ScrollView {
                VStack(spacing: 0) {
                    if ready {
                        HStack {
                            Menu {
                                Button(target.gameID == nil ? "Built-in Layout" : "Use System Defaults") { useInherited() }
                                ForEach(profiles.profiles(for: target.platform)) { profile in
                                    Button(profile.name) { load(profile) }
                                }
                                Button("Save as New Profile…", systemImage: "plus") { name = ""; naming = true }
                                if let id = selectedProfile {
                                    Button("Update This Profile") { saveNamed(replacing: id) }
                                    Button("Delete This Profile", role: .destructive) {
                                        perform { try profiles.deleteProfile(id); selectedProfile = nil }
                                    }
                                }
                            } label: { Label(profileName, systemImage: "rectangle.3.group") }
                            Spacer()
                            Toggle("Show Controls", isOn: $model.visible).fixedSize()
                        }.padding(.horizontal).padding(.vertical, 10)
                        Text("Drag to move · Pinch to resize").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle()).onTapGesture { model.selected = nil }
                        ZStack {
                            Color(white: 0.04)
                            TouchControlsOverlay(iridiumEmbedded: true, iridiumSettings: true)
                        }.frame(height: max(320, geometry.size.height - 180))
                            .clipped().accessibilityIdentifier("sharedTouchLayoutEditor")
                        VStack(spacing: 8) {
                            valueSlider("Layout size", value: $model.sizeScale, range: 0.5...2)
                            valueSlider("Layout opacity", value: $model.iridiumSettingsOpacity, range: 0.15...1)
                        }.padding().background(.black)
                    } else if let failure {
                        VStack {
                            ContentUnavailableView("Controls Unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                            if target.gameID != nil, profiles.loadError == nil {
                                Button("Use System Defaults") { recoverDefaults() }.buttonStyle(.borderedProminent).padding(.bottom)
                            }
                        }
                    }
                    else { ProgressView("Opening controls…") }
                }.background { IridiumControlDeselectSurface() }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    if size.width > 0, size.height > 0 { begin(size: geometry.size) }
                }
              }.scrollBounceBehavior(.basedOnSize)
            }
            .background { Color.black.overlay { IridiumControlDeselectSurface() } }.navigationTitle(target.gameID == nil ? target.title + " Defaults" : target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if ready { Button("Add Control", systemImage: "plus") { addControl() }.labelStyle(.iconOnly) }
                    Button("Save") { save() }.disabled(!ready)
                }
            }
            .alert("Save Control Profile", isPresented: $naming) {
                TextField("Profile name", text: $name)
                Button("Save Profile") { saveNamed() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Reuse this layout with other \(target.platform.title) games.") }
            .alert("Could Not Save Controls", isPresented: Binding(get: { ready && failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .onReceive(LibraryController.shared.commands) { command($0) }
            .onKeyPress(.escape) { close(); return .handled }
        }.preferredColorScheme(.dark).tint(IridiumTheme.accent).interactiveDismissDisabled()
            .onDisappear { editing.end(owner: owner) }
    }
    private var profileName: String {
        if let id = selectedProfile, let profile = profiles.profiles(for: target.platform).first(where: { $0.id == id }) { return profile.name }
        return inherited && state == initial ? (target.gameID == nil ? "Built-in Layout" : "System Defaults") : "Custom Layout"
    }
    private func valueSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.subheadline).frame(minWidth: 108, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(label)
            Text("\(Int(value.wrappedValue * 100))%").font(.subheadline.monospacedDigit()).frame(minWidth: 44, alignment: .trailing)
        }
    }
    private func begin(size: CGSize) {
        guard !ready, failure == nil else { return }
        do {
            let built = defaults(size: size); builtIn = built
            var resolved = try profiles.resolve(platform: target.platform, gameID: target.gameID, builtIn: built)
            if target.platform == .windows, let game = target.gameID,
               profiles.document.games[game.uuidString] == nil, let legacy = target.windowsLayout { resolved = legacy }
            let selection = profiles.selection(platform: target.platform, gameID: target.gameID)
            selectedProfile = selection.profileID
            inherited = selection == .inherit && (target.gameID == nil || !profiles.hasGameOverride(target.gameID!))
            if target.platform == .windows, let game = target.gameID,
               profiles.document.games[game.uuidString] == nil, target.windowsLayout != nil { inherited = false }
            try editing.begin(owner: owner, platform: target.platform, layout: resolved)
            initial = state; ready = true
        } catch { failure = error.localizedDescription }
    }
    private func defaults(size: CGSize) -> IridiumControlLayoutState {
        if target.platform == .windows {
            let values = model.controls.isEmpty ? ControlPresetLayout.xbox(for: .referencePhone) : model.controls
            return .init(controls: values, visible: model.visible, size: model.sizeScale, automatic: true, opacity: 0.7)
        }
        let canvas = CGSize(width: size.width, height: max(320, size.height - 180))
        return .init(controls: IridiumConsoleControlLayout.editorDefaults(profile: .consoleProfile(target.platform.rawValue), size: canvas), visible: true, size: 1, automatic: true, opacity: 0.78)
    }
    private func recoverDefaults() {
        guard let builtIn else { return }
        do {
            let resolved = try profiles.resolve(platform: target.platform, gameID: nil, builtIn: builtIn)
            try editing.begin(owner: owner, platform: target.platform, layout: resolved)
            inherited = true; selectedProfile = nil; initial = state; failure = nil; ready = true
        } catch { failure = error.localizedDescription }
    }
    private func apply(_ layout: IridiumControlLayoutState) {
        model.selected = nil; model.controls = layout.controls; model.visible = layout.visible
        model.sizeScale = layout.size; model.iridiumSettingsOpacity = layout.opacity ?? 0.78; initial = state
    }
    private func load(_ profile: IridiumControlProfile) { apply(profile.layout); selectedProfile = profile.id; inherited = false }
    private func useInherited() {
        guard let builtIn else { return }
        perform {
            let value = target.gameID == nil ? builtIn : try profiles.resolve(platform: target.platform, gameID: nil, builtIn: builtIn)
            apply(value); selectedProfile = nil; inherited = true
        }
    }
    private func addControl() {
        guard ready, model.controls.count < 128 else { return }
        var value = TouchControl(); value.action = .pad("A")
        model.controls.append(value); model.selected = value.id
    }
    private func saveNamed(replacing id: UUID? = nil) {
        perform {
            let title = id.flatMap { key in profiles.profiles(for: target.platform).first(where: { $0.id == key })?.name } ?? name
            selectedProfile = try profiles.saveProfile(name: title, platform: target.platform, layout: state, replacing: id)
            initial = state; inherited = false
        }
    }
    private func save() {
        perform {
            let selection: IridiumControlSelection
            if inherited && state == initial { selection = .inherit }
            else if let id = selectedProfile, let profile = profiles.profiles(for: target.platform).first(where: { $0.id == id }), profile.layout == state { selection = .init(profileID: id) }
            else { selection = .init(layout: state) }
            try profiles.set(selection, platform: target.platform, gameID: target.gameID)
            close()
        }
    }
    private func close() { editing.end(owner: owner); dismiss() }
    private func perform(_ action: () throws -> Void) { do { try action(); failure = nil } catch { failure = error.localizedDescription } }
    private func command(_ value: String) {
        guard ready, !naming, failure == nil else { return }
        if value == "back" { close() }
        if value == "accept", model.selected == nil { addControl() }
        if ["up", "down"].contains(value), !model.controls.isEmpty {
            selectedControl = min(model.controls.count - 1, max(0, selectedControl + (value == "up" ? -1 : 1)))
            model.selected = model.controls[selectedControl].id
        }
        if ["left", "right"].contains(value), let i = model.index(of: model.selected) {
            model.controls[i].nx = min(0.95, max(0.05, model.controls[i].nx + (value == "left" ? -0.02 : 0.02)))
        }
    }
}

/// A background hit target: child controls and property editors receive their
/// gestures first. A drag that starts on a control never becomes a blank tap.
struct IridiumControlDeselectSurface: View {
    @ObservedObject private var model = TouchControlsModel.shared
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { if model.editing { model.selected = nil } }
            .accessibilityHidden(true)
    }
}
