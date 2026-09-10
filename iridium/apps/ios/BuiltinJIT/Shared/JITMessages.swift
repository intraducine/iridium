import Foundation
import CryptoKit

@objc(IRJITWorker)
protocol JITWorker {
    func enable(_ pid: Int32, pairing: Data)
}

@objc(IRJITHost)
protocol JITHost {
    func scriptListening()
    func preparation(_ stage: String)
    func finished(_ error: String?)
}

enum JITPairing {
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 1024 * 1024,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["identifier"] as? String, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              signingKey.publicKey.rawRepresentation == publicKey
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}
