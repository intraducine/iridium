#!/usr/bin/env python3
"""Reuse only a verified manual Linux artifact from trusted current history."""
from pathlib import Path
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPO = os.environ.get('GITHUB_REPOSITORY', 'nurtrino/Iridium-fork')
INPUTS = ('iridium-wine-ios', 'ci/prepare-linux-runtime.sh', 'ci/collect-debian-sources.py')


def producer_revision_is_ancestor(root, revision):
    current = subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    comparison = json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{REPO}/compare/{revision}...{current}'], text=True))
    return comparison.get('merge_base_commit', {}).get('sha') == revision


def validate_run(run, jobs, revision, branch="main", allow_other_branch=False):
    branch_ok = run.get('head_branch') in ('main', branch) or allow_other_branch
    if (run.get('event') != 'workflow_dispatch' or not branch_ok
        or run.get('head_sha') != revision
        or run.get('path') != '.github/workflows/build-unsigned-ipa.yml'
        or run.get('head_repository', {}).get('full_name') != REPO):
        raise ValueError('Linux artifact must come from this repository manual workflow on main, this branch, or merged current history')
    if not any(j.get('name') == 'linux-userland' and j.get('conclusion') == 'success' for j in jobs):
        raise ValueError('Linux producer job did not succeed')


def verify(root, run_id):
    revision = (root / '.build/linux-transfer/source-revision.txt').read_text().strip()
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid Linux source revision')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
    if run_id:
        if not re.fullmatch('[0-9]{1,20}', run_id):
            raise ValueError('Invalid producer run ID')
        def api(suffix):
            return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPO + '/actions/runs/' + run_id + suffix], text=True))
        branch = os.environ.get('GITHUB_REF_NAME') or git('branch', '--show-current')
        run = api('')
        jobs = api('/jobs?per_page=100')['jobs']
        other_branch = run.get('head_branch') not in ('main', branch)
        validate_run(run, jobs, revision, branch, allow_other_branch=other_branch)
        if other_branch and not producer_revision_is_ancestor(root, revision):
            raise ValueError('Linux producer revision is not an ancestor of the current build')
        subprocess.run(['git', '-C', str(root), 'fetch', '--depth=1', 'origin', revision], check=True)
        for path in INPUTS:
            if git('rev-parse', revision + ':' + path) != git('rev-parse', 'HEAD:' + path):
                raise ValueError('Linux source input changed: ' + path)
    elif revision != git('rev-parse', 'HEAD'):
        raise ValueError('Linux userland came from a different source revision')
    subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=root / '.build/linux-transfer', check=True)
    print('Verified Linux producer source and archive checksums.')


if __name__ == '__main__':
    verify(ROOT, os.environ.get('LINUX_RUNTIME_RUN_ID', ''))
