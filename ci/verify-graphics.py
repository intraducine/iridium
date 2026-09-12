"""Check ANGLE's generated compiler plan and finished iPhone frameworks."""
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True)


def check_plan(commands, directory, clang):
    count = 0
    for line in commands.splitlines():
        if any(part in line for part in ('third_party/dawn/', 'third_party/llvm-build/', 'third_party/libc++/', 'llvm-ar', 'ld64.lld')):
            raise ValueError('Unexpected graphics backend or compiler dependency')
        words = shlex.split(line)
        if not words or Path(words[0]).name not in {'clang', 'clang++'}:
            continue
        compiler = (directory / words[0]).resolve()
        if compiler.parent != clang.resolve().parent:
            raise ValueError('Graphics compiler does not belong to selected Xcode')
        if '-c' in words:
            if '-target' not in words or words[words.index('-target') + 1] != 'arm64-apple-ios18.0':
                raise ValueError('Unexpected graphics target')
            if '-w' in words:
                raise ValueError('Compiler warnings must remain visible')
            count += 1
    if not count:
        raise ValueError('No graphics compilation commands found')
    print(f'Verified {count} iPhone compiler commands; no Dawn or bundled Clang/libc++')


def check_binaries(directory):
    for name, symbol in (('libEGL', '_eglGetDisplay'), ('libGLESv2', '_glGetString')):
        framework = directory / (name + '.framework')
        binary = framework / name
        info = plistlib.loads((framework / 'Info.plist').read_bytes())
        if info.get('CFBundleExecutable') != name:
            raise ValueError('Framework executable does not match its plist')
        if output('xcrun', 'lipo', '-archs', str(binary)).strip() != 'arm64':
            raise ValueError('Framework must contain only arm64')
        build = output('xcrun', 'vtool', '-show-build', str(binary))
        if 'platform IOS\n' not in build or 'minos 18.0\n' not in build:
            raise ValueError('Framework has wrong platform or minimum OS')
        symbols = output('xcrun', 'nm', '-gjU', str(binary)).splitlines()
        if symbol not in symbols:
            raise ValueError('Framework is missing its public API')
        for line in output('xcrun', 'otool', '-L', str(binary)).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if not dependency.startswith(('/usr/lib/', '/System/Library/Frameworks/', '@rpath/libEGL.framework/', '@rpath/libGLESv2.framework/')):
                raise ValueError('Unexpected framework dependency: ' + dependency)
        signing = subprocess.run(['/usr/bin/codesign', '-d', str(framework)], capture_output=True, text=True)
        if signing.returncode == 0 or 'not signed at all' not in signing.stderr:
            raise ValueError('Framework must be unsigned')
        print(f'Verified {name}: arm64 iOS, minimum 18.0, public API and library dependencies')


if __name__ == '__main__':
    mode, path = sys.argv[1:]
    directory = Path(path).resolve()
    if mode == 'plan':
        check_plan(output('ninja', '-C', str(directory), '-t', 'commands', 'libEGL', 'libGLESv2'),
                   directory, Path(output('xcrun', '--find', 'clang').strip()))
    elif mode == 'binaries':
        check_binaries(directory)
    else:
        raise SystemExit('Usage: verify-graphics.py plan|binaries output-directory')
