// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SteamSettingsSection: View {
    /// Opens Steam sign-in or Madeira Dock. LibraryView presents the sheet from the
    /// Settings Form: a sheet attached to this section closed again as soon as it
    /// slid up whenever the Form rebuilt its rows.
    let open: (SettingsSheet) -> Void
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var cloud = SteamCloudSetting.shared
    @State private var confirmSignOut = false
    /// Settings › Steam › Game language (SteamLanguage); "" follows the device.
    @State private var language = SteamLanguage.chosen ?? ""

    /// Shown when Steam sign-in or Madeira Dock is available.
    static var shown: Bool { SteamSignIn.isEnabled || MadeiraDock.enabled }

    var body: some View {
        Section {
            if let name = signIn.accountName {
                LabeledContent("Signed in as", value: name)
                Button("Sign out of Steam", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.steamSignIn) } label: { Label("Sign in to Steam", systemImage: "person.crop.circle.badge.plus") }
            }
            Picker("Game language", selection: $language) {
                Text("Device language (\(SteamLanguage.name(SteamLanguage.device)))").tag("")
                ForEach(SteamLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
            }
            .pickerStyle(.navigationLink)
            .onChange(of: language) { _, value in SteamLanguage.choose(value.isEmpty ? nil : value) }
            // Off: no Steam Cloud checks, transfers or prompts before Play (docs/STEAM_CLOUD.md).
            if SteamOwnedLibrary.enabled {
                Toggle("Steam Cloud saves", isOn: $cloud.on)
            }
            if MadeiraDock.enabled {
                Button { open(.dock) } label: { Label("Madeira Dock", systemImage: "shippingbox") }
                if let status = dock.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Steam")
        } footer: {
            Text("Choose the language for new Steam downloads. Games without that language use English. Download an installed game again to change its language. Signing out removes this device’s saved Steam sign-in.")
        }
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signIn.signOut() }
        }
        .onAppear { signIn.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in signIn.refresh() }
    }
}

// MARK: - Madeira Dock in the library

extension LibraryEntry {
    static let dockSessionID = UUID(uuidString: "5D0C4A3E-2B7F-4C61-9E0A-6B1D2F3C4E5A")!

    /// A Dock start from the library runs as a library session (full-screen
    /// view, starting screen, in-game menu, one session per run) with this
    /// entry. It is a desktop session: explorer's virtual desktop runs the
    /// host. It is never saved to the library.
    static func dockSession(title: String, width: Int, height: Int) -> LibraryEntry {
        var entry = LibraryEntry(title: title.isEmpty ? "Madeira Dock" : title, relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = dockSessionID; entry.desktop = true; entry.resolution = "\(width)x\(height)"
        entry.graphicsAPI = "Madeira Dock"
        return entry
    }
}
