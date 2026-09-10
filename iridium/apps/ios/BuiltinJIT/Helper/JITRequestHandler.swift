import Foundation
import StikJIT

@objc(JITRequestHandler)
final class JITRequestHandler: NSObject, NSExtensionRequestHandling, JITWorker {
    private var context: NSExtensionContext?
    private var connection: NSXPCConnection?
    private var host: JITHost?
    private var accepted = false
    private let queue = DispatchQueue(label: "software.iridium.jit.worker")

    func beginRequest(with context: NSExtensionContext) {
        do {
            guard let item = context.inputItems.first as? NSExtensionItem,
                  let endpoint = item.userInfo?["IridiumJITEndpoint"] as? NSXPCListenerEndpoint
            else { throw CocoaError(.coderReadCorrupt) }
            self.context = context
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.exportedInterface = NSXPCInterface(with: JITWorker.self)
            connection.exportedObject = self
            connection.remoteObjectInterface = NSXPCInterface(with: JITHost.self)
            connection.resume()
            self.connection = connection
            host = connection.remoteObjectProxy as? JITHost
        } catch { context.cancelRequest(withError: error) }
    }

    func enable(_ pid: Int32, pairing: Data) {
        queue.async { [self] in
            guard !accepted, pid > 0, pid != getpid(), pid == connection?.processIdentifier else {
                host?.finished("The JIT request did not match its host process."); return
            }
            accepted = true
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID()).plist")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try JITPairing.validate(pairing)
                try pairing.write(to: file, options: [.atomic, .completeFileProtection])
                guard let script = Bundle.main.url(forResource: "madeira-jit", withExtension: "js") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                try StikJIT.enableJIT(targetPID: pid, pairingFile: file,
                    ddiPaths: DDIPaths.default(in: library.appendingPathComponent("StikJIT")),
                    script: .custom(script), forceScript: true,
                    preparationProgress: { [self] stage in
                        switch stage {
                        case .checkingReachability: host?.preparation("Connect LocalDevVPN. Checking the local connection.")
                        case .checkingDDI: host?.preparation("Checking Apple developer support files.")
                        case .downloadingDDI: host?.preparation("Downloading Apple developer support files.")
                        case .mountingDDI: host?.preparation("Preparing this iPhone for debugging.")
                        case .verifyingDDI: host?.preparation("Checking device preparation.")
                        case .ready: host?.preparation("Starting the game code preparation script.")
                        @unknown default: host?.preparation("Preparing JIT support.")
                        }
                    }, progress: { [self] line in
                        // Only forward our exact protocol marker, never raw framework logs or credentials.
                        if line == "IRIDIUM_SCRIPT_LISTENING" { host?.scriptListening() }
                    })
                host?.finished(nil)
            } catch {
                // Framework errors can include pairing paths and protocol responses. Keep them in the helper.
                host?.finished("Built-in JIT failed. Check LocalDevVPN and the pairing file. Restart Iridium before retrying.")
            }
        }
    }
}
