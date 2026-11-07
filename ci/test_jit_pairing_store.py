# SPDX-License-Identifier: AGPL-3.0-only
"""Execute the production pairing store against inert Security API endpoints."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]


class PairingStoreTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_failed_update_keeps_existing_credential_and_success_is_verified(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        store = source[source.index('enum JITPairingFileStore {'):source.index('\n@MainActor\nfinal class JITCoordinator')]
        # Only replace I/O endpoints. Never call the host's actual Keychain or legacy migration.
        for name in ('Update', 'Add', 'CopyMatching', 'Delete'):
            store = store.replace('SecItem' + name + '(', 'fixtureSecItem' + name + '(')
        store = store.replace('UserDefaults.standard', 'fixtureDefaults')
        fixture = r'''
import Foundation
import Security
let suite = "iridium-test-" + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: suite)!
defer { fixtureDefaults.removePersistentDomain(forName: suite) }
enum JITPairingSource: String { case imported, onDevice }
final class LogStore { static let shared = LogStore(); func log(_ line: String) { } }
var saved: Data?
var refuse = false, badReadback = false
var updates = 0, adds = 0, reads = 0
func fixtureSecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    updates += 1
    if refuse { return errSecAuthFailed }
    guard saved != nil else { return errSecItemNotFound }
    let values = unsafeBitCast(attributes, to: NSDictionary.self)
    saved = values[kSecValueData as String] as? Data
    precondition(values[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    return errSecSuccess
}
func fixtureSecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    adds += 1
    let values = unsafeBitCast(attributes, to: NSDictionary.self)
    saved = values[kSecValueData as String] as? Data
    return errSecSuccess
}
func fixtureSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
    reads += 1
    guard let saved else { return errSecItemNotFound }
    result?.pointee = (badReadback ? Data([99]) : saved) as NSData
    return errSecSuccess
}
func fixtureSecItemDelete(_ query: CFDictionary) -> OSStatus { fatalError("Never delete a credential before storing its replacement") }
STORE
func pairing(_ name: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["identifier":name,
        "public_key":Data(repeating:0,count:32),"private_key":Data(repeating:0,count:32)], format:.binary, options:0)
}
let first = try pairing("fixture-A"), second = try pairing("fixture-B")
saved = first; refuse = true
do { try JITPairingFileStore.store(second,source:.imported); fatalError("Expected failed write") } catch { }
precondition(saved == first && updates == 1 && adds == 0 && reads == 0)
refuse = false
try JITPairingFileStore.store(second,source:.imported)
precondition(saved == second && updates == 2 && adds == 0 && reads == 1)
saved = nil
try JITPairingFileStore.store(first,source:.onDevice)
precondition(saved == first && adds == 1 && reads == 2)
badReadback = true
do { try JITPairingFileStore.store(second,source:.imported); fatalError("Expected unverified write") } catch { }
let calls = updates
for bytes in [Data(),Data("invalid".utf8),Data(repeating:0,count:1024*1024+1)] {
    do { try JITPairingFileStore.store(bytes,source:.imported); fatalError("Expected invalid input") } catch { }
}
precondition(updates == calls && adds == 1)
print("PASS pairing upsert: old credential survives failure; successful writes require readback; invalid inputs never reach storage")
'''.replace('STORE', store)
        with tempfile.TemporaryDirectory(prefix='iridium-pairing-store-') as directory:
            folder = Path(directory)
            unit = folder / 'main.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            result = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                str(unit), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
