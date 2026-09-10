import Foundation
import CryptoKit

@main enum PairingCheck {
    static func main() throws {
        // Synthetic keys only. Test the formats emitted by idevice and iloader.
        let key = Curve25519.Signing.PrivateKey()
        let remote: [String: Any] = ["identifier": UUID().uuidString,
            "public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation]
        let lockdown: [String: Any] = ["HostID": "test-host",
            "HostCertificate": Data([1]), "HostPrivateKey": Data([2])]
        let combined = remote.merging(lockdown) { a, _ in a }
        func encode(_ record: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: record, format: format, options: 0)
        }
        for record in [remote, combined] {
            for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
                try JITPairing.validate(encode(record, format))
            }
        }
        var malformed = [[String: Any]]()
        malformed.append(lockdown)
        for field in ["identifier", "public_key", "private_key"] {
            var record = remote; record.removeValue(forKey: field); malformed.append(record)
        }
        for field in ["public_key", "private_key"] {
            var record = remote; record[field] = Data([1]); malformed.append(record)
            record[field] = "not binary data"; malformed.append(record)
        }
        var record = remote; record["identifier"] = ""; malformed.append(record)
        record = remote; record["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation; malformed.append(record)
        let invalid = try malformed.map { try encode($0) } + [Data(), Data("not a plist".utf8), Data(repeating: 0, count: 1024 * 1024 + 1)]
        for data in invalid {
            do { try JITPairing.validate(data); fatalError("Accepted an invalid remote pairing record") }
            catch { }
        }
        print("PASS: remote-only and iloader combined pairing (XML/binary); rejects legacy-only, missing/wrong/mismatched keys, malformed and oversized records")
    }
}
