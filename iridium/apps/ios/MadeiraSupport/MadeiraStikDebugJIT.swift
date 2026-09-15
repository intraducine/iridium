import Darwin
import Foundation
import UIKit

/// Current StikDebug URL integration for Madeira. Keep debugger acquisition
/// separate from StikJITHelper's allocator/detach implementation so protocol
/// updates cannot perturb the working JIT memory path.
@MainActor
enum MadeiraStikDebugJIT {
    private static let persistentScriptRequestKey = "IridiumPersistentJITScriptRequested"
    private static var timer: Timer?
    private static var completion: ((Bool) -> Void)?
    private static var request = UUID()
    private(set) static var lastFailure = "StikDebug did not enable JIT."

    static var isAvailable: Bool {
        guard let url = URL(string: "stikdebug://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func enableJIT(completion: @escaping (Bool) -> Void) {
        cancel(notify: false)
        self.completion = completion
        let token = UUID()
        request = token
        let deadline = Date().addingTimeInterval(180)

        UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: "IridiumJITDeadline")
        UserDefaults.standard.set(true, forKey: persistentScriptRequestKey)

        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            finish(false, message: "Could not determine Iridium's bundle ID for StikDebug.")
            return
        }
        guard let scriptURL = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let scriptData = try? Data(contentsOf: scriptURL) else {
            finish(false, message: "Cannot load the bundled JIT script for StikDebug.")
            return
        }

        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-data", value: scriptData.base64EncodedString()),
        ]
        guard let url = components.url else {
            finish(false, message: "Cannot create the StikDebug JIT request.")
            return
        }

        RuntimeLogCapture.writeLine(
            "[Launch] Opening StikDebug for pid=\(getpid()) hosted=\(LiveContainerIntegration.isHosted()) bundle=\(bundleID)."
        )

        let pollTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard request == token, Self.completion != nil else { return }
                if jit_check_debugged() {
                    finish(true)
                } else if Date() >= deadline {
                    finish(false, message: "StikDebug JIT timed out.")
                }
            }
        }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)

        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in
                guard request == token, Self.completion != nil else { return }
                if opened {
                    RuntimeLogCapture.writeLine("[Launch] StikDebug JIT request opened; waiting for debugger attachment.")
                } else {
                    finish(false, message: "Could not open StikDebug. Verify that it is installed.")
                }
            }
        }
    }

    static func cancel() {
        cancel(notify: true)
    }

    private static func cancel(notify: Bool) {
        guard completion != nil else {
            timer?.invalidate()
            timer = nil
            return
        }
        if notify { finish(false, message: "StikDebug JIT request cancelled.") }
        else {
            timer?.invalidate()
            timer = nil
            completion = nil
            request = UUID()
        }
    }

    private static func finish(_ success: Bool, message: String? = nil) {
        timer?.invalidate()
        timer = nil
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
