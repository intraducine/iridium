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

    def test_game_memory_reserve_stops_before_process_limit(self):
        presentation = (IOS / 'Iridium/RuntimeLaunchPresentation.swift').read_text()
        self.run_swift(presentation + """
@main struct Check { static func main() {
    func stop(_ availableMiB: UInt64?, warning: Bool = false) -> Bool {
        RuntimeMemorySnapshot(usedBytes: 0, availableBytes: availableMiB.map { $0 << 20 })
            .shouldStopGame(memoryWarning: warning)
    }
    precondition(!stop(nil, warning: true))
    precondition(!stop(2048, warning: true))
    precondition(!stop(1153))
    precondition(stop(1153, warning: true))
    precondition(stop(1024) && stop(72) && stop(0))
}}""")

    def test_controls_overlay_disappears_between_library_sessions(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        start = source.index('struct TouchControlsOverlay: View')
        expression = source[source.index('                if (landscape || iridiumConsole)', start):].split(' {', 1)[0].strip()[3:]
        window = source[source.index('final class ControlsWindow:'):source.index('enum TouchControlsHost')]
        self.assertLess(window.index('guard !library.enabled || library.current != nil || library.preparing != nil'),
                        window.index('if m.editing'))
        self.run_swift('import Foundation\n@main struct Check { static func main() {\n' +
            'func shown(_ enabled: Bool, _ session: Bool, _ landscape: Bool, _ iridiumConsole: Bool = false, _ iridiumSuspended: Bool = false) -> Bool {\n' +
            'let library = (enabled: enabled, unused: false)\nreturn ' + expression + '\n}\n' +
            'for landscape in [false, true] { precondition(!shown(true, false, landscape)); precondition(shown(true, true, true)) }\n' +
            'precondition(shown(false, false, true)); precondition(!shown(false, false, false))\n' +
            'precondition(shown(true, true, true, true)); precondition(!shown(true, true, true, false, true))\n}}')

    def test_dock_executable_scan_does_not_run_on_main_thread(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        start = source.index('            let need = await Task.detached(')
        scan = source[start:source.index('            guard ', start)]
        self.run_swift('''import Foundation
        enum StikJITHelper {
            static func fixedBaseWindowMB(in folder: URL) -> Int {
                precondition(!Thread.isMainThread)
                return 192
            }
        }
        @main struct Check { @MainActor static func main() async {
            let installFolder = URL(fileURLWithPath: "/fixture")
        ''' + scan + 'precondition(need == 192)\n}}')

    def test_loading_screen_precedes_launch_work_and_rejects_duplicate_or_stale_requests(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        wrapper = source[source.index('    private func launchLibraryEntry('):source.index('    private func continueLibraryLaunch(')]
        model = (IOS / 'App/Adapters/Madeira/IridiumWindowsLibraryService.swift').read_text()
        prepare = model[model.index('    func prepare(_ entry:'):model.index('    /// A Steam game\'s saves')]
        self.run_swift('''import Foundation
struct LibraryEntry { let id = UUID() }
@MainActor final class RuntimePerformanceDiagnostics {
 static let shared = RuntimePerformanceDiagnostics()
 var phases: [String] = []
 func record(_ phase: String) { phases.append(phase) }
}
@MainActor enum TouchControlsHost { static var attachments = 0; static func attach() { attachments += 1 } }
@MainActor final class LibraryModel {
 var preparationID = UUID()
 var current: UUID?, preparing: LibraryEntry?, preparingSince = Date(), launching = false
 var launchAfterJIT: (() -> Void)?, startingJIT: UUID?, cloudRetry: (() -> Void)?
 var cancellableLaunchID: UUID? { preparing == nil ? nil : preparationID }
 func requestQuit() { fatalError("Preflight cancellation tried to stop a native job") }
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
  precondition(RuntimePerformanceDiagnostics.shared.phases == ["windows-play"])
  precondition(host.library.preparing?.id == entry.id && host.launches == 0 && TouchControlsHost.attachments == 1)
  let deadline = Date().addingTimeInterval(3)
  while host.launches == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
  precondition(host.launches == 1)
  host.library.preparing = nil
  host.play(entry); host.library.preparing = LibraryEntry()
  try await Task.sleep(for: .milliseconds(250))
  precondition(host.launches == 1)
  host.library.preparing = nil
  host.play(entry)
  let cancelled = host.library.preparationID
  host.library.launchAfterJIT = { fatalError("Cancelled JIT callback") }
  host.library.startingJIT = entry.id
  host.library.cloudRetry = { fatalError("Cancelled Cloud callback") }
  host.library.cancelLaunch(cancelled)
  precondition(host.library.preparing == nil && host.library.launchAfterJIT == nil)
  precondition(host.library.startingJIT == nil && host.library.cloudRetry == nil)
  host.play(entry)
  host.library.cancelLaunch(cancelled)
  precondition(host.library.preparing?.id == entry.id)
  try await Task.sleep(for: .milliseconds(250))
  precondition(host.launches == 2, "a cancelled request must not start the same game again")
  host.library.preparing = nil; host.library.current = UUID()
  host.play(entry); precondition(host.library.preparing == nil)
 }
}
''')

    def test_jit_preparation_uses_the_pending_library_launch(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        tail = source.split('jitCoordinator.prepareOfflineMemory(completion: completion)', 1)
        start = tail[0].rindex('        if ')
        selection = source[start:source.index('    /// Start a waiting game', start)]
        self.run_swift('''import Foundation
struct Library { var launchAfterJIT: (() -> Void)? }
final class Coordinator {
    var prepared = [String]()
    func prepareOfflineMemory(completion: () -> Void) { prepared.append("both") }
    func prepareWindowsMemory(completion: () -> Void) { prepared.append("windows") }
}
func prepare(library: Library, jitCoordinator: Coordinator) {
    let completion = {}
''' + selection + '''
@main struct Check { static func main() {
    let coordinator = Coordinator()
    prepare(library: Library(), jitCoordinator: coordinator)
    prepare(library: Library(launchAfterJIT: {}), jitCoordinator: coordinator)
    precondition(coordinator.prepared == ["both", "windows"])
}}''')

    def test_failed_jit_closes_only_its_own_loading_screen(self):
        source = (IOS / 'App/Adapters/Madeira/ContentView.swift').read_text()
        start = source.index('    private func launchAfterJITEnded(')
        callback = source[start:source.index('    /// Whether a launch may ask', start)]
        self.run_swift('''import Foundation
struct LibraryEntry { let id: UUID }
@MainActor final class LibraryModel {
 var startingJIT: UUID?, preparing: LibraryEntry?, current: UUID?, error: String?
 var launchAfterJIT: (() -> Void)?
}
@MainActor enum StikJITHelper { static var ready = false }
@MainActor final class IridiumMadeiraRuntime { static let shared = IridiumMadeiraRuntime(); var isBusy = false }
struct LogStore { func log(_ text: String) {} }
@MainActor final class Host {
 let library = LibraryModel(), logStore = LogStore()
 func finish(_ started: Bool) { launchAfterJITEnded(started: started) }
''' + callback + '''
}
@main struct Check {
 @MainActor static func main() {
  let host = Host(), request = UUID(), newer = UUID()
  var launches = 0
  host.library.startingJIT = request; host.library.preparing = .init(id: request)
  host.library.launchAfterJIT = { launches += 1 }; host.finish(false)
  precondition(host.library.preparing == nil && host.library.startingJIT == nil && launches == 0)
  host.library.startingJIT = request; host.library.preparing = .init(id: newer)
  host.library.launchAfterJIT = { launches += 1 }; host.finish(false)
  precondition(host.library.preparing?.id == newer && launches == 0)
  host.library.startingJIT = request; host.library.preparing = .init(id: request)
  host.library.launchAfterJIT = { launches += 1 }; StikJITHelper.ready = true; host.finish(true)
  precondition(launches == 1 && host.library.preparing?.id == request)
  host.finish(true); precondition(launches == 1)
  IridiumMadeiraRuntime.shared.isBusy = true
  host.library.startingJIT = request; host.library.preparing = .init(id: request)
  host.library.launchAfterJIT = { launches += 1 }; host.finish(true)
  precondition(launches == 1 && host.library.preparing == nil)

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
