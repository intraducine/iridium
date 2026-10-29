"""Production registry/store checks; core execution is an explicit build check."""
from host_tests import module_cache
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sameboy_bootroms as boots

ROOT = Path(__file__).resolve().parents[1]


class SameBoyBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.core = self.root / 'core'
        (self.core / 'BootROMs').mkdir(parents=True)
        for name in ('Makefile', 'version.mk', 'BootROMs/original.asm'):
            (self.core / name).write_text('fixture source\n')
        self.manifest = self.root / 'boots.json'
        self.record = {'revision': boots.REVISION, 'rgbdsRevision': boots.RGBDS_REVISION,
                       'rgbdsVersion': boots.RGBDS_VERSION, 'sourceSHA256': boots.source_hashes(self.core),
                       'bootROMs': {name: {'hex': [bytes(size).hex()],
                                          'sha256': hashlib.sha256(bytes(size)).hexdigest()}
                                   for name, size in boots.MODELS.items()}}
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps(self.record))

    def test_all_boot_data_and_source_hashes_are_verified(self):
        result = boots.read_bootroms(self.core, self.manifest)
        self.assertEqual({name: len(data) for name, data in result.items()}, boots.MODELS)
        (self.core / 'BootROMs/original.asm').write_text('changed source\n')
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)

    def test_corrupt_missing_and_wrong_size_boots_are_rejected(self):
        self.record['bootROMs']['dmg']['hex'] = ['ff' * 256]
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        self.record['bootROMs']['dmg'] = {'hex': ['00'], 'sha256': boots.digest(b'\0')}
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        del self.record['bootROMs']['dmg']
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)

    def test_source_symlinks_and_invented_provenance_are_rejected(self):
        self.record['revision'] = '0' * 40
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        source = self.core / 'BootROMs/original.asm'
        source.unlink(); source.symlink_to(self.core / 'Makefile')
        with self.assertRaises(ValueError): boots.source_hashes(self.core)

    def test_regeneration_does_not_overwrite_before_running_tools(self):
        with patch.object(boots.subprocess, 'check_output') as command:
            with self.assertRaises(ValueError):
                boots.regenerate(self.core, self.root / 'tools', self.manifest)
        command.assert_not_called()

    def test_component_reuse_rejects_recipe_source_archive_and_namespace_changes(self):
        spec = importlib.util.spec_from_file_location('core_builder', ROOT / 'ci/build-sameboy.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        folder = self.root / 'output'; folder.mkdir()
        archive = folder / 'libIridiumSameBoy.a'; archive.write_bytes(b'archive')
        namespace = folder / 'SameBoyNamespace.h'; namespace.write_bytes(b'namespace')
        record = {'revision': boots.REVISION, 'buildInputSHA256': {'recipe': 'original'},
                  'archiveSHA256': boots.digest(archive.read_bytes()), 'namespaceSHA256': boots.digest(namespace.read_bytes())}
        manifest = folder / 'source-manifest.json'; manifest.write_text(json.dumps(record))
        with patch.object(builder, 'build_input_hashes', return_value={'recipe': 'original'}):
            self.assertEqual(builder.verify_component(folder), record)
            for file in (archive, namespace):
                old = file.read_bytes(); file.write_bytes(b'changed')
                with self.assertRaises(ValueError): builder.verify_component(folder)
                file.write_bytes(old)
        with patch.object(builder, 'build_input_hashes', return_value={'recipe': 'changed'}):
            with self.assertRaises(ValueError): builder.verify_component(folder)
        record['revision'] = '0' * 40; manifest.write_text(json.dumps(record))
        with patch.object(builder, 'build_input_hashes', return_value={'recipe': 'original'}):
            with self.assertRaises(ValueError): builder.verify_component(folder)


class MultiRuntimeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for library launch routing')
    def test_play_routes_advanced_engines_to_owned_jit_without_extra_confirmation(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryView.swift').read_text()
        launch = source[source.index('    private func launch(_ game:'):source.index('    private func options(_ game:')]
        repair = source[source.index('    private func steamRepairID('):source.index('    private func actions(')]
        marker = '.onChange(of: jitState.enabled) { _, enabled in'
        start = source.index(marker) + len(marker)
        continuation = source[start:source.index('\n            }', start)]
        fixture = r'''import Foundation
@MainActor enum IridiumMenuSounds {
    enum Cue { case invoke }
    static var selections = 0
    static func play(_ cue: Cue) { selections += 1 }
}
struct LibraryEntry { let id = UUID(); var steamAppID: Int? = nil }
struct IridiumGame {
    var windows: LibraryEntry?
    var console: IridiumConsoleGame?
    init(console: IridiumConsoleGame) { self.console = console }
    init(windows: LibraryEntry) { self.windows = windows }
    var id: UUID { console?.id ?? windows!.id }
}
@MainActor final class Session {
    var busy = false
    func validateLaunchAdmission() throws { if busy { throw IridiumRuntimeError.busy } }
}
@MainActor final class Library { var error: String? }
@MainActor final class JITState { var enabled = false; var showSetup = false }
@MainActor final class Steam {
    struct Download { enum State { case paused, failed(String), queued, active }; var state: State }
    var downloads: [Int: Download] = [:], installed: [Int] = [], repaired: [Int] = []
    var error: String?
    func install(_ id: Int) { installed.append(id) }
    func repair(_ id: Int) { repaired.append(id) }
}
@MainActor final class SteamGames {
    struct Game { let id: Int; let installed: Bool }
    var games: [Game] = []
}
@MainActor var nativeStarts: [UUID] = []
@MainActor struct IridiumConsoleDriver {
    init(game: IridiumConsoleGame) throws {}
    func launch(gameID: UUID) throws { nativeStarts.append(gameID) }
}
@MainActor struct IridiumWindowsDriver {
    let start: (LibraryEntry) -> Void
    func launch(gameID: UUID) throws { start(LibraryEntry()) }
}
@MainActor final class Host {
    let consoleSession = Session(), library = Library(), jitState = JITState(), jit = JITState()
    let steam = Steam(), steamGames = SteamGames()
    var lastLaunchNeedsSupport = false, pendingSupportGame: IridiumConsoleGame?
    var enables = 0, windows = 0
    func enableJIT() { enables += 1 }
    func play(_ game: LibraryEntry) { windows += 1 }
LAUNCH
STEAM_REPAIR
    func start(_ game: IridiumConsoleGame) { launch(IridiumGame(console: game)) }
    func start(_ entry: LibraryEntry) { launch(IridiumGame(windows: entry)) }
    func enabledChanged(_ enabled: Bool) {
CONTINUATION
    }
}
@main struct Check {
    @MainActor static func main() {
        for (platform, runtime) in [(IridiumPlatform.wii, "dolphin"), (.gameCube, "dolphin"),
                                    (.psp, "ppsspp"), (.nintendo3DS, "azahar"),
                                    (.playStation2, "play"), (.dreamcast, "flycast")] {
            for enabled in [false, true] {
                let host = Host(); host.jitState.enabled = enabled
                let game = IridiumConsoleGame(id: UUID(), title: "Fixture", platform: platform,
                    runtimeID: runtime, fileExtension: "iso", importedAt: Date())
                let count = nativeStarts.count, selections = IridiumMenuSounds.selections
                host.start(game)
                precondition(nativeStarts.count == count + 1 && nativeStarts.last == game.id)
                precondition(host.enables == 0 && host.pendingSupportGame == nil && host.library.error == nil)
                host.enabledChanged(true); precondition(nativeStarts.count == count + 1)
                precondition(IridiumMenuSounds.selections == selections + 1)
            }
        }
        let blocked = Host(); blocked.consoleSession.busy = true
        let game = IridiumConsoleGame(id: UUID(), title: "Fixture", platform: .wii,
            runtimeID: "dolphin", fileExtension: "iso", importedAt: Date())
        let count = nativeStarts.count; blocked.start(game)
        precondition(blocked.library.error != nil && blocked.enables == 0 && nativeStarts.count == count)
        let missing = Host()
        missing.lastLaunchNeedsSupport = true
        missing.start(LibraryEntry(steamAppID: 220))
        precondition(missing.steam.repaired == [220] && missing.windows == 0 && missing.enables == 0 && !missing.lastLaunchNeedsSupport)
        let paused = Host()
        paused.steam.downloads[220] = Steam.Download(state: .paused)
        paused.start(LibraryEntry(steamAppID: 220))
        precondition(paused.steam.installed == [220] && paused.windows == 0 && paused.enables == 0)
        print("PASS shipping Play: all advanced engines own JIT without duplicate launches; busy admission retained")
    }
}
'''.replace('LAUNCH', launch).replace('CONTINUATION', continuation).replace('STEAM_REPAIR', repair)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'check.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['swiftc', '-parse-as-library', '-D', 'IRIDIUM_PPSSPP', '-D', 'IRIDIUM_PHASE3',
                            str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'), str(unit), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_live_target_includes_core_sources_and_guards(self):
        spec = importlib.util.spec_from_file_location('runtime_overlay', ROOT / 'ci/madeira-frontend.py')
        overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(overlay)
        upstream = ROOT / 'ci/fixtures/madeira-build43/app/Madeira'
        if not upstream.is_dir():
            self.skipTest('Pinned Madeira source not initialized')
        source = (upstream / 'ContentView.swift').read_text()
        result = overlay.overlay('ContentView.swift', source)
        self.assertEqual(result.count('guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }'), 4)
        self.assertIn('guard !IridiumConsoleSession.shared.isActive, TouchControlsModel.shared.iridiumSettingsContext == nil else { return nil }', result)
        # Upstream UI names no longer control maintained admission guards.
        self.assertEqual(result, overlay.overlay('ContentView.swift',
            source.replace('private func startLibraryEntry(', 'private func renamedEntry(')))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for runtime model execution')
    def test_runtime_model_and_store(self):
        source = ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'
        fixture = ROOT / 'iridium/apps/ios/RuntimeTests/main.swift'
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / 'runtime-test'
            # Both shipping configurations execute the same production model:
            # PSP records must survive an installation without that component.
            for flags in ([], ['-D', 'IRIDIUM_PPSSPP'], ['-D', 'IRIDIUM_PPSSPP', '-D', 'IRIDIUM_PHASE3']):
                subprocess.run(['swiftc', *flags, str(source), str(fixture), '-o', str(executable)], check=True)
                subprocess.run([str(executable)], check=True, timeout=30)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for lifecycle checks')
    def test_console_launch_guards_execute_with_stopped_wine_flags(self):
        session = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        admission = session[session.index('    func validateLaunchAdmission() throws {'):session.index('    func start(_ game:')]
        start = session.index('            try validateLaunchAdmission()')
        end = session.index('            lock.lock(); intent =', start)
        # Execute the shipping preflight/lease acquisition, with controlled
        # process liveness endpoints. This is not a Wine teardown simulation.
        guards = session[start:end]
        fixture = r'''
import Foundation
var wineRunning: Int32 = 0, serverRunning: Int32 = 0
enum LibraryError: Error { case message(String) }
final class IridiumImportCoordinator {
    static let shared = IridiumImportCoordinator()
    var blocksLaunch = false
    var launchMessage = "Import in progress"
}
func wine_process_is_running() -> Int32 { wineRunning }
func wineserver_is_running() -> Int32 { serverRunning }
final class JITCoordinator {
    static let shared = JITCoordinator()
    var busy = false, consoleMemoryRequiresRestart = false
}
final class LibraryModel {
    static let shared = LibraryModel()
    static var sessionsThisRun = 0
    var current: UUID?
    var launching = false
}
final class TouchControlsModel {
    static let shared = TouchControlsModel()
    var iridiumSettingsContext: UUID?
}
final class Preflight {
    enum Phase { case idle, restartRequired }
    var phase = Phase.idle
    var dolphinMaintenance = false
    var ownership = IridiumRuntimeOwnership()
ADMISSION
    func acquire(_ game: IridiumConsoleGame) throws -> IridiumRuntimeLease {
GUARDS
        return owner
    }
}
let game = IridiumConsoleGame(id: UUID(), title: "Fixture", platform: .psp,
    runtimeID: "ppsspp", fileExtension: "elf", importedAt: Date())
let preflight = Preflight()
// Prompt-time admission never claims a lease; confirmation must recheck it.
try preflight.validateLaunchAdmission()
precondition(preflight.ownership.lease == nil)
IridiumImportCoordinator.shared.blocksLaunch = true
do { try preflight.validateLaunchAdmission(); fatalError("Storage reservation must block launch") }
catch LibraryError.message { }
IridiumImportCoordinator.shared.blocksLaunch = false

func rejects(_ expected: IridiumRuntimeError) {
    do { _ = try preflight.acquire(game); fatalError("Unexpected launch") }
    catch let actual as IridiumRuntimeError { precondition(String(describing: actual) == String(describing: expected)) }
    catch { fatalError("Unexpected error") }
}
let first = try preflight.acquire(game)
rejects(.busy)
preflight.ownership.release(first)
preflight.dolphinMaintenance = true; rejects(.busy); preflight.dolphinMaintenance = false
JITCoordinator.shared.busy = true; rejects(.busy); JITCoordinator.shared.busy = false
JITCoordinator.shared.consoleMemoryRequiresRestart = true; rejects(.restartRequired)
JITCoordinator.shared.consoleMemoryRequiresRestart = false
LibraryModel.shared.current = UUID(); rejects(.busy); LibraryModel.shared.current = nil
LibraryModel.shared.launching = true; rejects(.busy); LibraryModel.shared.launching = false
TouchControlsModel.shared.iridiumSettingsContext = UUID(); rejects(.busy)
TouchControlsModel.shared.iridiumSettingsContext = nil
wineRunning = 1; rejects(.busy); wineRunning = 0
serverRunning = 1; rejects(.busy); serverRunning = 0
// Zero liveness flags alone cannot authorize a post-Windows console launch.
LibraryModel.sessionsThisRun = 1; rejects(.restartRequired)
LibraryModel.sessionsThisRun = 0 // Fixture models a different, fresh process.
let second = try preflight.acquire(game)
preflight.ownership.release(first) // Stale stop cannot release the newer owner.
rejects(.busy)
preflight.ownership.release(second)
let third = try preflight.acquire(game)
preflight.ownership.release(third)
preflight.phase = .restartRequired; rejects(.restartRequired)
preflight.phase = .idle
let last = try preflight.acquire(game)
preflight.ownership.release(last, restart: true); rejects(.restartRequired)
print("PASS shipping preflight: active Windows/launch/server/owner, prior Windows despite zero flags, repeated clean console leases, stale stop, restart state")
'''.replace('GUARDS', guards).replace('ADMISSION', admission)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); source = folder / 'main.swift'; source.write_text(fixture)
            binary = folder / 'checks'
            subprocess.run(['swiftc', '-D', 'IRIDIUM_PPSSPP', '-module-cache-path', module_cache('macosx'),
                            str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'),
                            str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)

    def test_psp_session_has_fixed_component_and_drained_ownership(self):
        # Source guards supplement, rather than replace, the executed Swift
        # model and explicit native/device tests.
        session = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        self.assertIn('Bundle.main.privateFrameworksURL', session)
        self.assertIn('appendingPathComponent("libIridiumPPSSPPNative.dylib")', session)
        self.assertIn('appendingPathComponent("PSP/PPSSPP", isDirectory: true)', session)
        self.assertIn('try store.validateROM(game)', session)
        self.assertIn('case IR_PSP_CLOSED: complete(owner)', session)
        self.assertIn('case IR_PSP_RESTART_REQUIRED: requireRestart(owner)', session)
        self.assertIn('ir_psp_request_stop()', session)
        self.assertNotIn('ir_psp_close', session)
        self.assertNotIn('dlclose', session)
        self.assertIn('guard runningGame != nil, backend == .sameBoy else { return }', session)
        self.assertIn('frame.width > 0 && frame.height > 0', session)
        self.assertIn('guard self.lease == owner, self.phase == .starting, self.requested == .play', session)

    def test_psp_frontend_routes_controls_and_runtime(self):
        frontend = ROOT / 'iridium/apps/ios/MadeiraFrontend'
        player = (frontend / 'IridiumConsolePlayer.swift').read_text()
        library = (frontend / 'IridiumRuntimeLibrary.swift').read_text()
        view = (frontend / 'IridiumLibraryView.swift').read_text()
        layout = (ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift').read_text()
        for label, icon, bit in [('Cross', 'xmark', 0), ('Circle', 'circle', 8),
                                 ('Square', 'square', 1), ('Triangle', 'triangle', 9)]:
            self.assertIn(f'add("{label}", "{icon}", bit: 1 << {bit},', layout)
        for label, bit in [('L', 10), ('R', 11), ('Start', 3), ('Select', 2)]:
            self.assertIn(f'add("{label}", bit: 1 << {bit},', layout)
        self.assertIn('session.setAnalog(x: Int16(x), y: Int16(y), keyboard: true)', player)
        self.assertIn('onChange(of: keyboardFocus)', player)
        self.assertIn('IridiumConsoleDriver(game: console)', view)
        self.assertNotIn('IridiumSameBoyDriver', view + library)
        self.assertIn('descriptor = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)', library)
        self.assertIn('IridiumRuntimeRegistry.compatible(with: .psp)', library)
        self.assertIn('IridiumConsoleSystem.all.flatMap(\\.extensions)', library)

    @unittest.skipUnless(os.environ.get('IRIDIUM_TEST_CORE') == '1',
                         'Native core execution is explicit; source CI must not trigger emulator builds')
    def test_actual_core_execution(self):
        subprocess.run(['python3', str(ROOT / 'ci/check-sameboy.py')], check=True, timeout=180)


if __name__ == '__main__':
    unittest.main()
