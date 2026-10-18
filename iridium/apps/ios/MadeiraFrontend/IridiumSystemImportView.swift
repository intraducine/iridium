// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumSystemSetupSections: View {
    let system: IridiumConsoleSystem
    var platform: IridiumPlatform? = nil
    var body: some View {
        Section {
            LabeledContent("System", value: system.subtitle)
            LabeledContent("Emulator", value: system.runtime.name)
            if system.runtime.jit == .required {
                Button("Set Up Launch Support", systemImage: "bolt") { JITCoordinator.shared.showSetup = true }
            }
        }
        Section {
            DisclosureGroup("Supported Files") {
                Text((platform.map { system.formats(for: $0) } ?? system.extensions).map { "." + $0 }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
                if system.id == "azahar" { Text("Use an unencrypted game file. CIA installation is not supported.").font(.footnote).foregroundStyle(.secondary) }
                if system.id == "flycast" { Text("For a GDI or CUE disc, choose its folder to include every track.").font(.footnote).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Saves & System Files") {
                Text(system.storageGuidance).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
