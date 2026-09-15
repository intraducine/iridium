import Foundation
import SwiftUI

struct TouchControllerLayoutEditorView: View {
    let gameID: UUID
    let gameTitle: String

    @State private var layout: TouchControllerLayout
    @State private var selectedID: UUID?
    @State private var confirmingReset = false
    @Environment(\.dismiss) private var dismiss

    init(gameID: UUID, gameTitle: String) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        let saved = TouchControllerLayoutStore.layout(for: gameID)
        _layout = State(initialValue: saved)
        _selectedID = State(initialValue: saved.controls.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let minimumDimension = min(geometry.size.width, geometry.size.height)
                ZStack {
                    LinearGradient(
                        colors: [Color.black, Color(white: 0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    ForEach(layout.controls) { control in
                        let renderedSize = editorControlSize(control, minimumDimension: minimumDimension)
                        EditorControlPreview(
                            control: control,
                            renderedSize: renderedSize,
                            selected: selectedID == control.id
                        )
                        .frame(width: renderedSize.width, height: renderedSize.height)
                        .position(
                            x: CGFloat(control.centerX) * geometry.size.width,
                            y: CGFloat(control.centerY) * geometry.size.height
                        )
                        .opacity(control.isHidden ? 0.26 : 1)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("touchControllerCanvas"))
                                .onChanged { value in
                                    selectedID = control.id
                                    move(control.id, to: value.location, canvas: geometry.size)
                                }
                        )
                        .accessibilityLabel("\(control.mapping.displayName) control")
                        .accessibilityHint("Drag to move")
                    }
                }
                .coordinateSpace(name: "touchControllerCanvas")
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("Drag controls to move them")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .frame(minHeight: 280)

            Divider()

            if let selectedIndex {
                inspector(index: selectedIndex)
            } else {
                ContentUnavailableView(
                    "Select a Control",
                    systemImage: "hand.tap",
                    description: Text("Choose a control above, or add a new one.")
                )
                .frame(maxHeight: 220)
            }
        }
        .navigationTitle("On-Screen Controller")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(TouchControllerMapping.allCases) { mapping in
                        Button(mapping.displayName, systemImage: mapping.systemImage) {
                            add(mapping)
                        }
                    }
                } label: {
                    Label("Add Control", systemImage: "plus")
                }

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    confirmingReset = true
                }

                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Reset controls for \(gameTitle)?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset to Xbox Layout", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Positions, sizes, opacity, hidden controls, and added controls will return to the default layout.")
        }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return layout.controls.firstIndex(where: { $0.id == selectedID })
    }

    @ViewBuilder
    private func inspector(index: Int) -> some View {
        let control = layout.controls[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(control.mapping.displayName, systemImage: control.mapping.systemImage)
                        .font(.headline)
                    Spacer()
                    Button("Delete", role: .destructive) { delete(control.id) }
                        .buttonStyle(.bordered)
                }

                Picker("Input", selection: binding(index, \.mapping)) {
                    ForEach(TouchControllerMapping.allCases) { mapping in
                        Text(mapping.displayName).tag(mapping)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(control.size * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: binding(index, \.size), in: 0.055...0.34, step: 0.005)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(control.opacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: binding(index, \.opacity), in: 0.15...1, step: 0.05)
                }

                Toggle("Hidden", isOn: binding(index, \.isHidden))

                Text("Layouts are saved for this game. Positions are stored as screen-relative values so the same layout scales across device sizes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(maxHeight: 260)
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<TouchControllerControl, Value>) -> Binding<Value> {
        Binding(
            get: { layout.controls[index][keyPath: keyPath] },
            set: { value in
                guard layout.controls.indices.contains(index) else { return }
                layout.controls[index][keyPath: keyPath] = value
                save()
            }
        )
    }

    private func move(_ id: UUID, to location: CGPoint, canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0,
              let index = layout.controls.firstIndex(where: { $0.id == id }) else { return }
        let rendered = editorControlSize(
            layout.controls[index],
            minimumDimension: min(canvas.width, canvas.height)
        )
        let marginX = min(0.49, Double(rendered.width / (2 * canvas.width)))
        let marginY = min(0.49, Double(rendered.height / (2 * canvas.height)))
        let x = Double(location.x / canvas.width)
        let y = Double(location.y / canvas.height)
        layout.controls[index].centerX = min(1 - marginX, max(marginX, x))
        layout.controls[index].centerY = min(1 - marginY, max(marginY, y))
        save()
    }

    private func add(_ mapping: TouchControllerMapping) {
        let count = layout.controls.count
        let column = count % 4
        let row = (count / 4) % 3
        let control = TouchControllerControl(
            mapping: mapping,
            centerX: 0.38 + Double(column) * 0.08,
            centerY: 0.34 + Double(row) * 0.10,
            size: mapping.kind == .stick ? 0.16 : 0.08
        )
        layout.controls.append(control)
        selectedID = control.id
        save()
    }

    private func delete(_ id: UUID) {
        guard layout.controls.count > 1 else { return }
        layout.controls.removeAll { $0.id == id }
        selectedID = layout.controls.first?.id
        save()
    }

    private func reset() {
        layout = .xboxDefault
        selectedID = layout.controls.first?.id
        TouchControllerLayoutStore.resetLayout(for: gameID)
    }

    private func save() {
        TouchControllerLayoutStore.save(layout, for: gameID)
    }
}

private func editorControlSize(_ control: TouchControllerControl, minimumDimension: CGFloat) -> CGSize {
    let base = max(38, CGFloat(control.size) * minimumDimension)
    switch control.mapping.kind {
    case .stick, .dpad:
        return CGSize(width: base, height: base)
    case .trigger:
        return CGSize(width: base * 1.55, height: base * 0.68)
    case .button:
        switch control.mapping {
        case .leftBumper, .rightBumper:
            return CGSize(width: base * 1.45, height: base * 0.70)
        case .menu, .view:
            return CGSize(width: base * 1.15, height: base * 0.80)
        default:
            return CGSize(width: base, height: base)
        }
    }
}

private struct EditorControlPreview: View {
    let control: TouchControllerControl
    let renderedSize: CGSize
    let selected: Bool

    var body: some View {
        ZStack {
            switch control.mapping.kind {
            case .stick:
                Circle().fill(.black.opacity(0.55))
                Circle().stroke(.white.opacity(0.55), lineWidth: 2)
                Circle()
                    .fill(.white.opacity(0.32))
                    .frame(width: renderedSize.width * 0.44, height: renderedSize.height * 0.44)
                Text(control.mapping.compactLabel).font(.caption2.bold()).foregroundStyle(.white)
            case .dpad:
                Image(systemName: "dpad.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.58))
            case .trigger:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.58))
                Text(control.mapping.compactLabel).font(.caption.bold()).foregroundStyle(.white)
            case .button:
                Circle().fill(.black.opacity(0.58))
                Circle().stroke(.white.opacity(0.55), lineWidth: 2)
                Text(control.mapping.compactLabel).font(.caption.bold()).foregroundStyle(.white)
            }
        }
        .opacity(control.opacity)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    .padding(-5)
            }
        }
        .contentShape(Rectangle())
    }
}
