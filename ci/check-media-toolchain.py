#!/usr/bin/env python3
"""Compile and link small probes with Cerbero's actual target and host flags."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def probe(config, directory, label):
    env = config.env
    source = directory / (label + '.cpp')
    source.write_text('#include <vector>\n#include <string>\n#include <mutex>\n'
                      'int main() { std::vector<std::string> v{"ok"}; '
                      'std::mutex m; std::lock_guard<std::mutex> lock(m); '
                      'return v.front().size() != 2; }\n')
    for standard in ('c++14', 'c++17', 'c++20'):
        output = directory / (label + '-' + standard)
        command = (shlex.split(env['CXX']) + shlex.split(env['CXXFLAGS']) +
                   ['-std=' + standard, '-Werror', str(source), '-o', str(output)] +
                   shlex.split(env['LDFLAGS']))
        subprocess.run(command, env=env, check=True)
        print(f'PASS {label} {standard}: compile and link', flush=True)
    if label == 'host':
        subprocess.run([str(output)], check=True)
    else:
        subprocess.run(['xcrun', 'lipo', '-verify_arch', 'arm64', str(output)], check=True)
        subprocess.run(['xcrun', 'vtool', '-show-build', str(output)], check=True)


def check(source, config_file):
    version = subprocess.check_output(['xcodebuild', '-version'], text=True)
    if not version.startswith('Xcode 27'):
        raise ValueError('This workflow requires Xcode 27; check DEVELOPER_DIR')
    print(version.strip(), flush=True)
    os.environ['CERBERO_UNINSTALLED'] = '1'
    sys.path.insert(0, str(source))
    from cerbero.config import Config
    config = Config()
    config.load([str(source / 'config/cross-ios-arm64.cbc'), str(config_file)])
    if config.target_platform != 'ios' or config.target_arch != 'arm64':
        raise ValueError('Expected iPhone ARM64 configuration')
    print('Resolved iOS minimum:', config.ios_min_version, flush=True)
    print('Resolved iPhone C++ flags:', config.env['CXXFLAGS'], flush=True)
    print('Resolved host C++ flags:', config.build_tools_config.env['CXXFLAGS'], flush=True)
    with tempfile.TemporaryDirectory(prefix='iridium-compiler-check-') as temp:
        failures = []
        for label, target in [('host', config.build_tools_config), ('iphone', config)]:
            try:
                probe(target, Path(temp), label)
            except subprocess.CalledProcessError:
                failures.append(label)
        if failures:
            raise SystemExit('Compiler preflight failed: ' + ', '.join(failures))


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
