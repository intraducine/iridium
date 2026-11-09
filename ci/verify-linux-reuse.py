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


def fetch_revision(root, revision):
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid producer source revision')
    # checkout deliberately does not persist credentials. Let gh supply the
    # step's GH_TOKEN without putting its value in argv, URLs, or git config.
    subprocess.run(['git', '-C', str(root), '-c', 'credential.helper=',
                    '-c', 'credential.https://github.com.helper=!gh auth git-credential',
                    'fetch', '--quiet', '--depth=1', 'origin', revision], check=True)


def producer_revision_is_in_history(root, revision, *, include_main=False):
    current = subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()

    def get(path):
        return json.loads(subprocess.check_output(
            ['gh', 'api', f'repos/{REPO}/{path}'], text=True))

    def is_ancestor(commit, target):
        return get(f'compare/{commit}...{target}').get('merge_base_commit', {}).get('sha') == commit

    if is_ancestor(revision, current):
        return True
    main = get('git/ref/heads/main')['object']['sha'] if include_main else ''
    if main and is_ancestor(revision, main):
        return True
    # A squash merge retains the reviewed source, but not the producer commits.
    for pull in get(f'commits/{revision}/pulls'):
        merged = pull.get('merge_commit_sha')
        head, base = pull.get('head') or {}, pull.get('base') or {}
        if (not pull.get('merged_at') or not re.fullmatch(r'[0-9a-f]{40}', merged or '')
                or (head.get('repo') or {}).get('full_name') != REPO
                or (base.get('repo') or {}).get('full_name') != REPO):
            continue
        if is_ancestor(merged, current):
            return True
        # A separate review branch may predate the merge into main. Trust only
        # the exact reviewed head for this additional cross-branch path.
        if main and base.get('ref') == 'main' and head.get('sha') == revision and is_ancestor(merged, main):
            return True
    return False


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
        if other_branch and not producer_revision_is_in_history(root, revision):
            raise ValueError('Linux producer revision is not in trusted merged history')
        fetch_revision(root, revision)
        for path in INPUTS:
            if git('rev-parse', revision + ':' + path) != git('rev-parse', 'HEAD:' + path):
                raise ValueError('Linux source input changed: ' + path)
    elif revision != git('rev-parse', 'HEAD'):
        raise ValueError('Linux userland came from a different source revision')
    subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=root / '.build/linux-transfer', check=True)
    print('Verified Linux producer source and archive checksums.')


if __name__ == '__main__':
    verify(ROOT, os.environ.get('LINUX_RUNTIME_RUN_ID', ''))
