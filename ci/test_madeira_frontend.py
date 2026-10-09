"""One migration check: old paths, save conflicts, containment and retry."""
import pathlib
import hashlib
import json
import importlib.util
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import madeira_presentation

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('madeira_frontend', ROOT / 'ci/madeira-frontend.py')
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class FrontendImportTests(unittest.TestCase):
    def test_compiler_identity_ignores_only_metal_mount(self):
        def identity(version, mount):
            def output(command, **kwargs):
                if 'metal' in command: return f'Metal {version}\nTarget: air64\nInstalledDir: {mount}'
                return 'fixed compiler version'
            with patch.object(BUILD.subprocess, 'check_output', side_effect=output):
                return BUILD.compiler_identity()
        self.assertEqual(identity('1', '/mount/one'), identity('1', '/mount/two'))
        self.assertNotEqual(identity('1', '/mount/one'), identity('2', '/mount/one'))

    def test_settings_copy_changes_only_notes(self):
        import re
        folder = ROOT / 'vendor/Madeira/app/Madeira'
        original = (folder / 'ConfigCatalog.generated.swift').read_text()
        changed = madeira_presentation.apply('ConfigCatalog.generated.swift', original)
        notes = r'note: "(?:[^"\\]|\\.)*"'
        self.assertEqual(re.sub(notes, '', original), re.sub(notes, '', changed))
        self.assertNotRegex(' '.join(re.findall(notes, changed)), r'\bml\d+\b|as before|previous bar')

    def test_source_package_requires_all_dependency_revisions(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            upstream = root / 'vendor/Madeira'
            dependencies = {'wine': 'wine-pin', 'FEX': 'fex-pin'}
            for name in dependencies: (upstream / name).mkdir(parents=True)
            (root / 'UPSTREAM-SOURCES.json').write_text(json.dumps({'frontend_runtime': {'dependencies': dependencies}}))
            revisions = {'vendor/Madeira': BUILD.REVISION, **{'vendor/Madeira/' + k: v for k, v in dependencies.items()}}
            record = root / 'SOURCE-REVISIONS.json'
            record.write_text(json.dumps(revisions))
            with patch.object(BUILD, 'ROOT', root), patch.object(BUILD, 'UPSTREAM', upstream):
                BUILD.verify_pin()
                revisions['vendor/Madeira/FEX'] = 'wrong-pin'
                record.write_text(json.dumps(revisions))
                with self.assertRaisesRegex(ValueError, 'FEX'): BUILD.verify_pin()

    def test_packaging_requires_mapped_source_with_matching_checksum(self):
        import hashlib
        import json
        spec = importlib.util.spec_from_file_location('frontend_prerequisites', ROOT / 'ci/check-ipa-prerequisites.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'ci').mkdir()
            for name in ('binary-release-blockers.json', 'binary-package-blockers.json'):
                (root / 'ci' / name).write_text('[]')
            with patch.object(module, 'required_for_profile', return_value={}):
                self.assertEqual(module.blockers(root, profile='madeira-frontend'), [])
                self.assertTrue(module.blockers(root, profile='madeira-frontend', package=True))
                out = root / '.build/ipa-output'
                out.mkdir(parents=True)
                archive = out / 'Iridium-corresponding-source.tar.gz'
                archive.write_bytes(b'source fixture')
                (out / 'SOURCE-SHA256SUMS').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name)
                (out / 'COMPONENT-MANIFEST.json').write_text(json.dumps({'binaries': [{'component': 'Wine'}],
                    'static_archives': ['libWine.a'], 'revisions': {'vendor/Madeira': BUILD.REVISION}}))
                self.assertEqual(module.blockers(root, profile='madeira-frontend', package=True), [])
                archive.write_bytes(b'changed')
                self.assertTrue(module.blockers(root, profile='madeira-frontend', package=True))

    def test_source_inventory_rejects_unknown_binary(self):
        spec = importlib.util.spec_from_file_location('frontend_collect', ROOT / 'ci/collect-madeira-source.py')
        collect = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(collect)
        for name, component in [('Iridium', 'Iridium, Madeira and SameBoy native libraries'),
                                ('arm64ec-windows/xtajit64.dll', 'FEX'),
                                ('i386-windows/winemetal.dll', 'DXMT'),
                                ('arm64ec-windows/dockhost.exe', 'Madeira Dock and LLVM-MinGW runtime'),
                                ('aarch64-windows/wow64win.dll', 'Wine and its bundled libraries')]:
            self.assertEqual(collect.binary_component(name), component)
        for name in ('unknown.dylib', 'Frameworks/Unknown.framework/Unknown', '../i386-windows/game.dll'):
            with self.assertRaises(ValueError): collect.binary_component(name)

    def test_bundle_rejects_empty_i386_farm_and_missing_wow64_modules(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            app, upstream = root / 'Iridium.app', root / 'upstream'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'IridiumMadeiraRevision': BUILD.REVISION, 'IridiumPPSSPPRevision': BUILD.PSP_REVISION}))
            component = app / 'Frameworks/ppsspp_libretro.dylib'
            component.parent.mkdir(); component.write_bytes(b'PSP component fixture')
            asset = app / 'PSP/PPSSPP/compat.ini'
            asset.parent.mkdir(parents=True); asset.write_bytes(b'PSP asset fixture')
            psp_output = root / 'psp-output'; psp_output.mkdir()
            (psp_output / 'component.json').write_text(json.dumps({
                'revision': BUILD.PSP_REVISION,
                'sha256': hashlib.sha256(component.read_bytes()).hexdigest(),
                'assetSHA256': {'compat.ini': hashlib.sha256(asset.read_bytes()).hexdigest()},
            }))
            for farm in ('arm64ec-windows', 'aarch64-windows', 'i386-windows'):
                for parent in (app, upstream / 'app/Madeira'):
                    (parent / farm).mkdir(parents=True)
                    (parent / farm / '.gitkeep').touch()
                    if farm != 'i386-windows': (parent / farm / 'ntdll.dll').write_bytes(b'binary')
            with patch.object(BUILD, 'UPSTREAM', upstream), patch.object(BUILD, 'PSP_OUTPUT', psp_output):
                with self.assertRaisesRegex(ValueError, 'i386-windows'):
                    BUILD.check_bundle(app)
                names = ('arm64ec-windows/xtajit64.dll', 'd3d12/libmetalirconverter.dylib',
                         'aarch64-windows/xtajit.dll', 'aarch64-windows/wow64.dll',
                         'aarch64-windows/wow64win.dll', 'i386-windows/ntdll.dll',
                         'i386-windows/d3d9.dll', 'i386-windows/winemetal.dll')
                for name in names:
                    path = app / name
                    path.parent.mkdir(exist_ok=True)
                    path.write_bytes(b'binary')
                    source = upstream / 'app/Madeira' / name
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_bytes(b'binary')
                BUILD.check_bundle(app)
                (app / 'aarch64-windows/xtajit.dll').write_bytes(b'')
                with self.assertRaisesRegex(ValueError, 'xtajit.dll'):
                    BUILD.check_bundle(app)
                (app / 'aarch64-windows/xtajit.dll').write_bytes(b'binary')
                original_component = component.read_bytes()
                component.write_bytes(b'changed PSP component')
                with self.assertRaisesRegex(ValueError, 'audited PSP component'):
                    BUILD.check_bundle(app)
                component.write_bytes(original_component)
                original_asset = asset.read_bytes()
                asset.unlink()
                with self.assertRaisesRegex(ValueError, 'PSP runtime asset'):
                    BUILD.check_bundle(app)
                asset.write_bytes(b'changed PSP asset')
                with self.assertRaisesRegex(ValueError, 'PSP runtime asset'):
                    BUILD.check_bundle(app)
                asset.write_bytes(original_asset)
                BUILD.check_bundle(app)

    def test_generated_psp_project_embeds_without_linking_and_preserves_settings(self):
        # Model plutil's parsed PBX graph; exercise project(), not source text.
        objects = {
            'target': {'isa': 'PBXNativeTarget', 'name': 'Madeira', 'productName': 'Madeira',
                       'productReference': 'product', 'buildPhases': ['sources', 'resources', 'frameworks'],
                       'buildConfigurationList': 'configurations'},
            'product': {'isa': 'PBXFileReference', 'path': 'Madeira.app'},
            'group': {'isa': 'PBXGroup', 'path': 'Madeira', 'children': ['existing-reference']},
            'sources': {'isa': 'PBXSourcesBuildPhase', 'files': ['existing-source']},
            'resources': {'isa': 'PBXResourcesBuildPhase', 'files': ['existing-resource']},
            'frameworks': {'isa': 'PBXFrameworksBuildPhase', 'files': ['existing-link']},
            'configurations': {'buildConfigurations': ['debug', 'release']},
            'debug': {'isa': 'XCBuildConfiguration', 'buildSettings': {
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) DEBUG',
                'HEADER_SEARCH_PATHS': ['$(inherited)', 'existing-include'],
                'OTHER_LDFLAGS': ['$(inherited)', '-lexisting']}},
            'release': {'isa': 'XCBuildConfiguration', 'buildSettings': {}},
        }
        with patch.object(BUILD.subprocess, 'check_output', return_value=plistlib.dumps({'objects': objects})):
            result = BUILD.project(pathlib.Path('/fixture/project.pbxproj'),
                                   ['IRPSPBridge.c', 'IridiumConsoleSession.swift'])['objects']
        target = result['target']
        self.assertEqual(target['name'], 'Iridium')
        self.assertEqual(result['product']['path'], 'Iridium.app')
        embeds = [result[key] for key in target['buildPhases']
                  if result[key]['isa'] == 'PBXCopyFilesBuildPhase']
        self.assertEqual(len(embeds), 1)
        embed = embeds[0]
        self.assertEqual(embed['dstSubfolderSpec'], 10)  # App's Frameworks directory.
        self.assertEqual(embed['dstPath'], '')
        self.assertEqual(embed['runOnlyForDeploymentPostprocessing'], 0)
        self.assertEqual(len(embed['files']), 1)
        component_ref = result[embed['files'][0]]['fileRef']
        component = result[component_ref]
        self.assertEqual(component['sourceTree'], 'SOURCE_ROOT')
        self.assertEqual(component['lastKnownFileType'], 'compiled.mach-o.dylib')
        self.assertEqual(component['path'], '../../ppsspp/$(PLATFORM_NAME)/ppsspp_libretro.dylib')
        for sdk in ('iphoneos', 'iphonesimulator'):
            resolved = (BUILD.OUTPUT / 'app' / component['path'].replace('$(PLATFORM_NAME)', sdk)).resolve()
            self.assertEqual(resolved, (BUILD.ROOT / '.build/ppsspp' / sdk / 'ppsspp_libretro.dylib').resolve())
        self.assertEqual(result['frameworks']['files'], ['existing-link'])
        self.assertIn(component_ref, result['group']['children'])
        resource_refs = [result[result[key]['fileRef']] for key in result['resources']['files']
                         if key != 'existing-resource']
        self.assertEqual(resource_refs, [{'isa': 'PBXFileReference', 'lastKnownFileType': 'folder',
                                         'path': 'PSP', 'sourceTree': '<group>'}])
        self.assertIn('existing-resource', result['resources']['files'])
        source_refs = [result[result[key]['fileRef']] for key in result['sources']['files']
                       if key != 'existing-source']
        self.assertEqual({item['path']: item['lastKnownFileType'] for item in source_refs},
                         {'IRPSPBridge.c': 'sourcecode.c.c', 'IridiumConsoleSession.swift': 'sourcecode.swift'})
        for configuration in ('debug', 'release'):
            settings = result[configuration]['buildSettings']
            self.assertIn('IRIDIUM_PPSSPP', settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
            self.assertIn('$(inherited)', settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
            self.assertIn('$(SRCROOT)/../../ppsspp/$(PLATFORM_NAME)/include', settings['HEADER_SEARCH_PATHS'])
            self.assertIn('-lIridiumSameBoy', settings['OTHER_LDFLAGS'])
            self.assertFalse(any('ppsspp' in flag.lower() for flag in settings['OTHER_LDFLAGS']))
        self.assertIn('DEBUG', result['debug']['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
        self.assertIn('existing-include', result['debug']['buildSettings']['HEADER_SEARCH_PATHS'])
        self.assertIn('-lexisting', result['debug']['buildSettings']['OTHER_LDFLAGS'])

    def test_generated_tree_refresh_is_repeatable_and_removes_only_stale_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder).resolve()
            source, destination = root / 'source', root / 'generated/PSP/PPSSPP'
            (source / 'flash0/font').mkdir(parents=True)
            (source / 'flash0/font/font.pgf').write_bytes(b'font')
            (source / 'compat.ini').write_bytes(b'first')
            outside = root / 'unrelated'; outside.mkdir()
            retained = outside / 'keep'; retained.write_bytes(b'preserve')
            BUILD.refresh_generated_tree(source, destination)
            (destination / 'stale.ini').write_bytes(b'stale')
            (destination / 'stale-link').symlink_to(outside, target_is_directory=True)
            (source / 'compat.ini').write_bytes(b'second')
            BUILD.refresh_generated_tree(source, destination)
            BUILD.refresh_generated_tree(source, destination)
            self.assertEqual((destination / 'compat.ini').read_bytes(), b'second')
            self.assertEqual((destination / 'flash0/font/font.pgf').read_bytes(), b'font')
            self.assertFalse((destination / 'stale.ini').exists())
            self.assertFalse((destination / 'stale-link').is_symlink())
            self.assertEqual(retained.read_bytes(), b'preserve')
            self.assertEqual((source / 'compat.ini').read_bytes(), b'second')

    def test_generated_tree_refresh_refuses_leaf_and_ancestor_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder).resolve()
            source, outside = root / 'source', root / 'outside'
            source.mkdir(); outside.mkdir()
            (source / 'replacement').write_bytes(b'new')
            retained = outside / 'keep'; retained.write_bytes(b'preserve')
            leaf = root / 'leaf'; leaf.symlink_to(outside, target_is_directory=True)
            ancestor = root / 'parent-link'; ancestor.symlink_to(outside, target_is_directory=True)
            dangling = root / 'dangling'; dangling.symlink_to(root / 'absent', target_is_directory=True)
            for destination in (leaf, ancestor / 'child', dangling):
                with self.subTest(destination=destination.name), self.assertRaisesRegex(ValueError, 'symbolic link'):
                    BUILD.refresh_generated_tree(source, destination)
            self.assertTrue(leaf.is_symlink())
            self.assertTrue(ancestor.is_symlink())
            self.assertTrue(dangling.is_symlink())
            self.assertEqual(retained.read_bytes(), b'preserve')
            ordinary_file = root / 'file'; ordinary_file.write_bytes(b'preserve file')
            with self.assertRaisesRegex(ValueError, 'not a directory'):
                BUILD.refresh_generated_tree(source, ordinary_file)
            self.assertEqual(ordinary_file.read_bytes(), b'preserve file')

    def test_i386_reuse_requires_matching_outputs_and_unexpired_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            upstream = pathlib.Path(folder)
            recipe = upstream / 'build/wine-i386/build.sh'
            recipe.parent.mkdir(parents=True)
            text = (ROOT / 'vendor/Madeira/build/wine-i386/build.sh').read_text()
            recipe.write_text(text)
            def build(*args, **kwargs):
                dll = upstream / 'app/Madeira/i386-windows/ntdll.dll'
                dll.parent.mkdir(parents=True, exist_ok=True)
                dll.write_bytes(b'built')
            with patch.object(BUILD, 'UPSTREAM', upstream), patch.object(BUILD, 'verify_pin'), \
                 patch.object(BUILD.subprocess, 'check_output', side_effect=lambda args, **kw: '/tool/Metal.xctoolchain/usr/bin/metal\n' if kw.get('text') else b'tool version'), \
                 patch.object(BUILD.subprocess, 'run', side_effect=build) as run, \
                 patch.object(BUILD.time, 'time', return_value=100) as now:
                BUILD.windows()
                BUILD.windows()
                self.assertEqual(run.call_count, 1)
                (upstream / 'app/Madeira/i386-windows/ntdll.dll').unlink()
                BUILD.windows()
                self.assertEqual(run.call_count, 2)
                now.return_value = 100 + 15 * 86400
                BUILD.windows()
                self.assertEqual(run.call_count, 3)
                recipe.write_text(text + '\n# changed recipe\n')
                BUILD.windows()
                self.assertEqual(run.call_count, 4)

    def test_presentation_keeps_upstream_runtime_and_save_actions(self):
        folder = ROOT / 'vendor/Madeira/app/Madeira'
        if not folder.exists(): self.skipTest('Initialize vendor/Madeira first')
        original = (folder / 'Library.swift').read_text()
        rendered = madeira_presentation.apply('Library.swift', original)
        # LibraryModel owns launches, files, saves and input ownership. Its code
        # must not change when reorganizing the pages that call it.
        self.assertEqual(original[:original.index('struct LibraryView: View')],
                         rendered[:rendered.index('struct LibraryView: View')])
        start = '    private func start() {'
        end = '    /// A Steam game without a chosen cover'
        self.assertEqual(madeira_presentation.between(original, start, end),
                         madeira_presentation.between(rendered, start, end))
        for name, boundary in [('JITSetup.swift', 'struct JITSettingsSection: View'),
                               ('SteamGames.swift', 'struct SteamGamesSection: View')]:
            text = (folder / name).read_text()
            changed = madeira_presentation.apply(name, text)
            self.assertEqual(text[:text.index(boundary)], changed[:changed.index(boundary)])
        for name in ['GamepadInput.swift', 'HardwareInput.swift', 'SteamCloud.swift', 'SteamInstall.swift', 'SavesAndShortcuts.swift']:
            text = (folder / name).read_text()
            self.assertEqual(text, madeira_presentation.apply(name, text), name)
        self.assertIn('if command == "play" { start() }', rendered)
        self.assertNotIn('if command == "accept" { start() }', rendered)
        self.assertIn('.confirmationDialog("Close this game?"', rendered)
        self.assertIn('height: min(bindsPage ? 650 : menuContentHeight', rendered)
        self.assertIn('action: { menuContentHeight = $0 }', rendered)
        # Native Escape dismissal must pop the submenu before closing its sheet.
        destinations = madeira_presentation.destination_pages({'Display': 'Text("Display")'})
        self.assertIn('.navigationBarBackButtonHidden()', destinations)
        self.assertIn('Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }', destinations)
        self.assertIn('.keyboardShortcut(.cancelAction)', destinations)
        # A changed upstream integration must fail rather than silently omit a page.
        with self.assertRaises(ValueError):
            madeira_presentation.apply('Library.swift', original.replace('.navigationTitle("Game details")', '.navigationTitle("Details")'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler is required')
    def test_import_preserves_originals_and_rejects_conflicts(self):
        source = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryImport.swift'
        with tempfile.TemporaryDirectory() as folder:
            script = pathlib.Path(folder) / 'main.swift'
            script.write_text(r'''
import Foundation
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func game(_ title: String, save: String) throws -> IridiumLibraryImport.Game {
    let id = UUID()
    let prefix = root.appendingPathComponent("MadeiraTestPrefixes/" + id.uuidString)
    let drive = prefix.appendingPathComponent("drive_c")
    try fm.createDirectory(at: drive.appendingPathComponent("IridiumGame/bin"), withIntermediateDirectories: true)
    try fm.createDirectory(at: drive.appendingPathComponent("IridiumGame/empty"), withIntermediateDirectories: true)
    try fm.createDirectory(at: drive.appendingPathComponent("users/madeira/saves"), withIntermediateDirectories: true)
    try Data("exe".utf8).write(to: drive.appendingPathComponent("IridiumGame/bin/game.exe"))
    try Data(save.utf8).write(to: drive.appendingPathComponent("users/madeira/saves/player.dat"))
    for name in ["user.reg", "system.reg"] { try Data("reg".utf8).write(to: prefix.appendingPathComponent(name)) }
    return .init(id: id, title: title, installPath: "/old/container/game", launchProfile: .init(executablePath: "/old/container/game/bin/game.exe", arguments: []))
}
let first = try game("First", save: "first")
let imported = try IridiumLibraryImport.transfer(first, documents: root)
assert(imported.executable == "IridiumGame/bin/game.exe")
assert(root.appendingPathComponent("wine").resolvingSymlinksInPath().lastPathComponent == "wine")
let second = try game("Second", save: "different")
let firstSave = try String(contentsOf: root.appendingPathComponent("wine/drive_c/users/madeira/saves/player.dat"), encoding: .utf8)
assert(firstSave == "first")
do { _ = try IridiumLibraryImport.transfer(second, documents: root); fatalError("save conflict was accepted") }
catch IridiumLibraryImport.Failure.conflictingSave { }
assert(!fm.fileExists(atPath: root.appendingPathComponent("wine/drive_c/Imported/" + second.id.uuidString).path))
let secondSave = root.appendingPathComponent("MadeiraTestPrefixes/" + second.id.uuidString + "/drive_c/users/madeira/saves/player.dat")
let saved = try String(contentsOf: secondSave, encoding: .utf8)
assert(saved == "different")
try Data("first".utf8).write(to: secondSave)
_ = try IridiumLibraryImport.transfer(second, documents: root)
_ = try IridiumLibraryImport.transfer(second, documents: root)
let original = root.appendingPathComponent("MadeiraTestPrefixes/" + second.id.uuidString + "/drive_c/IridiumGame/bin/game.exe")
assert(fm.fileExists(atPath: original.path))
assert(fm.fileExists(atPath: root.appendingPathComponent("wine/drive_c/Imported/" + second.id.uuidString + "/empty").path))
let third = try game("Linked", save: "first")
let user = root.appendingPathComponent("MadeiraTestPrefixes/" + third.id.uuidString + "/drive_c/users/madeira")
try fm.removeItem(at: user)
try fm.createSymbolicLink(at: user, withDestinationURL: root)
do { _ = try IridiumLibraryImport.transfer(third, documents: root); fatalError("unsafe save link was accepted") }
catch IridiumLibraryImport.Failure.outsideFolder { }
assert(IridiumLibraryImport.commandLine(["", "a b", "a\"b", "tail\\"]) == "\"\" \"a b\" \"a\\\"b\" \"tail\\\\\"")
print("Migration: old sandbox path, save conflict, idempotent retry and link containment passed.")
''')
            exe = pathlib.Path(folder) / 'check'
            subprocess.run(['swiftc', str(source), str(script), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_privacy_scans_public_sources_and_ignores_build_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            shutil.copy2(ROOT / 'check-public-source.py', root)
            (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/public-signing-fixtures.json', root / 'ci')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('.build/\n')
            (root / '.build').mkdir()
            key = b'-----BEGIN ' + b'PRIVATE KEY-----\nfixture'
            (root / '.build/generated').write_bytes(key)
            clean = subprocess.run(['python3', str(root / 'check-public-source.py')], capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
            # A source-only scan must still reject untracked signing material.
            (root / 'accidental-key').write_bytes(key)
            bad = subprocess.run(['python3', str(root / 'check-public-source.py')], capture_output=True, text=True)
            self.assertEqual(bad.returncode, 1)
            self.assertIn('accidental-key: private key', bad.stdout)
            (root / 'accidental-key').unlink()
            archive = root / 'vendor/Madeira/app/Madeira/libgnutls.a'
            archive.parent.mkdir(parents=True)
            archive.write_bytes(key)
            changed = subprocess.run(['python3', str(root / 'check-public-source.py')], capture_output=True, text=True)
            self.assertEqual(changed.returncode, 1)
            self.assertIn('libgnutls.a: private key', changed.stdout)


if __name__ == '__main__': unittest.main()
