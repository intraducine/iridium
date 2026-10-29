"""Execute launch admission and setup storage without a runtime or real Keychain."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class LaunchFeedbackTests(unittest.TestCase):
    def run_swift(self, code):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'check.swift'
            binary = source.with_suffix('')
            source.write_text(code)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', module_cache('macosx'),
                            str(source), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_loading_screen_precedes_launch_work_and_rejects_duplicate_or_stale_requests(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        wrapper = source[source.index('    private func launchLibraryEntry('):source.index('    private func continueLibraryLaunch(')]
        model = (IOS / 'App/Adapters/Madeira/IridiumWindowsLibraryService.swift').read_text()
        prepare = model[model.index('    func prepare(_ entry:'):model.index('    /// A Steam game\'s saves')]
        self.run_swift('''import Foundation
struct LibraryEntry { let id = UUID() }
@MainActor enum TouchControlsHost { static var attachments = 0; static func attach() { attachments += 1 } }
@MainActor final class LibraryModel {
 var current: UUID?, preparing: LibraryEntry?, preparingSince = Date(), launching = false
''' + prepare + '''
}
@MainActor final class Host {
 let library = LibraryModel()
 var launches = 0
 func continueLibraryLaunch(_ entry: LibraryEntry) {
  precondition(library.preparing?.id == entry.id && TouchControlsHost.attachments > 0)
  launches += 1
 }
 func play(_ entry: LibraryEntry) { launchLibraryEntry(entry) }
''' + wrapper + '''
}
@main struct Check {
 @MainActor static func main() async throws {
  let host = Host(), entry = LibraryEntry()
  host.play(entry); host.play(entry)
  precondition(host.library.preparing?.id == entry.id && host.launches == 0 && TouchControlsHost.attachments == 1)
  let deadline = Date().addingTimeInterval(3)
  while host.launches == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
  precondition(host.launches == 1)
  host.library.preparing = nil
  host.play(entry); host.library.preparing = LibraryEntry()
  try await Task.sleep(for: .milliseconds(250))
  precondition(host.launches == 1)
  host.library.preparing = nil; host.library.current = UUID()
  host.play(entry); precondition(host.library.preparing == nil)
 }
}
''')

    def test_failed_jit_closes_only_its_own_loading_screen(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        start = source.index('    private func launchAfterJITEnded(')
        callback = source[start:source.index('    /// Whether a launch may ask', start)]
        self.run_swift('''import Foundation
struct LibraryEntry { let id: UUID }
@MainActor final class LibraryModel {
 var startingJIT: UUID?, preparing: LibraryEntry?, current: UUID?, error: String?
}
@MainActor enum StikJITHelper { static var ready = false }
func wine_process_is_running() -> Int { 0 }
struct LogStore { func log(_ text: String) {} }
@MainActor final class Host {
 let library = LibraryModel(), logStore = LogStore()
 var launchAfterJIT: (() -> Void)?
 func finish(_ started: Bool) { launchAfterJITEnded(started: started) }
''' + callback + '''
}
@main struct Check {
 @MainActor static func main() {
  let host = Host(), request = UUID(), newer = UUID()
  var launches = 0
  host.library.startingJIT = request; host.library.preparing = .init(id: request)
  host.launchAfterJIT = { launches += 1 }; host.finish(false)
  precondition(host.library.preparing == nil && host.library.startingJIT == nil && launches == 0)
  host.library.startingJIT = request; host.library.preparing = .init(id: newer)
  host.launchAfterJIT = { launches += 1 }; host.finish(false)
  precondition(host.library.preparing?.id == newer && launches == 0)
  host.library.startingJIT = request; host.library.preparing = .init(id: request)
  host.launchAfterJIT = { launches += 1 }; StikJITHelper.ready = true; host.finish(true)
  precondition(launches == 1 && host.library.preparing?.id == request)
  host.finish(true); precondition(launches == 1)
 }
}
''')

    def test_setup_keychain_updates_without_deleting_and_reports_retryable_read_failure(self):
        source = (IOS / 'MadeiraFrontend/IridiumOnboarding.swift').read_text()
        storage = source[source.index('@MainActor enum OnboardingCompletion'):source.index('enum OnboardingRules')]
        storage = storage.replace(' as CFDictionary', '')
        self.run_swift('''import Foundation
typealias OSStatus = Int32
typealias CFTypeRef = AnyObject
let errSecSuccess: OSStatus = 0, errSecItemNotFound: OSStatus = -25300, errSecDuplicateItem: OSStatus = -25299
let kSecClass = "class", kSecClassGenericPassword = "generic", kSecAttrService = "service", kSecAttrAccount = "account"
let kSecReturnData = "return", kSecMatchLimit = "limit", kSecMatchLimitOne = "one", kSecValueData = "data"
let kSecAttrAccessible = "accessible", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "after-first-unlock-device"
@MainActor enum Store {
 static var value: Data?, readStatus: OSStatus = 0, writeStatus: OSStatus = 0, inserts = 0, updates = 0
 static func validate(_ query: [String: Any]) {
  precondition(query[kSecClass] as? String == kSecClassGenericPassword)
  precondition(query[kSecAttrService] as? String == "software.iridium.setup")
  precondition(query[kSecAttrAccount] as? String == "completed")
 }
}
@MainActor func SecItemCopyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
 Store.validate(query)
 precondition(query[kSecReturnData] as? Bool == true && query[kSecMatchLimit] as? String == kSecMatchLimitOne)
 if Store.readStatus != 0 { return Store.readStatus }
 guard let value = Store.value else { return errSecItemNotFound }
 result.pointee = value as NSData; return 0
}
@MainActor func SecItemUpdate(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
 Store.validate(query); Store.updates += 1
 if Store.writeStatus != 0 { return Store.writeStatus }
 guard Store.value != nil else { return errSecItemNotFound }
 Store.value = attributes[kSecValueData] as? Data; return 0
}
@MainActor func SecItemAdd(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 Store.validate(query); Store.inserts += 1
 precondition(query[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
 if Store.writeStatus != 0 { return Store.writeStatus }
 Store.value = query[kSecValueData] as? Data; return 0
}
''' + storage + '''
@main struct Check {
 @MainActor static func main() {
  precondition(OnboardingCompletion.load() == false)
  OnboardingCompletion.save(); precondition(OnboardingCompletion.load() == true && Store.inserts == 1)
  OnboardingCompletion.save(); precondition(Store.inserts == 1 && Store.updates == 2)
  Store.readStatus = -25308
  precondition(OnboardingCompletion.load() == nil && Store.value == Data([1]))
  Store.writeStatus = -25308; OnboardingCompletion.save()
  precondition(Store.inserts == 1 && Store.value == Data([1]))
  Store.readStatus = 0; precondition(OnboardingCompletion.load() == true)
  Store.value = Data([99]); precondition(OnboardingCompletion.load() == false)
 }
}
''')


if __name__ == '__main__': unittest.main()
