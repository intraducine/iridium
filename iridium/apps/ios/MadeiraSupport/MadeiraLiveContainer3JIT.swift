import Foundation
import UIKit
import Darwin

enum MadeiraLiveContainer3JIT {
    private static let persistentScriptRequestKey = "IridiumPersistentJITScriptRequested"
    private static var timer: Timer?
    private static var activation: Task<Void, Never>?
    private static var completion: ((Bool) -> Void)?
    private static var checking = false
    private static var request = UUID()
    private(set) static var lastFailure = "LiveContainer3 did not enable JIT."

    static func enableJIT(completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        request = UUID()
        let token = request
        let wasDebugged = jit_check_debugged()
        let deadline = Date().addingTimeInterval(180)

        guard let scriptURL = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let scriptData = try? Data(contentsOf: scriptURL)
        else {
            finish(false, message: "Cannot load the bundled JIT script for LiveContainer3.")
            return
        }

        var guest = URLComponents()
        guest.scheme = "stikjit"
        guest.host = "enable-jit"
        guest.queryItems = [
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "software.iridium"),
            URLQueryItem(name: "script-data", value: scriptData.base64EncodedString())
        ]
        guard let guestURL = guest.url,
              let destination = MadeiraExternalJITRouting.liveContainerURL(
                  for: guestURL,
                  scheme: MadeiraExternalJITRouting.liveContainer3Scheme
              )
        else {
            finish(false, message: "Cannot create the LiveContainer3 JIT request.")
            return
        }

        UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: "IridiumJITDeadline")
        UserDefaults.standard.set(true, forKey: persistentScriptRequestKey)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard request == token else { return }
            if Date() >= deadline {
                finish(false, message: "JIT timed out after opening LiveContainer3.")
            } else if checking && jit_check_debugged() {
                finish(true)
            }
        }

        UIApplication.shared.open(destination, options: [:]) { success in
            guard request == token else { return }
            guard success else {
                finish(
                    false,
                    message: "Cannot open LiveContainer3. Choose another route in Launch Support or verify the LiveContainer instance is installed."
                )
                return
            }

            RuntimeLogCapture.writeLine("[Launch] Opened LiveContainer3 for external JIT.")
            if !wasDebugged {
                checking = true
                return
            }

            activation = Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didBecomeActiveNotification
                ) {
                    guard !Task.isCancelled, request == token else { return }
                    checking = true
                    return
                }
            }
        }
    }

    static func cancel() {
        guard completion != nil else { return }
        finish(false, message: "LiveContainer3 JIT request cancelled.")
    }

    private static func finish(_ success: Bool, message: String? = nil) {
        timer?.invalidate()
        timer = nil
        activation?.cancel()
        activation = nil
        checking = false
        request = UUID()

        if let message {
            lastFailure = message
            RuntimeLogCapture.writeLine("[Launch] \(message)")
        }
        if !success {
            UserDefaults.standard.removeObject(forKey: persistentScriptRequestKey)
        }

        let callback = completion
        completion = nil
        callback?(success)
    }
}
