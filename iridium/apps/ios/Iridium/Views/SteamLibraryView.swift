import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct SteamLibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var steam = SteamLibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var search = ""
    @State private var executable = ""
    @State private var adding = false
    @State private var challengeImage: UIImage?

    var body: some View {
        NavigationStack {
            List {
                if !steam.state.signedIn { signIn }
                else {
                    Section {
                        Label(steam.state.accountName ?? "Steam", systemImage: "person.crop.circle.fill")
                        Button("Sign Out", role: .destructive) { steam.perform(["action": "signOut"]) }
                            .disabled(steam.busy || adding)
                    } footer: { Text("Games download directly to this device. Compatibility varies; games requiring the desktop Steam client may not launch.") }
                }

                if steam.busy || steam.state.appId != nil || steam.state.error != nil {
                    Section("Download status") {
                        if let appId = steam.state.appId,
                           let game = steam.state.games.first(where: { $0.appId == appId }) {
                            Text(game.name).font(.headline)
                        }
                        Text(steam.state.message).font(.subheadline)
                        if steam.state.totalBytes > 0 {
                            ProgressView(value: Double(steam.state.completedBytes), total: Double(steam.state.totalBytes))
                            Text("\(ByteCountFormatter.string(fromByteCount: steam.state.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: steam.state.totalBytes, countStyle: .file)) verified")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else if steam.busy { ProgressView() }
                        if steam.busy {
                            Button(steam.state.signedIn ? "Pause" : "Cancel Sign-in") { steam.perform(["action": "cancel"]) }
                                .disabled(steam.state.phase == "pausing")
                        }
                    }
                }

                if let installed = steam.state.installed {
                    Section("Ready to add") {
                        Picker("Windows executable", selection: $executable) {
                            Text("Choose executable").tag("")
                            ForEach(installed.executables, id: \.self) { Text($0).tag($0) }
                        }
                        Button {
                            adding = true
                            Task {
                                do {
                                    try await viewModel.registerSteamDownload(title: installed.name, appID: String(installed.appId),
                                        directory: installed.directory, executable: executable)
                                    dismiss()
                                } catch { steam.error = error.localizedDescription }
                                adding = false
                            }
                        } label: {
                            HStack { Text("Add to Library"); if adding { Spacer(); ProgressView() } }
                        }.disabled(executable.isEmpty || adding || steam.busy)
                    } footer: { Text("Choose the main game executable. Play will use Iridium's usual runtime and JIT checks.") }
                    .onAppear { if installed.executables.count == 1 { executable = installed.executables[0] } }
                }

                if steam.state.signedIn {
                    Section("Your games · \(steam.state.games.count)") {
                        if steam.state.games.isEmpty && !steam.busy {
                            Text("No games returned. Refresh your library to try again.").foregroundStyle(.secondary)
                        }
                        ForEach(steam.state.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { game in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(game.name).font(.headline)
                                Button("Download / resume", systemImage: "arrow.down.circle") {
                                    executable = ""
                                    steam.perform(["action": "install", "appId": game.appId])
                                }.disabled(steam.busy || adding)
                                .accessibilityLabel("Download or resume \(game.name)")
                            }.padding(.vertical, 6)
                        }
                    }
                }
                if let error = steam.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Steam")
            .searchable(text: $search, prompt: "Search your Steam games")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(adding).keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    if steam.state.signedIn {
                        Button("Refresh", systemImage: "arrow.clockwise") { steam.perform(["action": "library"]) }
                            .disabled(steam.busy || adding)
                    }
                }
            }
            .task { await steam.restore() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { steam.pauseForBackground() } }
            .onChange(of: steam.state.challengeUrl, initial: true) { _, value in
                challengeImage = value.flatMap(qrImage)
            }
            .interactiveDismissDisabled(adding)
        }
    }

    private var signIn: some View {
        Section {
            Label("Your Steam library, on this device", systemImage: "gamecontroller.fill").font(.headline)
            if !steam.busy { Text(steam.state.message).font(.subheadline).foregroundStyle(.secondary) }
            TextField("Steam account name", text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(steam.busy)
            SecureField("Password", text: $password).textContentType(.password).disabled(steam.busy)
            Button("Sign in to Steam") {
                steam.perform(["action": "signIn", "accountName": username, "password": password])
                password = ""
            }.disabled(steam.busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            Button("Sign in with QR code") { steam.perform(["action": "qr"]) }.disabled(steam.busy)
            if steam.state.phase == "guard" {
                Text(steam.state.message)
                TextField("Steam Guard code", text: $code).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Submit Code") { steam.perform(["action": "guard", "code": code]); code = "" }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let qr = challengeImage {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220)
                    .padding().background(.white).accessibilityLabel("Steam sign-in QR code. Scan with Steam Mobile on another device.")
            }
        } footer: {
            Text("Steam Guard is supported. Credentials go directly to Steam. Your password is never saved; the session is stored in this device's Keychain. Keep Iridium open while downloading; downloads pause when the app goes into the background.")
        }
    }

    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
