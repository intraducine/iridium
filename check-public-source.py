#!/usr/bin/env python3
"""Check common private-data patterns; prints paths and categories, never values."""
from pathlib import Path
import re
import sys

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
for path in ROOT.rglob("*"):
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
            findings.append((path.relative_to(ROOT), category))
    if path.suffix.lower() in {".p12", ".pfx", ".mobileprovision", ".provisionprofile"}:
        findings.append((path.relative_to(ROOT), "signing material"))
for path, category in findings:
    print(f"{path}: {category}")
print(f"Privacy scan: {len(findings)} finding(s)")
sys.exit(bool(findings))
