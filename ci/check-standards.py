#!/usr/bin/env python3
"""Validate release descriptions and the repository's workflow safety rules."""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
HEADINGS = ('Summary', 'Changes', 'Installation and requirements', 'Migration and saves',
            'Verification', 'Known limitations', 'Downloads and source')


def release_errors(path):
    text = path.read_text()
    errors = []
    version = path.stem
    if not re.fullmatch(VERSION, version):
        errors.append('Invalid release version filename')
    elif '-' in version and any(part.isdigit() and len(part) > 1 and part[0] == '0'
                                 for part in version.split('-', 1)[1].split('.')):
        errors.append('Numeric prerelease identifiers cannot have leading zeros')
    if not text.startswith('# Iridium ' + version + '\n'):
        errors.append('Release title must match its version filename')
    actual = re.findall(r'^## (.+)$', text, re.M)
    if actual != list(HEADINGS):
        errors.append('Release sections must match the template order')
    for heading in HEADINGS:
        match = re.search(r'^## ' + re.escape(heading) + r'\n(.*?)(?=^## |\Z)', text, re.M | re.S)
        if match and not match[1].strip():
            errors.append('Empty section: ' + heading)
    if re.search(r'\[Required:|\b(?:TODO|TBD|FIXME|VERSION)\b', text):
        errors.append('Unresolved release placeholder')
    if not re.search(r'^Source commit: [0-9a-f]{40}$', text, re.M):
        errors.append('Missing full source commit')
    if not re.search(r'^Build run: https://github\.com/intraducine/iridium/actions/runs/[0-9]+$', text, re.M):
        errors.append('Missing build evidence URL')
    return errors


def workflow_errors(text):
    errors = []
    for reference in re.findall(r'^\s*-?\s*uses:\s*(\S+)', text, re.M):
        if reference.startswith('./'):
            continue
        if not re.fullmatch(r'[\w./-]+@[0-9a-f]{40}', reference):
            errors.append('External Action must use a full commit: ' + reference)
    if re.search(r'\bpull_request_target\b|\bsecrets\.', text):
        errors.append('Privileged PR execution or credential references are prohibited')
    if re.search(r'allowProvisioningUpdates|import-codesign-certs|security import', text):
        errors.append('Signing credential operations are prohibited')
    return errors


def check(root):
    errors = []
    for path in sorted((root / '.github/workflows').glob('*')):
        if path.suffix in {'.yaml', '.yml'}:
            errors.extend(str(path.relative_to(root)) + ': ' + e for e in workflow_errors(path.read_text()))
    for path in sorted((root / 'docs/releases').glob('*.md')):
        if path.name != 'TEMPLATE.md':
            errors.extend(str(path.relative_to(root)) + ': ' + e for e in release_errors(path))
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', help='Validate and print a versioned release description; no publication')
    args = parser.parse_args()
    if args.release:
        if not re.fullmatch(VERSION, args.release):
            parser.error('Invalid release version')
        path = ROOT / 'docs/releases' / (args.release + '.md')
        if not path.is_file():
            parser.error('Release description does not exist')
        errors = release_errors(path)
    else:
        errors = check(ROOT)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        sys.exit(1)
    print(path.read_text() if args.release else 'Repository standards checks passed.', end='' if args.release else '\n')
