import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct SteamLibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    var onBack: (() -> Void)? = nil
    @StateObject private var steam = SteamLibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page = .library
    @State private var search = ""
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var challengeImage: UIImage?
    @State private var configuring: SteamOwnedGame?
    @State private var reviewing: SteamDownloadJob?
    @State private var removing: SteamDownloadJob?

    private enum Page: String, CaseIterable, Identifiable {
        case queue = "Queue", library = "Steam", installed = "Installed"
        var id: Self { self }
    }

    var body: some View {
        List {
            Section {
                Picker("Downloads section", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                    .menuFocusable(action: { changePage(1) }, adjust: changePage)
                    .accessibilityIdentifier("steamDownloadsSection")
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)

            if let error = steam.error {
                Section {
                    Text(error).font(.callout)
                    MenuButton("Dismiss Message") { steam.error = nil }
                }.modifier(SteamPanel())
            }
            if !steam.state.signedIn && page != .installed { signInSection }
            if steam.busy && steam.activeJobID == nil {
                Section {
                    ProgressView(steam.state.message)
                    MenuButton("Cancel Request") { steam.perform(["action": "cancel"]) }
                }.modifier(SteamPanel())
            }
            switch page {
            case .queue: queueSection
            case .library: librarySection
            case .installed: installedSection
            }
        }
        .iridiumListChrome(onBack: onBack)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Library", systemImage: "chevron.backward", action: onBack)
                        .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if steam.state.signedIn {
                        Text(steam.state.accountName ?? "Steam")
                        Button("Refresh Steam Library", systemImage: "arrow.clockwise") { steam.perform(["action": "library"]) }
                        Button("Sign Out", role: .destructive) { steam.perform(["action": "signOut"]) }
                    } else { Button("Steam Sign-in") { page = .library } }
                } label: {
                    Label("Steam Account", systemImage: "person.crop.circle")
                }.disabled(steam.busy).accessibilityLabel("Steam account")
            }
        }
        .task { await steam.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { steam.pauseForBackground() }
            if phase == .active { steam.resumeForeground() }
        }
        .onChange(of: steam.state.challengeUrl, initial: true) { _, value in challengeImage = value.flatMap(qrImage) }
        .sheet(item: $configuring) { game in
            NavigationStack {
                SteamDownloadOptionsView(game: game, steam: steam) { options in
                    if steam.enqueue(game, options: options) { configuring = nil; page = .queue }
                }
            }
        }
        .sheet(item: $reviewing) { job in
            NavigationStack {
                SteamInstallReviewView(job: job, viewModel: viewModel, steam: steam)
            }
        }
        .confirmationDialog("Remove Download Entry?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Entry", role: .destructive) { if let job = removing { steam.remove(job.id) }; removing = nil }
            Button("Keep Entry", role: .cancel) { removing = nil }
        } message: {
            Text("This only removes the queue or history entry. Downloaded files, partial files, and saves are kept.")
        }
    }

    private func changePage(_ direction: Int) {
        let pages = Page.allCases
        guard let index = pages.firstIndex(of: page) else { return }
        page = pages[min(pages.count - 1, max(0, index + direction))]
    }

    private var signInSection: some View {
        Section {
            Text("Your Steam games, on this device").font(.headline)
            MenuTextField("Steam account name", text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(steam.busy)
            MenuTextField("Password", text: $password, secure: true).textContentType(.password).disabled(steam.busy)
            MenuButton("Sign In") {
                steam.perform(["action": "signIn", "accountName": username, "password": password])
                password = ""
            }.libraryGlass(prominent: true).disabled(steam.busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            MenuButton("Use a QR Code") { steam.perform(["action": "qr"]) }.disabled(steam.busy)
            if steam.state.phase == "guard" {
                Text(steam.state.message).font(.callout)
                MenuTextField("Steam Guard code", text: $code).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                MenuButton("Submit Code") { steam.perform(["action": "guard", "code": code]); code = "" }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if steam.state.phase == "approval" { Text("Approve the sign-in in Steam Mobile.") }
            if let challengeImage {
                Image(uiImage: challengeImage).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 220).padding().background(.white)
                    .accessibilityLabel("Steam sign-in QR code. Scan using Steam Mobile on another device.")
            }
        } footer: {
            Text("Credentials go directly to Steam. Your password is not saved; the session is stored in this device’s Keychain.")
        }.modifier(SteamPanel())
    }

    private var librarySection: some View {
        Section {
            if steam.state.signedIn {
                MenuTextField("Search your Steam games", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if steam.state.games.isEmpty && !steam.busy {
                    Text("No games returned. Refresh your Steam library to try again.").foregroundStyle(.secondary)
                    MenuButton("Refresh Library") { steam.perform(["action": "library"]) }
                }
                ForEach(steam.state.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { game in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(game.name).font(.headline).lineLimit(2)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 18) { gameActions(game) }
                            VStack(alignment: .leading, spacing: 10) { gameActions(game) }
                        }
                    }.padding(.vertical, 6)
                }
            } else {
                Text("Sign in to browse the games on your account.").foregroundStyle(.secondary)
            }
        } header: { Text("Your Games · \(steam.state.games.count)") }
        footer: { Text("Downloads run inside Iridium, without Steam.exe or a companion PC. Downloading does not guarantee that a game will run.") }
        .modifier(SteamPanel())
    }

    @ViewBuilder private func gameActions(_ game: SteamOwnedGame) -> some View {
        let queued = steam.queue.jobs.contains { $0.appId == game.appId && $0.isPending && $0.account == SteamDownloadJob.accountKey(steam.account ?? "") }
        MenuButton(queued ? "In Queue" : "Queue Download", systemImage: "arrow.down.circle") {
            if steam.enqueue(game) { page = .queue }
        }.disabled(queued).accessibilityLabel(queued ? "\(game.name) is in the queue" : "Download \(game.name)")
        MenuButton("Options", systemImage: "slider.horizontal.3") { configuring = game }
            .disabled(steam.busy || queued).accessibilityLabel("Download options for \(game.name)")
    }

    private var queueSection: some View {
        Section {
            if steam.queue.jobs.allSatisfy({ $0.status == .completed }) {
                ContentUnavailableView("No Downloads Queued", systemImage: "arrow.down.circle",
                    description: Text("Choose a game from the Steam section."))
                MenuButton("Browse Steam Games") { page = .library }
            } else {
                HStack(spacing: 18) {
                    MenuButton("Resume Queue", systemImage: "play.fill") { steam.resumeQueue() }.disabled(!steam.state.signedIn)
                    MenuButton("Pause All", systemImage: "pause.fill") { steam.pauseQueue() }.disabled(steam.queue.isPaused)
                }
                if steam.queue.isPaused { Text("Queue paused. Resume when you are ready.").font(.callout).foregroundStyle(.secondary) }
                ForEach(steam.queue.jobs.filter { $0.status != .completed }) { job in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.name).font(.headline).lineLimit(2)
                        Text("\(job.options.branch) · \(job.options.language) · \(job.options.architecture)-bit")
                            .font(.caption).foregroundStyle(.secondary)
                        if job.totalBytes > 0 {
                            ProgressView(value: job.fractionCompleted)
                                .accessibilityLabel("Verified download progress for \(job.name)")
                            Text("\(bytes(job.completedBytes)) of \(bytes(job.totalBytes)) verified")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        } else if job.status == .running { ProgressView() }
                        Text(job.message ?? job.status.rawValue.capitalized).font(.callout)
                        if steam.activeJobID == job.id && steam.bytesPerSecond > 0 {
                            Text("\(bytes(Int64(steam.bytesPerSecond))) / s received").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if job.account != SteamDownloadJob.accountKey(steam.account ?? "") {
                            Text("Account: \(job.account)").font(.caption).foregroundStyle(.secondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 18) { queueActions(job) }
                            VStack(alignment: .leading, spacing: 10) { queueActions(job) }
                        }
                    }.padding(.vertical, 6)
                }
            }
        } header: { Text("Downloads · \(steam.pendingCount)") }
        footer: { Text("Keep Iridium open while downloading. Backgrounding pauses the queue. Resume checks saved chunks before downloading missing data.") }
        .modifier(SteamPanel())
    }

    @ViewBuilder private func queueActions(_ job: SteamDownloadJob) -> some View {
        if job.status == .running || job.status == .queued {
            MenuButton("Pause") { steam.pause(job.id) }.disabled(job.phase == "pausing")
            if job.status == .queued { MenuButton("Download Next") { steam.prioritize(job.id) } }
            MenuButton("Cancel") { steam.cancel(job.id) }.disabled(job.phase == "pausing")
        } else {
            if job.canResume {
                MenuButton(job.status == .failed ? "Retry" : "Resume") { steam.resume(job.id) }
                    .disabled(job.account != SteamDownloadJob.accountKey(steam.account ?? ""))
            }
            MenuButton("Remove Entry") { removing = job }
        }
    }

    private var installedSection: some View {
        Section {
            let completed = steam.queue.jobs.filter { $0.status == .completed && $0.installed != nil }
            if completed.isEmpty {
                ContentUnavailableView("No Completed Downloads", systemImage: "checkmark.circle",
                    description: Text("Verified downloads appear here, ready to add to your library."))
            }
            ForEach(completed.reversed()) { job in
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.name).font(.headline).lineLimit(2)
                    if let build = job.installed?.buildId {
                        Text("Build \(build) · \(job.options.branch)").font(.caption).foregroundStyle(.secondary)
                    }
                    if job.addedToLibrary { Label("Added to Library", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                    MenuButton(job.addedToLibrary ? "Choose Executable / Add Again" : "Add to Library") { reviewing = job }
                    MenuButton("Verify / Repair or Update") { steam.repairOrUpdate(job); page = .queue }
                        .disabled(!steam.state.signedIn || job.account != SteamDownloadJob.accountKey(steam.account ?? ""))
                    MenuButton("Check for Updates") { steam.loadDetails(for: SteamOwnedGame(appId: job.appId, name: job.name)) }.disabled(steam.busy)
                    if let branch = steam.detailsByApp[job.appId]?.branches.first(where: { $0.name == job.options.branch }),
                       let current = branch.buildId, let installed = job.installed?.buildId {
                        Text(current == installed ? "This build is up to date." : "A different build is available: \(current).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    MenuButton("Remove History Entry") { removing = job }
                }.padding(.vertical, 6)
            }
        } header: { Text("Installed Files") }
        footer: { Text("Repair checks the selected branch’s current build. Updates are stored separately; older files and saves are kept. Add the verified build to your library when ready.") }
        .modifier(SteamPanel())
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct SteamPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2))
            .listRowSeparator(.hidden)
    }
}

