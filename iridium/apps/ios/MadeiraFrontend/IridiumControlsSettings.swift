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
    @State private var target: IridiumControlTarget?
    @State private var pending: IridiumControlTarget?
    @State private var pickingGame = false
    @State private var focus = 0
    @State private var guided = false
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
                        }.id(index).listRowBackground(guided && focus == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                    }
                } header: { Text("Default Touch Layouts") } footer: { Text("Set a layout for a system, or save reusable profiles. Games can have their own controls.") }
                Section {
                    Button("Game Overrides", systemImage: "gamecontroller") { pickingGame = true }
                        .id(systems.count).listRowBackground(guided && focus == systems.count ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
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
                    NavigationLink("Windows Games") { IridiumWindowsControllerSettings() }
                }
                Section("Touch Mouse · Windows") { LibraryPointerSettings() }
                Section("Haptics") { IridiumControlFeedbackSettings() }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Controls")
                .onChange(of: focus) { _, value in proxy.scrollTo(value, anchor: .center) }
        }
        .onReceive(LibraryController.shared.commands) { command($0) }
        .onKeyPress(.upArrow) { command("up"); return .handled }
        .onKeyPress(.downArrow) { command("down"); return .handled }
        .onKeyPress(.return) { command("accept"); return .handled }
        .sheet(isPresented: $pickingGame, onDismiss: { target = pending; pending = nil }) {
            NavigationStack {
                List {
                Group {

                    if choices.isEmpty { ContentUnavailableView("No Games Yet", systemImage: "gamecontroller", description: Text("Add a game to customize its controls. System defaults are available now.")) }
                    ForEach(choices) { choice in
                        Button { pending = choice; pickingGame = false } label: {
                            VStack(alignment: .leading) { Text(choice.title); Text(choice.platform.title).font(.caption).foregroundStyle(.secondary) }
                        }
                    }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Game Controls")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { pickingGame = false } } }
            }
        }
        .fullScreenCover(item: $target) { IridiumTouchLayoutEditor(target: $0) }
    }
    private func command(_ value: String) {
        guard target == nil, !pickingGame else { return }
        if value == "up" || value == "down" { guided = true; focus = min(systems.count, max(0, focus + (value == "up" ? -1 : 1))) }
        if value == "accept" {
            if focus < systems.count { target = .init(platform: systems[focus], title: systems[focus].title) }
            else { pickingGame = true }
        }
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
    var body: some View {
        List {
                Group {

            Section {
                ForEach(library.entries.filter { $0.desktop != true }) { entry in
                    NavigationLink(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))) { IridiumWindowsMappingEditor(entry: entry) }
                }
                if library.entries.filter({ $0.desktop != true }).isEmpty {
                    Text("Add a Windows game to customize its controller mapping.").foregroundStyle(.secondary)
                }
            } header: { Text("Windows Games") } footer: { Text("Console games use their system's standard gamepad mapping. Windows games can use a gamepad or keyboard and mouse inputs.") }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Controller Mapping")
    }
}

private struct IridiumWindowsMappingEditor: View {
    @State var entry: LibraryEntry
    var body: some View {
        Form {
                Group {

            Section("Controller Input") {
                ControllerModeChoice(mode: $entry.controllerMode)
            }
            if entry.controllerMode == "keys" { ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical) }
            Section { Text("Changes apply the next time this game starts.").font(.footnote).foregroundStyle(.secondary) }

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle(IridiumArtworkModel.shared.title(IridiumGame(windows: entry)))
            .onDisappear {
                guard var latest = LibraryModel.shared.entries.first(where: { $0.id == entry.id }) else { return }
                latest.controllerMode = entry.controllerMode; latest.controllerBinds = entry.controllerBinds
                latest.padMouseVertical = entry.padMouseVertical; LibraryModel.shared.save(latest)
            }
    }
}

struct IridiumTouchLayoutEditor: View {
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
            .onDisappear { model.iridiumEndSettings(owner: owner) }
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
            let admission = LibraryModel.shared.current == nil && !LibraryModel.shared.launching &&
                !IridiumConsoleSession.shared.isActive && !JITCoordinator.shared.busy &&
                wine_process_is_running() == 0 && wineserver_is_running() == 0
            try model.iridiumBeginSettings(owner: owner, platform: target.platform, state: resolved, admission: admission)
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
            let admission = LibraryModel.shared.current == nil && !LibraryModel.shared.launching &&
                !IridiumConsoleSession.shared.isActive && !JITCoordinator.shared.busy &&
                wine_process_is_running() == 0 && wineserver_is_running() == 0
            try model.iridiumBeginSettings(owner: owner, platform: target.platform, state: resolved, admission: admission)
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
    private func close() { model.iridiumEndSettings(owner: owner); dismiss() }
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
