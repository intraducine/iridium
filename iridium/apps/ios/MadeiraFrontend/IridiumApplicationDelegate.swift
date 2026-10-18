// SPDX-License-Identifier: AGPL-3.0-only
import UIKit

@MainActor
final class IridiumApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        IridiumConsoleSession.shared.nativePSPController?.supportedInterfaceOrientations ?? .all
    }
}