private struct SteamDownloadOptionsView: View {
    let game: SteamOwnedGame
    @ObservedObject var steam: SteamLibraryModel
    let enqueue: (SteamInstallOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = SteamInstallOptions()
    @State private var chooseDlc = false

    private var details: SteamGameDetails? { steam.detailsByApp[game.appId] }
    private var branches: [String] { details?.branches.filter { !$0.passwordRequired }.map(\.name) ?? ["public"] }
    private var languages: [String] { details?.languages ?? ["english"] }

    var body: some View {
        List {
            Section {
                Text(game.name).font(.headline)
                if steam.busy && details == nil { ProgressView("Loading download options…") }
                Picker("Branch", selection: $options.branch) {
                    ForEach(branches, id: \.self) { Text($0 == "public" ? "Default (public)" : $0).tag($0) }
                }.menuFocusable(adjust: { adjust(&options.branch, in: branches, by: $0) })
                Picker("Language", selection: $options.language) {
                    ForEach(languages, id: \.self) { Text($0.capitalized).tag($0) }
                }.menuFocusable(adjust: { adjust(&options.language, in: languages, by: $0) })
                Picker("Windows architecture", selection: $options.architecture) {
                    Text("64-bit").tag("64")
                    Text("32-bit").tag("32")
                }.menuFocusable(adjust: { options.architecture = $0 > 0 ? "32" : "64" })
                Stepper("Download connections: \(options.maxDownloads)", value: $options.maxDownloads, in: 1...8)
                    .menuFocusable(adjust: { options.maxDownloads = min(8, max(1, options.maxDownloads + $0)) })
            } footer: {
                Text("Public and unprotected beta branches are supported. Architecture controls which files download, not runtime compatibility.")
            }.modifier(SteamPanel())
            Section {
                MenuToggle("Include DLC", isOn: $options.includeDlc)
                if options.includeDlc, let ids = details?.dlcAppIds, !ids.isEmpty {
                    MenuToggle("Choose Individual DLC", isOn: $chooseDlc)
                    if chooseDlc {
                        ForEach(ids, id: \.self) { id in
                            MenuToggle("DLC · \(id)", isOn: Binding(get: { options.dlcAppIds.contains(id) }, set: { selected in
                                options.dlcAppIds.removeAll { $0 == id }
                                if selected { options.dlcAppIds.append(id) }
                            }))
                        }
                    }
                }
            } header: { Text("Additional Content") }
            footer: { Text("Steam checks access to every depot. Include DLC defaults to all authorized content. Unowned content cannot be downloaded.") }
            .modifier(SteamPanel())
            Section {
                MenuButton("Add to Download Queue") {
                    var selected = options
                    if !chooseDlc { selected.dlcAppIds = [] }
                    if chooseDlc && selected.dlcAppIds.isEmpty { selected.includeDlc = false }
                    enqueue(selected)
                }.libraryGlass(prominent: true).disabled(details == nil || steam.busy)
                if details == nil && !steam.busy {
                    MenuButton("Retry Loading Options") { steam.loadDetails(for: game) }
                }
            }.modifier(SteamPanel())
        }
        .iridiumListChrome()
        .navigationTitle("Download Options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) } }
        .task { steam.loadDetails(for: game) }
    }

    private func adjust(_ value: inout String, in choices: [String], by direction: Int) {
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(of: value) ?? 0
        value = choices[min(choices.count - 1, max(0, index + direction))]
    }
}

private struct SteamInstallReviewView: View {
    let job: SteamDownloadJob
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var steam: SteamLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var executable = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            if let installed = job.installed {
                Section {
                    Text(installed.name).font(.headline)
                    Picker("Windows executable", selection: $executable) {
                        Text("Choose executable").tag("")
                        ForEach(installed.executables, id: \.self) { Text($0).tag($0) }
                    }.menuFocusable(adjust: { direction in
                        guard !installed.executables.isEmpty else { return }
                        let index = installed.executables.firstIndex(of: executable) ?? 0
                        executable = installed.executables[min(installed.executables.count - 1, max(0, index + direction))]
                    })
                    MenuButton("Add to Library") {
                        adding = true
                        Task {
                            do {
                                try await viewModel.registerSteamDownload(title: installed.name, appID: String(installed.appId),
                                    directory: installed.directory, executable: executable)
                                steam.markAdded(job.id)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            adding = false
                        }
                    }.libraryGlass(prominent: true).disabled(executable.isEmpty || adding)
                    if adding { ProgressView("Adding game…") }
                    if let error { Text(error).font(.callout) }
                } footer: { Text("Choose the main game executable. Playing uses Iridium’s usual runtime and JIT checks. Updates keep the current prefix and settings. Previous versions and game-local saves are retained, but game-local saves are not automatically moved to a new version.") }
                .modifier(SteamPanel())
                .onAppear { if installed.executables.count == 1 { executable = installed.executables[0] } }
            }
        }
        .iridiumListChrome()
        .navigationTitle("Add Downloaded Game").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(adding)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(adding).keyboardShortcut(.cancelAction) } }
    }
}
