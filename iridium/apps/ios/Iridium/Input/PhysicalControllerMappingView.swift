import SwiftUI

struct PhysicalControllerMappingView: View {
    let gameID: UUID
    let gameTitle: String
    @State private var configuration: PhysicalControllerConfiguration
    @State private var confirmingReset = false

    init(gameID: UUID, gameTitle: String) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        _configuration = State(initialValue: PhysicalControllerMappingStore.configuration(for: gameID))
    }

    var body: some View {
        List {
            Section("Physical Controllers") {
                choice("Input Mode", options: PhysicalControllerMode.allCases.map { ($0.displayName, $0) },
                       selection: editing(\.mode), value: configuration.mode.displayName)
                    .accessibilityIdentifier("physicalControllerMode")
                Text("Native Controller uses the game's controller support. Keyboard & Mouse maps connected physical pads to keys and mouse input. These settings apply only to \(gameTitle).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sticks") {
                choice("Left Stick", options: PhysicalControllerStick.allCases.map { ($0.displayName, $0) },
                       selection: editing(\.leftStick), value: configuration.leftStick.displayName)
                choice("Right Stick", options: PhysicalControllerStick.allCases.map { ($0.displayName, $0) },
                       selection: editing(\.rightStick), value: configuration.rightStick.displayName)
                Stepper(value: editing(\.deadZone), in: 0.1...0.8, step: 0.05) {
                    LabeledContent("Dead Zone", value: configuration.deadZone.formatted(.percent.precision(.fractionLength(0))))
                }
                .menuFocusable(action: { adjustDeadZone(1) }, adjust: adjustDeadZone)
                Stepper(value: editing(\.mouseSpeed), in: 100...2400, step: 100) {
                    LabeledContent("Mouse Speed", value: configuration.mouseSpeed.formatted(.number.precision(.fractionLength(0))) + " px/s")
                }
                .menuFocusable(action: { adjustMouseSpeed(1) }, adjust: adjustMouseSpeed)
            }
            Section("Buttons") {
                ForEach(PhysicalControllerButton.allCases) { button in
                    choice(button.displayName, options: PhysicalControllerAction.choices.map { ($0.displayName, $0) },
                           selection: Binding(get: { configuration.action(for: button) },
                                              set: { action in
                                                  var value = configuration
                                                  value.bindings[button.rawValue] = action
                                                  persistEdit(value)
                                              }),
                           value: configuration.action(for: button).displayName)
                        .accessibilityIdentifier("controllerBinding.\(button.rawValue)")
                }
                Text("Shared bindings stay pressed until every source releases them. When several sticks move the mouse, the strongest stick controls its speed. On-screen controls keep their saved layout and controller behavior.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Menu / Start sends its game binding during play. Use the on-screen Player Menu to open Iridium's controls. In Iridium's menus and launch screen, Menu / Start follows the app's navigation instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                MenuButton("Reset Bindings", role: .destructive) { confirmingReset = true }
            }
        }
        .navigationTitle("Controller Mapping")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .onAppear { configuration = PhysicalControllerMappingStore.configuration(for: gameID) }
        .confirmationDialog("Reset controller bindings?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Bindings", role: .destructive) {
                var value = PhysicalControllerConfiguration()
                value.mode = configuration.mode
                persistEdit(value)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restore WASD, right-stick mouse, and default button bindings for \(gameTitle). The selected input mode is kept.")
        }
    }

    private func choice<Value: Hashable>(_ title: String, options: [(String, Value)],
                                         selection: Binding<Value>, value: String) -> some View {
        MenuNavigationLink {
            ControllerMappingChoiceView(title: title, options: options, selection: selection)
        } label: { LabeledContent(title, value: value) }
    }
    private func editing<Value>(_ keyPath: WritableKeyPath<PhysicalControllerConfiguration, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: keyPath] }, set: { newValue in
            var value = configuration
            value[keyPath: keyPath] = newValue
            persistEdit(value)
        })
    }
    private func persistEdit(_ value: PhysicalControllerConfiguration) {
        configuration = value
        PhysicalControllerMappingStore.save(value, for: gameID)
    }
    private func adjustDeadZone(_ direction: Int) {
        editing(\.deadZone).wrappedValue = min(0.8, max(0.1, configuration.deadZone + (direction > 0 ? 0.05 : -0.05)))
    }
    private func adjustMouseSpeed(_ direction: Int) {
        editing(\.mouseSpeed).wrappedValue = min(2400, max(100, configuration.mouseSpeed + (direction > 0 ? 100 : -100)))
    }
}

private struct ControllerMappingChoiceView<Value: Hashable>: View {
    let title: String
    let options: [(String, Value)]
    @Binding var selection: Value
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                MenuButton {
                    selection = option.1
                    dismiss()
                } label: {
                    HStack {
                        Text(option.0)
                        Spacer()
                        if selection == option.1 { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .accessibilityAddTraits(selection == option.1 ? .isSelected : [])
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }
}
