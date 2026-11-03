// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import Combine
import UIKit

@MainActor final class LibraryStoreSheets: ObservableObject {
    static let shared = LibraryStoreSheets()
    struct Game<ID: Hashable>: Identifiable { let id: ID }
    @Published var itchGame: Game<Int>?
    @Published var itchSignIn = false
    @Published var itchFind = false
    @Published var epicGame: Game<String>?
    @Published var epicSignIn = false
    @Published var eaGame: Game<String>?
    @Published var eaSignIn = false
}
