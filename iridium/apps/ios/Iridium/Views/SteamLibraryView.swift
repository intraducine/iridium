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
    @State private var deleting: SteamDownloadJob?
    @State private var overridingStorage: SteamDownloadJob?

    private enum Page: String, CaseIterable, Identifiable {
        case queue = "Queue", library = "Steam", installed = "Installed"
        var id: Self { self }
    }

    var body: some View {
        presentedView
        .confirmationDialog("Download despite the storage warning?", isPresented: Binding(get: { overridingStorage != nil }, set: { if !$0 { overridingStorage = nil } }), titleVisibility: .visible) {
            Button("Download Anyway", role: .destructive) {
                if let job = overridingStorage { steam.downloadAnyway(job.id) }
                overridingStorage = nil
            }
            Button("Keep Paused", role: .cancel) { overridingStorage = nil }
        } message: {
            if let storage = overridingStorage?.storage {
                Text("Last check: \(bytes(storage.requiredBytes)) needed, including \(bytes(storage.safetyMarginBytes)) safety margin. Available: \(storage.availableBytes.map(bytes) ?? "unknown").")
            }
            Text("Only this attempt will skip the storage estimate. If the device runs out of space, this download and other apps may fail to save. Verified partial files are kept, and file verification stays on. Pausing or retrying will check storage again.")
        }
        .confirmationDialog("Delete game files?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Game Files", role: .destructive) {
                guard let job = deleting else { return }
                deleting = nil
                Task {
                    do { try await viewModel.deleteSteamDownload(job, from: steam) }
                    catch { steam.error = "Could not delete game files: \(error.localizedDescription)" }
                }
            }
            Button("Keep Files", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes the selected Steam copy and its library entry. Iridium keeps separate Windows profile saves. Files saved inside the game folder will be deleted.")
        }
    }

    private var chromeView: some View {
        list
        .iridiumListChrome(onBack: onBack)
        .buttonStyle(.borderless)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { navigationTools }
    }

    private var presentedView: some View {
        chromeView
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
        .confirmationDialog("Remove from Downloads?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from Downloads", role: .destructive) { if let job = removing { steam.remove(job.id) }; removing = nil }
            Button("Keep Download", role: .cancel) { removing = nil }
        } message: {
            Text("The download is removed from this list. Game files, partial files, and saves stay on this device.")
        }
    }

    private var list: some View {
        List {
            pagePicker
            statusSections
            pageContent
        }
    }

    @ToolbarContentBuilder private var navigationTools: some ToolbarContent {
        if let onBack {
            ToolbarItem(placement: .topBarLeading) {
                Button("Library", systemImage: "chevron.backward", action: onBack)
                    .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
            }
        }
        ToolbarItem(placement: .topBarTrailing) { accountMenu }
    }

    private var accountMenu: some View {
        Menu {
            if steam.state.signedIn {
                Text(steam.state.accountName ?? "Steam")
                if steam.busy { Text("Finish or pause the current Steam task first.") }
                Button("Refresh Steam Library", systemImage: "arrow.clockwise") { steam.perform(["action": "library"]) }
                    .disabled(steam.busy)
                Button("Sign Out", role: .destructive) { steam.perform(["action": "signOut"]) }
                    .disabled(steam.busy)
            } else { Button("Steam Sign-in") { page = .library } }
        } label: {
            Label("Steam Account", systemImage: "person.crop.circle")
        }.tint(.white).accessibilityLabel("Steam account")
    }

    private var pagePicker: some View {
        Section {
            Picker("Downloads section", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
                .menuFocusable(action: { changePage(1) }, adjust: changePage)
                .accessibilityIdentifier("steamDownloadsSection")
        }.listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    @ViewBuilder private var statusSections: some View {
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
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .queue: queueSection
        case .library: librarySection
        case .installed: installedSection
        }
    }

    private func changePage(_ direction: Int) {
        let pages = Page.allCases
        guard let index = pages.firstIndex(of: page) else { return }
        page = pages[min(pages.count - 1, max(0, index + direction))]
    }

    private var signInSection: some View {
        Section {
            Text("Sign in to Steam").font(.headline)
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
            Text("Your password is not saved. Iridium keeps your sign-in on this device.")
        }.modifier(SteamPanel())
    }

    private var librarySection: some View {
        Section {
            if steam.state.signedIn {
                MenuTextField("Search your Steam games", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .modifier(SteamCard())
                if steam.state.games.isEmpty && !steam.busy {
                    Text("No games found.").foregroundStyle(.secondary)
                    MenuButton("Refresh Library") { steam.perform(["action": "library"]) }
                }
                ForEach(steam.state.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { game in
                    HStack(spacing: 14) {
                        SteamCover(appId: game.appId, width: 96, height: 144)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(game.name).font(.headline).lineLimit(2)
                            gameActions(game)
                        }
                    }.modifier(SteamCard())
                }
            } else {
                Text("Sign in to see your Steam library.").foregroundStyle(.secondary)
            }
        } header: { Text(steam.state.signedIn ? "Games · \(steam.state.games.count)" : "Games") }
        footer: { Text("After a download finishes, add it to your Iridium library.") }
        .modifier(SteamPanel())
    }

    @ViewBuilder private func gameActions(_ game: SteamOwnedGame) -> some View {
        let account = SteamDownloadJob.accountKey(steam.account ?? "")
        let queued = steam.queue.jobs.contains { $0.appId == game.appId && $0.isPending && $0.account == account }
        let installed = steam.queue.jobs.contains { $0.appId == game.appId && $0.status == .completed && $0.account == account }
        MenuButton(action: {
            if installed { page = .installed }
            else { configuring = game }
        }) {
            Label(queued ? "Queued" : installed ? "Manage Download" : "Download", systemImage: installed ? "checkmark.circle" : "arrow.down.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
            .disabled(queued).accessibilityLabel(queued ? "\(game.name) is in the queue" : installed ? "Manage \(game.name) download" : "Download \(game.name)")
    }

    private var queueSection: some View {
        Section {
            if steam.queue.jobs.allSatisfy({ $0.status == .completed }) {
                ContentUnavailableView("No Downloads Queued", systemImage: "arrow.down.circle",
                    description: Text("Choose a game in Steam to start a download."))
            } else {
                HStack(spacing: 18) {
                    MenuButton("Resume Queue", systemImage: "play.fill") { steam.resumeQueue() }
                        .frame(minHeight: 44).disabled(!steam.state.signedIn)
                    MenuButton("Pause All", systemImage: "pause.fill") { steam.pauseQueue() }
                        .frame(minHeight: 44).disabled(steam.queue.isPaused)
                }
                if steam.queue.isPaused { Text("Queue paused. Resume when you are ready.").font(.callout).foregroundStyle(.secondary) }
                ForEach(steam.queue.jobs.filter { $0.status != .completed }) { job in
                    HStack(spacing: 14) {
                        SteamCover(appId: job.appId, width: 96, height: 144)
                        VStack(alignment: .leading, spacing: 8) {
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
                                Text("This download belongs to another Steam account.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 0) { queueActions(job) }
                        }
                    }.modifier(SteamCard())
                }
            }
        } header: { Text("Downloads · \(steam.pendingCount)") }
        footer: {
            Text(LiveContainerIntegration.isHosted()
                ? "Keep Iridium open in LiveContainer. Downloads pause when you leave; guest Live Activities are unavailable."
                : "Prepared batches can transfer on Wi-Fi in the background. iOS decides when verification and the next batch can run. If progress stops or the app is closed, reopen Iridium and resume. The Live Activity shows the last observed verified progress.")
        }
        .modifier(SteamPanel())
    }

    @ViewBuilder private func queueActions(_ job: SteamDownloadJob) -> some View {
        if job.status == .running || job.status == .queued {
            MenuButton("Pause") { steam.pause(job.id) }.frame(minHeight: 44).disabled(job.phase == "pausing")
            if job.status == .queued { MenuButton("Download Next") { steam.prioritize(job.id) }.frame(minHeight: 44) }
            MenuButton("Cancel") { steam.cancel(job.id) }.frame(minHeight: 44).disabled(job.phase == "pausing")
        } else {
            if job.canResume {
                MenuButton(job.status == .failed ? "Retry" : "Resume") { steam.resume(job.id) }.frame(minHeight: 44)
                    .disabled(job.account != SteamDownloadJob.accountKey(steam.account ?? ""))
            }
            if job.canDownloadAnyway {
                MenuButton("Download Anyway…") { overridingStorage = job }.frame(minHeight: 44)
                    .disabled(steam.busy || job.account != SteamDownloadJob.accountKey(steam.account ?? ""))
                    .accessibilityHint("Review the low-storage risks before retrying this download")
            }
            MenuButton("Remove from Downloads") { removing = job }.frame(minHeight: 44)
        }
    }

    private var installedSection: some View {
        Section {
            if completedJobs.isEmpty {
                ContentUnavailableView("No Completed Downloads", systemImage: "checkmark.circle",
                    description: Text("Verified downloads appear here, ready to add to your library."))
            }
            ForEach(latestCompletedJobs) { installedRow($0) }
        } header: { Text("Installed Files") }
        footer: { Text("Repair checks downloaded files. Updates keep older versions and saves.") }
        .modifier(SteamPanel())
    }

    private var completedJobs: [SteamDownloadJob] {
        steam.queue.jobs.filter { $0.status == .completed && $0.installed != nil }
    }

    private var latestCompletedJobs: [SteamDownloadJob] {
        var seen = Set<String>()
        return completedJobs.reversed().filter { seen.insert("\($0.account):\($0.appId)").inserted }
    }

    private func installedRow(_ job: SteamDownloadJob) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SteamCover(appId: job.appId, width: 96, height: 144)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.name).font(.headline).lineLimit(2)
                if let build = job.installed?.buildId {
                    Text("Build \(build) · \(job.options.branch)").font(.caption).foregroundStyle(.secondary)
                }
                if job.addedToLibrary {
                    Label("Added to Library", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else { MenuButton("Add to Library") { reviewing = job }.frame(minHeight: 44) }
                MenuButton("Repair or Update") { steam.repairOrUpdate(job); page = .queue }
                    .frame(minHeight: 44)
                    .disabled(!steam.state.signedIn || job.account != SteamDownloadJob.accountKey(steam.account ?? ""))
                if let branch = steam.detailsByApp[job.appId]?.branches.first(where: { $0.name == job.options.branch }),
                   let current = branch.buildId, let installed = job.installed?.buildId {
                    Text(current == installed ? "This build is up to date." : "A different build is available: \(current).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    Button("Check for Updates") { steam.loadDetails(for: SteamOwnedGame(appId: job.appId, name: job.name)) }
                        .disabled(steam.busy)
                    Button("Remove from Downloads", role: .destructive) { removing = job }
                    Button("Delete Game Files", role: .destructive) { deleting = job }.disabled(steam.busy)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "ellipsis.circle")
                        Text("More")
                    }.foregroundStyle(.white)
                }
                    .tint(.white).accessibilityLabel("More Download Actions").frame(minHeight: 44)
                olderCopies(for: job)
            }
        }.modifier(SteamCard())
    }

    @ViewBuilder private func olderCopies(for job: SteamDownloadJob) -> some View {
        let older = completedJobs.filter { $0.id != job.id && $0.appId == job.appId && $0.account == job.account }
        if !older.isEmpty {
            DisclosureGroup("Older Copies (\(older.count))") {
                ForEach(older.reversed()) { copy in
                    Text("Build \(copy.installed?.buildId ?? "Unknown")").font(.footnote).foregroundStyle(.secondary)
                    MenuButton("Use This Copy") { reviewing = copy }
                    MenuButton("Delete This Copy", role: .destructive) { deleting = copy }.disabled(steam.busy)
                }
            }
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct SteamCover: View {
    let appId: UInt32
    let width: CGFloat
    let height: CGFloat

    private var assetRoot: URL { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/")! }

    var body: some View {
        AsyncImage(url: assetRoot.appendingPathComponent("library_600x900.jpg")) { phase in
            switch phase {
            case .success(let image): cover(image)
            case .failure:
                SteamCoverFallback(appId: appId, width: width, height: height)
            default: placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func cover(_ image: Image) -> some View {
        image.resizable().scaledToFill().frame(width: width, height: height).clipped()
    }

    private var placeholder: some View {
        Image(systemName: "gamecontroller").font(.title3).foregroundStyle(.secondary)
            .frame(width: width, height: height).background(Color.white.opacity(0.08))
    }
}

private struct SteamCoverFallback: View {
    let appId: UInt32
    let width: CGFloat
    let height: CGFloat
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill().frame(width: width, height: height).clipped()
            } else {
                Image(systemName: "gamecontroller").font(.title3).foregroundStyle(.secondary)
                    .frame(width: width, height: height).background(Color.white.opacity(0.08))
            }
        }
        .task(id: appId) {
            url = nil
            let resolved = await LibraryArtwork.shared.steamPortraitCoverURL(for: appId)
            if !Task.isCancelled { url = resolved }
        }
    }
}

private struct SteamPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct SteamCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
    }
}

private struct SteamDownloadOptionsView: View {
    let game: SteamOwnedGame
    @ObservedObject var steam: SteamLibraryModel
    let enqueue: (SteamInstallOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = SteamInstallOptions()
    @State private var chooseDlc = false
    @State private var storageEstimate: String?

    private var details: SteamGameDetails? { steam.detailsByApp[game.appId] }
    private var branches: [String] { details?.branches.filter { !$0.passwordRequired }.map(\.name) ?? ["public"] }
    private var languages: [String] { details?.languages ?? ["english"] }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    SteamCover(appId: game.appId, width: 56, height: 84)
                    Text(game.name).font(.headline)
                }
                Text(storageEstimate.map { "Storage needed: about \($0)" }
                    ?? "Size not listed. Download size appears after Steam checks the files.")
                    .font(.callout)
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
                Text("Choose which version and language to download.")
            }.listRowBackground(Rectangle().fill(.regularMaterial)).listRowSeparator(.hidden)
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
            footer: { Text("Only content owned by your Steam account can be downloaded.") }
            .listRowBackground(Rectangle().fill(.regularMaterial)).listRowSeparator(.hidden)
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
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .iridiumListChrome()
        .navigationTitle("Download Options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) } }
        .task {
            steam.loadDetails(for: game)
            storageEstimate = await LibraryArtwork.shared.steamStoreStorageEstimate(for: game.appId)
        }
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
                    HStack(spacing: 14) {
                        SteamCover(appId: job.appId, width: 56, height: 84)
                        Text(installed.name).font(.headline)
                    }
                    Picker("Game file (.exe)", selection: $executable) {
                        Text("Choose game file").tag("")
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
                } footer: { Text("Choose the main game file. Updates keep your settings and saves. Saves inside an older game folder may need to be moved manually.") }
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
