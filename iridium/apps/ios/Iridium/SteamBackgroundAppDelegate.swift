import UIKit

final class SteamBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard !LiveContainerIntegration.isHosted() else { completionHandler(); return }
        SteamBackgroundSession.shared.handleEvents(identifier: identifier) {
            MainActor.assumeIsolated { SteamLibraryModel.shared.processTransferWake(completion: completionHandler) }
        }
    }
}
