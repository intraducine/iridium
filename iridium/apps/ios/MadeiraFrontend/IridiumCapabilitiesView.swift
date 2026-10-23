// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumCapabilitiesView: View {
    @ObservedObject private var state = LibraryJITState.shared
    @ObservedObject private var coordinator = JITCoordinator.shared
    @State private var extendedMemory = EntitlementStatus.check().increasedMemory
    @State private var showingJITSetup = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
                Group {

            Section {
                LabeledContent("JIT", value: state.enabled ? "Active for this session" : "Not active")
                Text("JIT helps games run faster. Windows, GameCube, Wii, Nintendo 3DS, PlayStation 2, Dreamcast and arcade games require it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("JIT Settings", systemImage: "bolt") { showingJITSetup = true }
                    .disabled(coordinator.busy)
                if !state.enabled {
                    Button("Enable JIT", action: enableJIT).disabled(coordinator.busy)
                }
                if coordinator.busy { ProgressView(coordinator.status ?? "Connecting…") }
                if let error = coordinator.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    if let problem = coordinator.connectionProblem {
                        jitConnectionActions(problem, openSetup: { showingJITSetup = true })
                    }
                }
            } header: { Text("JIT · Faster Execution") } footer: {
                Text("Games that need JIT enable it when you press Play.")
            }
            #if !targetEnvironment(simulator)
            Section {
                LabeledContent("Extended memory", value: extendedMemory ? "Available" : "Requires setup")
                Text("Gives demanding games more memory to run.").font(.footnote).foregroundStyle(.secondary)
                if !extendedMemory {
                    Link("Set Up Extended Memory", destination: URL(string: "https://github.com/intraducine/iridium/blob/main/docs/actions-ipa.md")!)
                }
            } header: { Text("Memory") } footer: {
                if !extendedMemory { Text("Enable extended memory in your signing app, then reinstall Iridium.") }
            }
            #endif

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("Performance & Compatibility")
            // Keep the presenter on the Form so row updates preserve the sheet.
            .sheet(isPresented: $showingJITSetup) { JITSetupView() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { extendedMemory = EntitlementStatus.check().increasedMemory } }
    }

    private func enableJIT() {
        guard !coordinator.busy else { return }
        if !StikJITHelper.ready {
            if coordinator.resolvedMethod == .builtIn, !JITPairingFileStore.isImported {
                showingJITSetup = true
                return
            }
            if coordinator.resolvedMethod == .stikDebug, !StikJITHelper.isAvailable {
                showingJITSetup = true
                return
            }
        }
        coordinator.enable { _ in }
    }
}
