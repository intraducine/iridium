#!/usr/bin/env python3
"""Build the production interface/stores with unavailable native runtimes, for Simulator only.

Run madeira-frontend.py prepare first. This never modifies the generated device
project, installs on a phone, or packages a distributable app.
"""
from pathlib import Path
import argparse
import json
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / '.build/iridium-ui-preview'


def prepare():
    source = ROOT / '.build/madeira-frontend/app'
    app = OUTPUT / 'app'
    app.mkdir(parents=True, exist_ok=True)
    # Only source and UI resources: no emulator binaries, Wine prefix or games.
    destination = app / 'Madeira'
    destination.mkdir(exist_ok=True)
    for stale in destination.rglob('*.swift'): stale.unlink()
    for file in (source / 'Madeira').rglob('*'):
        relative = file.relative_to(source / 'Madeira')
        if file.is_file() and (file.suffix in {'.swift', '.h', '.c', '.metal'} or
                              relative.parts[0] in {'Assets.xcassets', 'licenses', 'legal'} or
                              str(relative) in {'Info.plist', 'GameConfig.xml', 'cacert.pem', 'Madeira JIT.shortcut'}):
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    project = plistlib.load(open(source / 'Madeira.xcodeproj/project.pbxproj', 'rb'))
    objects = project['objects']
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v['name'] == 'Iridium')
    objects[project['rootObject']]['targets'] = [k for k, v in objects.items() if v is target]
    target['dependencies'] = []
    target['buildPhases'] = [k for k in target['buildPhases'] if objects[k]['isa'] in
                             {'PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXResourcesBuildPhase'}]
    for key in target['buildPhases']:
        phase = objects[key]
        def path(build): return objects[objects[build]['fileRef']].get('path', '')
        if phase['isa'] == 'PBXSourcesBuildPhase':
            phase['files'] = [b for b in phase['files'] if path(b).endswith(('.swift', '.metal')) or
                              path(b).startswith('SwiftSteam/') and path(b).endswith('.c')]
            group = next(v for v in objects.values() if v.get('isa') == 'PBXGroup' and v.get('path') == 'Madeira')
            objects['ABC000000000000000000001'] = dict(isa='PBXFileReference', lastKnownFileType='sourcecode.c.objc', path='PreviewNative.m', sourceTree='<group>')
            objects['ABC000000000000000000002'] = dict(isa='PBXBuildFile', fileRef='ABC000000000000000000001')
            group['children'].append('ABC000000000000000000001'); phase['files'].append('ABC000000000000000000002')
        elif phase['isa'] == 'PBXFrameworksBuildPhase':
            phase['files'] = [b for b in phase['files'] if objects[objects[b]['fileRef']].get('sourceTree') == 'SDKROOT' and 'MetalFX' not in path(b)]
        else:
            phase['files'] = [b for b in phase['files'] if path(b) in {'Assets.xcassets', 'licenses', 'legal', 'GameConfig.xml', 'cacert.pem', 'Madeira JIT.shortcut'}]
            if (OUTPUT / 'PreviewSamples/samples.json').is_file():
                objects['ABC000000000000000000003'] = dict(isa='PBXFileReference', lastKnownFileType='folder', path='../PreviewSamples', sourceTree='SOURCE_ROOT')
                objects['ABC000000000000000000004'] = dict(isa='PBXBuildFile', fileRef='ABC000000000000000000003')
                phase['files'].append('ABC000000000000000000004')
    for c in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[c]['buildSettings']
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='software.iridium.uipreview', MADEIRA_BUNDLE_IDENTIFIER='software.iridium.uipreview',
                        SUPPORTED_PLATFORMS='iphonesimulator', SDKROOT='iphonesimulator', CODE_SIGNING_ALLOWED='NO',
                        HEADER_SEARCH_PATHS=['$(inherited)', '$(SRCROOT)/Madeira'], LIBRARY_SEARCH_PATHS=['$(inherited)'],
                        OTHER_LDFLAGS=['$(inherited)'], SWIFT_ACTIVE_COMPILATION_CONDITIONS=['$(inherited)', 'IRIDIUM_PPSSPP', 'IRIDIUM_PHASE3', 'IRIDIUM_UX_PREVIEW'])
    project_dir = app / 'Madeira.xcodeproj'; project_dir.mkdir(exist_ok=True)
    (project_dir / 'project.pbxproj').write_bytes(plistlib.dumps(project))
    info = plistlib.load(open(destination / 'Info.plist', 'rb'))
    info.update(CFBundleDisplayName='Iridium', IridiumBuildVariant='Simulator')
    (destination / 'Info.plist').write_bytes(plistlib.dumps(info))
    (destination / 'IridiumApp.swift').write_text('''import SwiftUI
@main struct MadeiraApp: App {
    init() {
        UserDefaults.standard.set("new", forKey: FrontendChoice.key)
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
    }
    var body: some Scene { WindowGroup { IridiumPreviewRoot() } }
}
''')
    jit = destination / 'JITSetup.swift'
    text = jit.read_text()
    for signature in ['func enable(completion: @escaping (Result<Void, Error>) -> Void) {',
                      'func enableBuiltIn(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {']:
        assert text.count(signature) == 1
        text = text.replace(signature, signature + '\n        error = "JIT is only available on an iPhone or iPad."\n        completion(.failure(NSError(domain: "IridiumPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "JIT is only available on an iPhone or iPad."])))\n        return\n')
    jit.write_text(text)
    # Generated from the real bridging declarations, so C ABI signatures stay exact.
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    ast = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-fmodules', '-x', 'objective-c',
        '-target', 'arm64-apple-ios26.0-simulator', '-isysroot', sdk, '-Xclang', '-ast-dump=json', '-fsyntax-only',
        str(destination / 'Madeira-Bridging-Header.h')])
    declarations = json.loads(ast)['inner']
    lines = ['#if !TARGET_OS_SIMULATOR', '#error UI preview is Simulator-only', '#endif', '#import "Madeira-Bridging-Header.h"']
    # Foundation supplies TARGET_OS_SIMULATOR after importing the header.
    lines = ['#import "Madeira-Bridging-Header.h"', '#if !TARGET_OS_SIMULATOR', '#error UI preview is Simulator-only', '#endif']
    seen = set()
    for declaration in declarations:
        if declaration['kind'] == 'VarDecl' and declaration.get('name', '').startswith(('madeira_early_', 'ws_log_quiet', 'MadeiraDisplayModeChangedNotification')):
            value = '@"IridiumPreviewDisplayModeChanged"' if declaration['name'] == 'MadeiraDisplayModeChangedNotification' else '0'
            lines.append(f'{declaration["type"]["qualType"]} {declaration["name"]} = {value};')
            continue
        if declaration['kind'] != 'FunctionDecl': continue
        if declaration.get('storageClass') == 'static' or declaration.get('inline'): continue
        name = declaration['name']
        if not name.startswith(('jit_', 'jit26_', 'fex_', 'wine', 'winios_', 'madeira_', 'ir_')) or name in seen: continue
        seen.add(name)
        result = declaration['type']['qualType'].split('(')[0].rstrip()
        parameters = []
        for i, parameter in enumerate(x for x in declaration.get('inner', []) if x['kind'] == 'ParmVarDecl'):
            kind = parameter['type']['qualType']
            parameters.append(kind.replace('(*)', f'(*p{i})') if '(*)' in kind else kind + f' p{i}')
        value = '' if result == 'void' else 'return "";' if result == 'const char *' else 'return 0;'
        lines.append(f'{result} {name}({", ".join(parameters) or "void"}) {{ {value} }}')
    (destination / 'PreviewNative.m').write_text('\n'.join(lines))
    return project_dir


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    project = prepare()
    if not args.prepare_only:
        subprocess.run(['xcodebuild', '-project', str(project), '-scheme', 'Iridium', '-configuration', 'Debug',
            '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(OUTPUT / 'derived'),
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
