import IridiumCore
import IridiumRuntime
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onBack: (() -> Void)? = nil
    @State private var artworkSettings = false

    var body: some View {
        List {
            Section {
                MenuNavigationLink {
                    LaunchSupportSettingsView(viewModel: viewModel)
                } label: {
                    settingRow(
                        title: "Launch Support",
                        summary: launchSupportSummary,
                        systemImage: "bolt.fill",
                        tone: viewModel.jitStatus == .ready ? .green : .orange
                    )
                }

                MenuNavigationLink {
                    RuntimeSettingsView(viewModel: viewModel)
                } label: {
                    settingRow(
                        title: "Runtime",
                        summary: viewModel.activeRuntimeHealth.status.displayName,
                        systemImage: "gearshape.2.fill",
                        tone: runtimeTone
                    )
                }

                MenuNavigationLink {
                    InputSettingsView()
                } label: {
                    settingRow(
                        title: "Input",
                        summary: "Touch controller, mouse, and keyboard",
                        systemImage: "gamecontroller.fill",
                        tone: .blue
                    )
                }

                MenuNavigationLink {
                    StorageSettingsView(viewModel: viewModel)
                } label: {
                    settingRow(
                        title: "Storage",
                        summary: "Device capacity and available space",
                        systemImage: "internaldrive.fill",
                        tone: storageTone
                    )
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("Library") {
                MenuButton("Artwork Settings") { artworkSettings = true }
                MenuNavigationLink("Recent Activity") { ActivityView(viewModel: viewModel) }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("Support") {
                MenuNavigationLink {
                    DiagnosticsSettingsView(viewModel: viewModel)
                } label: {
                    settingRow(
                        title: "Diagnostics",
                        summary: "Logs and technical status",
                        systemImage: "stethoscope",
                        tone: .blue
                    )
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("About") {
                MenuValue("Version", value: version)
                Text("Manage launch support, runtime, input, artwork, and storage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
        }
        .iridiumListChrome(onBack: onBack)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Library", systemImage: "chevron.backward", action: onBack)
                        .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $artworkSettings) { ArtworkConnectionView(artwork: LibraryArtwork.shared) }
    }

    private var launchSupportSummary: String {
        if viewModel.usesMadeiraRuntime {
            return viewModel.jitStatus == .ready ? "Ready" : "JIT requested when you play"
        }
        if viewModel.pendingLaunches.isEmpty {
            return viewModel.jitStatus == .ready ? "Ready" : "Needs attention"
        }
        return viewModel.pendingLaunches.count == 1 ? "1 launch queued" : "\(viewModel.pendingLaunches.count) launches queued"
    }

    private var runtimeTone: Color {
        switch viewModel.activeRuntimeHealth.status {
        case .healthy: .green
        case .degraded: .orange
        case .actionRequired: .red
        }
    }

    private var storageTone: Color {
        switch viewModel.managedStorage.pressure {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(short) (\(build))"
    }

    private func settingRow(
        title: String,
        summary: String,
        systemImage: String,
        tone: Color
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tone)
                .frame(width: 34, height: 34)

                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct LaunchSupportSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            #if BUILTIN_STIKJIT
            BuiltinJITSettings()
            #endif

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        viewModel.jitStatus == .ready ? "JIT is enabled" : "Enable JIT when prompted to play",
                        systemImage: viewModel.jitStatus == .ready
                            ? "checkmark.circle.fill" : "bolt.badge.exclamationmark.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(viewModel.jitStatus == .ready ? .green : .orange)

                    if let notice = viewModel.jitLaunchNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("JIT lets Iridium translate Windows game code. Follow the setup steps to enable it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            if !viewModel.usesMadeiraRuntime {
            Section("Setup Progress") {
                ForEach(viewModel.onboardingChecks) { check in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(check.title, systemImage: icon(for: check.state))
                                .foregroundStyle(color(for: check.state))
                            Spacer()
                            Text(check.state.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: check.state))
                        }
                        Text(check.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            }
            #if MADEIRA_RUNTIME
            if viewModel.usesMadeiraRuntime {
                MenuNavigationLink("External JIT App") { ExternalJITRoutesView() }
            }
            #endif
            Section("Actions") {
                if let jitToolActionTitle = viewModel.jitToolActionTitle {
                    MenuButton {
                        viewModel.enableJITWithRecommendedTool()
                    } label: {
                        Label(jitToolActionTitle, systemImage: "bolt.fill")
                    }
                    .disabled(!viewModel.canLaunchRecommendedJITTool)
                }

                MenuButton {
                    viewModel.checkJITAgain()
                } label: {
                    Label(
                        viewModel.isCheckingJIT ? "Checking Launch Support…" : "Check Launch Support Again",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isCheckingJIT)

                if !viewModel.usesMadeiraRuntime {
                MenuButton {
                    viewModel.validateRuntime()
                } label: {
                    Label("Validate Runtime", systemImage: "checkmark.shield")
                }

                }
                if let summary = viewModel.lastJITCheckSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            if !viewModel.usesMadeiraRuntime {
            Section("JitStreamer") {
                MenuTextField(
                    "Address",
                    text: Binding(
                        get: { viewModel.jitStreamerAddress },
                        set: { viewModel.updateJitStreamerAddress($0) }
                    )
                )
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)

                Text("Only configure this when JitStreamer is your chosen external JIT provider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Launch Support")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }

    private func icon(for state: OnboardingCheckState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .actionRequired: "xmark.octagon.fill"
        }
    }

    private func color(for state: OnboardingCheckState) -> Color {
        switch state {
        case .ready: .green
        case .warning: .orange
        case .actionRequired: .red
        }
    }
}

private struct RuntimeSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            #if MADEIRA_RUNTIME
            if viewModel.usesMadeiraRuntime {
                MenuNavigationLink("Display & Memory") { RuntimeLaunchPreferences() }
            }
            #endif
            Section("Runtime") {
                MenuValue("Status", value: viewModel.activeRuntimeHealth.status.displayName)
                if viewModel.usesMadeiraRuntime {
                    MenuValue("Runtime", value: "Madeira")
                    Text(viewModel.activeRuntimeHealth.notes.first ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                MenuValue("Base Runtime", value: viewModel.runtimeDescriptor.name)
                MenuValue(
                    "Bundle Version",
                    value: viewModel.hostCapabilities.selectedRuntimeBundle?.version ?? "Missing"
                )
                MenuValue("CPU Translation", value: viewModel.runtimeDescriptor.cpuTranslation.displayName)
                MenuValue("Graphics", value: viewModel.runtimeDescriptor.graphicsStack.displayName)
                MenuValue(
                    "Last Validated",
                    value: viewModel.activeRuntimeHealth.lastValidatedAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "Never"
                )
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            if !viewModel.runtimeSubsystemStatuses.isEmpty {
                Section("Subsystems") {
                    ForEach(viewModel.runtimeSubsystemStatuses) { subsystem in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(subsystem.title)
                                Spacer()
                                Text(subsystem.status)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: subsystem.tone))
                            }
                            Text(subsystem.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }

            if !viewModel.usesMadeiraRuntime {
            Section("Device") {
                MenuValue("Capability", value: viewModel.hostCapabilities.deviceCapabilityClass.displayName)
                MenuValue("Thermal State", value: viewModel.hostCapabilities.thermalState.displayName)
                MenuValue("Low Power Mode", value: viewModel.hostCapabilities.lowPowerModeEnabled ? "On" : "Off")
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            }
            if !viewModel.runtimeConstraintNotes.isEmpty {
                Section("Technical Notes") {
                    ForEach(viewModel.runtimeConstraintNotes, id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Runtime")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }

    private func color(for status: VerificationGateStatus) -> Color {
        switch status {
        case .ready: .green
        case .warning: .orange
        case .blocked: .red
        }
    }
}

private struct StorageSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var capacity: Int64?
    @State private var free: Int64?
    @State private var failure: String?

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
    private func refresh() {
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else {
                throw CocoaError(.fileReadUnknown)
            }
            capacity = Int64(total); free = Int64(available); failure = nil
        } catch { failure = "Storage could not be read. Try Refresh." }
    }
    var body: some View {
        List {
            Section("Device Storage") {
                if let capacity, let free {
                    MenuValue("Available", value: bytes(free))
                    MenuValue("Used", value: bytes(max(0, capacity - free)))
                    MenuValue("Total Capacity", value: bytes(capacity))
                    Text("Used space includes iOS, apps, and their data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.secondary) }
                MenuButton("Refresh") { refresh() }
            }
            Section("Library") {
                MenuValue("Registered Games", value: String(viewModel.games.count))
                Text("Manage each game's files through Game Options → Files & Saves. Multiple library entries can share a game folder.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
        .onAppear { refresh() }
    }
}

private struct DiagnosticsSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    private var logURLs: [URL] {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }
        return RuntimeDiagnosticLogFiles.existing(in: documents)
    }

    var body: some View {
        List {
            Section("Runtime Logs") {
                if !logURLs.isEmpty {
                    ShareLink(items: logURLs) {
                        Label("Share Runtime Logs", systemImage: "square.and.arrow.up")
                    }
                    Text("Includes app and native Wine/FEX/DXMT logs, including the previous run when available. Logs may contain file paths; review before sharing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No runtime log is available yet", systemImage: "doc")
                        .foregroundStyle(.secondary)
                }
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("Current State") {
                MenuValue("JIT", value: viewModel.jitStatus.displayName)
                MenuValue("Runtime", value: viewModel.activeRuntimeHealth.status.displayName)
                MenuValue("Games", value: "\(viewModel.games.count)")
                MenuValue("Queued Launches", value: "\(viewModel.pendingLaunches.count)")
                MenuValue("Compatibility Audits", value: "\(viewModel.verificationAudits.count)")
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)

            Section("Technical Details") {
                MenuValue("Bundle", value: Bundle.main.bundleIdentifier ?? "Unknown")
                MenuValue("Environment", value: viewModel.usesMadeiraRuntime ? "Native iOS" : viewModel.hostCapabilities.executionEnvironment.displayName)
                MenuValue("Runtime Bundle", value: viewModel.activeRuntimeHealth.runtimeBundleIdentifier ?? viewModel.hostCapabilities.selectedRuntimeBundle?.id ?? "Missing")
            }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }
}

#if MADEIRA_RUNTIME
private struct RuntimeLaunchPreferences: View {
    @AppStorage(MadeiraResolution.key) private var width = 960
    @AppStorage("IridiumJITPoolMB") private var pool = 0
    var body: some View {
        List {
            Section("Display Resolution") {
                ForEach(MadeiraResolution.allCases, id: \.rawValue) { resolution in
                    MenuButton { width = resolution.rawValue } label: {
                        HStack {
                            Text(resolution.title)
                            Spacer()
                            if width == resolution.rawValue { Image(systemName: "checkmark") }
                        }
                    }
                }
                Text("Applies to the next game launch. Lower resolutions reduce graphics work.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("JIT Memory Limit") {
                ForEach([0, 128, 256, 512], id: \.self) { mb in
                    MenuButton { pool = mb } label: {
                        HStack {
                            Text(mb == 0 ? "Automatic" : "\(mb) MB")
                            Spacer()
                            if pool == mb { Image(systemName: "checkmark") }
                        }
                    }
                }
                Text("Iridium can use a smaller pool when memory is limited. Some games need more code memory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Display & Memory")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }
}

private struct ExternalJITRoutesView: View {
    @AppStorage(StikJITHelper.routeKey) private var route = "automatic"
    var body: some View {
        List {
            ForEach(StikJITHelper.Route.allCases, id: \.rawValue) { option in
                MenuButton { route = option.rawValue } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if route == option.rawValue { Image(systemName: "checkmark") }
                    }
                }
            }
            Text("Automatic tries LiveContainer2, StikDebug, then LiveContainer. StikDebug must be installed inside the selected container.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("External JIT App")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }
}
#endif
