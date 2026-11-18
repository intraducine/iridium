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
DOCS_ONLY = frozenset((b'README.md', b'docs/actions-ipa.md', b'docs/console-engines.md',
                       b'docs/runtime-integration.md'))
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


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, timeout=30)


def pr_head(revision, environ):
    base, head = environ.get('PR_BASE', ''), environ.get('PR_HEAD', '')
    if not all(re.fullmatch('[0-9a-f]{40}', sha) for sha in (base, head)):
        return None
    parents = git('rev-list', '--parents', '-n1', revision).decode().split()
    return head if parents == [revision, base, head] else None


def docs_only(revision, environ):
    if environ.get('GITHUB_EVENT_NAME') != 'pull_request':
        return False
    try:
        if pr_head(revision, environ) is None:
            return False
        changes = git('diff', '--raw', '-z', '--no-renames', '--no-ext-diff',
                      environ['PR_BASE'], revision).split(b'\0')
        if len(changes) <= 1 or len(changes) % 2 == 0 or changes[-1]:
            return False
        return all(
            header.startswith(b':100644 100644 ') and header.endswith(b' M') and path in DOCS_ONLY
            for header, path in zip(changes[:-1:2], changes[1:-1:2], strict=True)
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        return False


def api(repo, path):
    return json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{repo}/{path}'], text=True, stderr=subprocess.PIPE, timeout=60))


def verified_run(repo, revision, artifact):
    runs = api(repo, 'actions/workflows/source-checks.yml/runs?head_sha=' + revision + '&per_page=100')['workflow_runs']
    pending = False
    for run in runs:
        if (run.get('head_sha') != revision or run.get('path') != WORKFLOW
                or run.get('event') not in ('push', 'workflow_dispatch', 'pull_request')
                or (run.get('head_repository') or {}).get('full_name') != repo):
            continue
        if run.get('status') != 'completed':
            # A PR can be testing a different merge tree or selecting docs only.
            pending |= run.get('event') != 'pull_request'
            continue
        if run.get('conclusion') != 'success':
            continue
        run_id = run['id']
        if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id <= 0:
            continue
        attempt = run.get('run_attempt')
        if type(attempt) is not int or attempt < 1:
            continue
        name = f'{artifact}-{attempt}'
        artifacts = api(repo, f'actions/runs/{run_id}/artifacts?name={name}&per_page=100')['artifacts']
        if sum(a.get('name') == name and a.get('expired') is False for a in artifacts) == 1:
            return run_id, pending
    return None, pending


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--classify', action='store_true')
    mode.add_argument('--record', action='store_true')
    mode.add_argument('--reuse', action='store_true')
    args = parser.parse_args()
    revision = git('rev-parse', 'HEAD').decode().strip()
    exact = re.fullmatch('[0-9a-f]{40}', revision) and revision == os.environ.get('GITHUB_SHA')
    if args.classify:
        skip = bool(exact and docs_only(revision, os.environ))
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'docs_only={str(skip).lower()}\n')
        print('Guide edits only.' if skip else 'Run the full host suite.', flush=True)
        return
    if not exact:
        raise ValueError('Host test results require the exact checked-out Actions commit')
    tree = git('rev-parse', 'HEAD^{tree}').decode().strip()
    if not re.fullmatch('[0-9a-f]{40}', tree):
        raise ValueError('Invalid host test source tree')
    if args.record and os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
        head = pr_head(revision, os.environ)
        if head is None:
            print('PR merge parents differ. No reusable host result.', flush=True)
            return
    else:
        head = revision
    artifact = f'host-tests-v2-{head}-{tree}-{environment_key()}'
    if args.record:
        attempt = os.environ['GITHUB_RUN_ATTEMPT']
        if not re.fullmatch('[1-9][0-9]*', attempt):
            raise ValueError('Invalid source-check attempt')
        artifact += '-' + attempt
        record = ROOT / '.build/host-tests/result.json'
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(json.dumps({'revision': revision, 'tree': tree, 'artifact': artifact}) + '\n')
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
