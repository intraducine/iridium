// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumCapabilitiesView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @State private var extendedMemory = EntitlementStatus.check().increasedMemory
    @State private var showingJITSetup = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
                Group {

            Section {
                LabeledContent("Offline JIT", value: coordinator.offlineMemoryReady ? "Ready" : "Needs setup")
                Button("JIT Setup", systemImage: "bolt") { showingJITSetup = true }
                    .disabled(coordinator.busy)
                if MadeiraBuiltInJIT.isAvailable && !coordinator.offlineMemoryReady {
                    Button("Enable JIT", action: enableJIT).disabled(coordinator.busy)
                }
                if coordinator.busy && coordinator.error == nil { IridiumJITProgress(status: coordinator.status) }
                if let error = coordinator.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    if let problem = coordinator.connectionProblem {
                        jitConnectionActions(problem, openSetup: { showingJITSetup = true })
                    }
                }
            } header: { Text("JIT") } footer: {
                Text(MadeiraBuiltInJIT.unavailableReason ??
                     "Enable JIT before going offline. Prepared memory lasts until the app closes.")
            }
            #if !targetEnvironment(simulator)
            Section {
                LabeledContent("Extended memory", value: extendedMemory ? "Available" : "Requires setup")
                if !extendedMemory {
                    Link("Set Up Extended Memory", destination: URL(string: "https://github.com/intraducine/iridium/blob/main/docs/actions-ipa.md")!)
                }
            } header: { Text("Memory") } footer: {
                if !extendedMemory { Text("Enable extended memory in your signing app, then reinstall Iridium.") }
            }
            #endif

                }.iridiumRowSurface()
}.iridiumPageSurface().navigationTitle("JIT & Memory")
            // Keep the presenter on the Form so row updates preserve the sheet.
            .sheet(isPresented: $showingJITSetup) { JITSetupView() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { extendedMemory = EntitlementStatus.check().increasedMemory } }
    }

    private func enableJIT() {
        guard !coordinator.busy else { return }
        if !coordinator.offlineMemoryReady,
           !MadeiraBuiltInJIT.isAvailable || !JITPairingFileStore.isImported {
            showingJITSetup = true
            return
        }
        coordinator.prepareOfflineMemory { _ in }
    }
}
