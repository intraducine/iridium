// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Display-only native engine surface. IridiumConsolePlayer owns all input and UI.
struct IridiumNativePSPSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
