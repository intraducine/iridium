#!/usr/bin/env python3
"""Focused source tests. Native calls are stubbed; this is NOT an iOS build/device test."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent

def run(args):
    subprocess.run([str(arg) for arg in args], check=True, timeout=45)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=HERE.parents[3])
    parser.add_argument('--group', choices=['all', 'files', 'input', 'lifecycle'], default='all')
    args = parser.parse_args()
    compiler = shutil.which('swiftc')
    if not compiler:
        raise SystemExit('swiftc is required; no checks were run.')
    root = args.source_root.resolve()
    ios = root / 'iridium/apps/ios'
    support = ios / 'MadeiraSupport'
    views = ios / 'Iridium/Views'
    core = root / 'iridium/packages/core/Sources/IridiumCore'
    with tempfile.TemporaryDirectory(prefix='iridium-review-tests-') as temp:
        temp = Path(temp)
        def build(name, sources, flags=()):
            binary=temp/name
            run([compiler, '-swift-version', '5', *flags, *sources, '-o', binary])
            return binary
        if args.group in ('all', 'files'):
            run([build('imports', [core/'ManagedGameFiles.swift', HERE/'ReviewManagedFilesCheck.swift'])])
            run([build('copies', [support/'MadeiraGamePreparation.swift', HERE/'ReviewGamePreparationCheck.swift'])])
        if args.group in ('all', 'input'):
            run([build('viewport', [views/'RuntimeViewportGeometry.swift', support/'MadeiraLaunchArguments.swift', HERE/'ReviewViewportFocusCheck.swift'])])
            hardware=(support/'MadeiraHardwareInput.swift').read_text()
            # Compile the actual input-entry functions. Platform device enumeration
            # below this delimiter is excluded and NOT validated by this harness.
            delimiter='    // Relative deltas and absolute UIKit locations must never drive the cursor together.'
            if hardware.count(delimiter)!=1:
                raise SystemExit('Hardware test source boundary changed; refusing a partial/incorrect extraction.')
            hardware=hardware.split(delimiter)[0]
            hardware='\n'.join(line for line in hardware.splitlines() if not line.startswith('import '))
            hardware+='\n    private static var held = Set<Int32>()\n    static var pointerCaptured = false\n}\n'
            under_test=temp/'HardwareUnderTest.swift'
            under_test.write_text('import Foundation\n'+hardware)
            run([build('keyboard', [support/'MadeiraKeys.swift', under_test, HERE/'ReviewKeyboardCheck.swift'])])
        if args.group in ('all', 'lifecycle'):
            original=(support/'MadeiraRuntimeAdapter.swift').read_text()
            under_test=temp/'RuntimeAdapterUnderTest.swift'
            under_test.write_text('\n'.join(line for line in original.splitlines()
                if line not in ('import UIKit', 'import MadeiraNative'))+'\n')
            binary=build('adapter', [HERE/'ReviewRuntimeStubs.swift', support/'MadeiraLaunchArguments.swift',
                under_test, HERE/'ReviewRuntimeCheck.swift'], ['-D','BUILTIN_STIKJIT'])
            cases=['prepare-failure','jit-failure','pool-failure','arena-failure','server-failure',
                   'server-died','wine-failure','builtin-start-failure','builtin-detach-failure',
                   'cancel-startup','success','duplicate-jit','process-exit','close-timeout']
            for case in cases:
                run([binary, case])
    print('PASS focused review regression checks. UIKit and real native-runtime behavior remain untested.', flush=True)

if __name__ == '__main__':
    main()
