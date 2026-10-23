"""Share host compiler modules and reuse only verified source-check results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = '.github/workflows/source-checks.yml'
_modules = None


def module_cache(sdk='macosx'):
    global _modules
    if _modules is None:
        _modules = tempfile.TemporaryDirectory(prefix='iridium-test-modules-')
    return str(Path(_modules.name) / sdk)


def environment_key():
    tools = {}
    commands = [('xcodebuild', '-version'), ('swiftc', '--version'),
                ('clang', '--version'), ('clang++', '--version'), ('git', '--version'),
                ('zstd', '--version')]
    commands += [('xcrun', '--sdk', sdk, '--show-sdk-build-version')
                 for sdk in ('macosx', 'iphoneos', 'iphonesimulator')]
    for command in commands:
        executable = shutil.which(command[0])
        if executable is None:
            raise ValueError('Missing host test tool: ' + command[0])
        tools[' '.join(command)] = [str(Path(executable).resolve()),
                                   subprocess.check_output(command, text=True, timeout=30).strip()]
    environment = {name: os.environ.get(name) for name in (
        'ImageVersion', 'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'SWIFT_EXEC',
        'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CPATH', 'LIBRARY_PATH', 'PYTHONPATH')}
    identity = [sys.version, str(sys.flags), str(Path(sys.executable).resolve()),
                platform.platform(), environment, tools]
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def api(repo, path):
    return json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{repo}/{path}'], text=True, stderr=subprocess.PIPE, timeout=60))


def verified_run(repo, revision, artifact):
    runs = api(repo, 'actions/workflows/source-checks.yml/runs?head_sha=' + revision + '&per_page=100')['workflow_runs']
    pending = False
    for run in runs:
        if (run.get('head_sha') != revision or run.get('path') != WORKFLOW
                or run.get('event') not in ('push', 'workflow_dispatch')
                or (run.get('head_repository') or {}).get('full_name') != repo):
            continue
        if run.get('status') != 'completed':
            pending = True
            continue
        if run.get('conclusion') != 'success':
            continue
        run_id = run['id']
        if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id <= 0:
            continue
        artifacts = api(repo, f'actions/runs/{run_id}/artifacts?name={artifact}&per_page=100')['artifacts']
        if sum(a.get('name') == artifact and a.get('expired') is False for a in artifacts) == 1:
            return run_id, pending
    return None, pending


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--record', action='store_true')
    mode.add_argument('--reuse', action='store_true')
    args = parser.parse_args()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch('[0-9a-f]{40}', revision) or revision != os.environ.get('GITHUB_SHA'):
        raise ValueError('Host test results require the exact checked-out Actions commit')
    artifact = 'source-checks-' + revision + '-' + environment_key()
    if args.record:
        record = ROOT / '.build/host-tests/result.json'
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(json.dumps({'revision': revision, 'artifact': artifact}) + '\n')
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('artifact=' + artifact + '\n')
        return
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo):
        raise ValueError('Invalid Actions repository')
    deadline = time.monotonic() + 20 * 60
    try:
        while True:
            run_id, pending = verified_run(repo, revision, artifact)
            if run_id:
                print(f'Reusing passed host tests: https://github.com/{repo}/actions/runs/{run_id}', flush=True)
                return
            if not pending or time.monotonic() >= deadline:
                break
            print('Waiting for source checks of this exact commit.', flush=True)
            time.sleep(20)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
        print('Source-check reuse unavailable.', flush=True)
    print('No passed source checks match this commit and host tools; running the tests.', flush=True)
    subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'ci', '-p', 'test_*.py'],
                   cwd=ROOT, check=True, timeout=20 * 60)


if __name__ == '__main__':
    main()
