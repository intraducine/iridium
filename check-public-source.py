#!/usr/bin/env python3
"""Check common private-data patterns; prints paths and categories, never values."""
from pathlib import Path
import re
import sys
import subprocess
import hashlib
import json

ROOT = Path(__file__).resolve().parent
PATTERNS = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "access token": rb"\b(?:ghp_|github_pat_|AKIA)[A-Za-z0-9_]{16,}\b",
    "device identifier": rb"\b00008[0-9A-Fa-f]{3}-[0-9A-Fa-f]{16}\b",
    "configured signing team": rb"(?m)^\s*DEVELOPMENT_TEAM\s*:\s*[A-Z0-9]{10}\s*$",
}
# Pass private identifiers as arguments for a targeted local scan. Do not commit them.
for index, value in enumerate(sys.argv[1:]):
    PATTERNS[f"private identifier {index + 1}"] = re.escape(value.encode())
findings = []
# This published archive includes GnuTLS's RSA self-test fixture. The key matches
# gnutls-3.8.9/lib/crypto-selftests-pk.c in the supplied source tarball. Any changed
# archive still fails this check; no maintainer key or other pattern is exempt.
PUBLIC_SELF_TEST = {
    'vendor/Madeira/app/Madeira/libgnutls.a': '1d514008193616c017131714e74b585d8e09753c3681875a128db93cd2abaf7b',
}
# Only reviewed public upstream bytes may bypass the signing-file suffix check.
# The source collector omits these files; other privacy patterns still apply.
PUBLIC_SIGNING_FIXTURES = json.loads((ROOT / 'ci/public-signing-fixtures.json').read_text())
def source_files(root):
    if (root / '.git').exists():
        result = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
        for name in set(result.decode().split('\0')) - {''}:
            path = root / name
            if path.is_dir() and (path / '.git').exists(): yield from source_files(path)
            elif path.is_file(): yield path
    else:
        yield from root.rglob('*')

for path in source_files(ROOT):
    if not path.is_file() or ".git" in path.relative_to(ROOT).parts or path == Path(__file__).resolve():
        continue
    if path.stat().st_size >= 50 * 1024 * 1024:
        findings.append((path.relative_to(ROOT), "large file; use release assets"))
    if any(part.endswith((".app", ".xcarchive")) or part in {"_CodeSignature", "xcuserdata"} for part in path.relative_to(ROOT).parts):
        findings.append((path.relative_to(ROOT), "generated app or personal metadata"))
    data = path.read_bytes()
    if data.startswith(b"version https://git-lfs.github.com/spec/v1"):
        findings.append((path.relative_to(ROOT), "LFS pointer"))
    for category, pattern in PATTERNS.items():
        if re.search(pattern, data, re.IGNORECASE):
            if category == 'private key' and PUBLIC_SELF_TEST.get(str(path.relative_to(ROOT))) == hashlib.sha256(data).hexdigest():
                continue
            findings.append((path.relative_to(ROOT), category))
    if path.suffix.lower() in {".p12", ".pfx", ".mobileprovision", ".provisionprofile"}:
        fixture = PUBLIC_SIGNING_FIXTURES.get(path.relative_to(ROOT).as_posix(), {})
        if path.is_symlink() or fixture.get('sha256') != hashlib.sha256(data).hexdigest():
            findings.append((path.relative_to(ROOT), "signing material"))
for path, category in findings:
    print(f"{path}: {category}")
print(f"Privacy scan: {len(findings)} finding(s)")
sys.exit(bool(findings))
