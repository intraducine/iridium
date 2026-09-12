#!/usr/bin/env python3
"""Rebuild modified GMP source and link it into a separate unsigned test app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MARKER = "Iridium GMP source relink verification"


def modify(source):
    signature = "mpn_add_n (mp_ptr rp, mp_srcptr up, mp_srcptr vp, mp_size_t n)\n{"
    if source.count(signature) != 2:
        raise ValueError("Unexpected GMP source; review the test patch")
    return source.replace(signature, signature + '\n  static const volatile char proof[] = "' + MARKER + '";\n  (void) proof[0];')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / '.build/corresponding-source/gmp.source-archive')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    pin = next(x for x in json.loads((ROOT / 'ci/runtime-inputs.json').read_text()) if x['name'] == 'gmp')
    if digest(args.source) != pin['sha256']:
        raise ValueError('GMP source checksum mismatch')
    work = Path(tempfile.mkdtemp(prefix='iridium-lgpl-relink-'))
    print(f'Relink test logs: {work}', flush=True)
    with tarfile.open(args.source) as archive:
        archive.extractall(work, filter='data')
    source = work / 'gmp-6.3.0'
    file = source / 'mpn/generic/add_n.c'
    file.write_text(modify(file.read_text()))
    def xcrun(*arguments):
        return subprocess.check_output(['xcrun', *arguments], text=True).strip()
    sdk = xcrun('--sdk', 'iphoneos', '--show-sdk-path')
    clang = xcrun('-f', 'clang')
    env = os.environ.copy()
    env.update(CC=f'{clang} -arch arm64 -isysroot {sdk} -miphoneos-version-min=17.0',
               CC_FOR_BUILD=f'{clang} -isysroot {xcrun("--sdk", "macosx", "--show-sdk-path")}',
               CFLAGS='-O2', AR=xcrun('-f', 'ar'), RANLIB=xcrun('-f', 'ranlib'))
    with (work / 'build.log').open('w') as log:
        subprocess.run(['./configure', '--host=aarch64-apple-darwin', '--enable-static',
                        '--disable-shared', '--disable-assembly', '--with-pic'],
                       cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', '-j2'], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    replacement = source / '.libs/libgmp.a'
    if MARKER.encode() not in replacement.read_bytes():
        raise ValueError('Modified GMP code was not compiled')
    report = {'source_sha256': digest(args.source), 'modified_library_sha256': digest(replacement),
              'modified_source_compiled': True, 'full_app_relinked': False}
    if not args.build_only:
        original = ROOT / 'testrepos/Madeira/app/Madeira/libgmp.a'
        backup = work / 'original-libgmp.a'
        shutil.copy2(original, backup)
        report['original_library_sha256'] = digest(backup)
        try:
            shutil.copy2(replacement, original)
            with (work / 'app.log').open('w') as log:
                subprocess.run(['xcodebuild', '-project', str(ROOT / 'iridium/apps/ios/IridiumStikJIT.xcodeproj'),
                                '-scheme', 'Iridium', '-configuration', 'Release',
                                '-destination', 'generic/platform=iOS', '-derivedDataPath', str(work / 'app'),
                                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
                                'DEVELOPMENT_TEAM=', 'EXPANDED_CODE_SIGN_IDENTITY=',
                                'PROVISIONING_PROFILE_SPECIFIER=', 'PROVISIONING_PROFILE=',
                                'LD_GENERATE_MAP_FILE=YES', 'build'], cwd=ROOT, stdout=log,
                               stderr=subprocess.STDOUT, check=True)
            binary = work / 'app/Build/Products/Release-iphoneos/Iridium.app/Frameworks/MadeiraNative.framework/MadeiraNative'
            if MARKER.encode() not in binary.read_bytes():
                raise ValueError('Modified library code did not reach the app')
            report.update(full_app_relinked=True, modified_framework_sha256=digest(binary))
        finally:
            shutil.copy2(backup, original)
            if digest(original) != report['original_library_sha256']:
                raise ValueError('Original GMP restoration failed')
    output = ROOT / '.build/app-link-audit/lgpl-relink.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    print('Device execution and other LGPL libraries are not covered by this test.')


if __name__ == '__main__':
    main()
