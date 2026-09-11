#!/usr/bin/env python3
"""Remove build-host identity and host links from a newly generated Wine prefix."""
from pathlib import Path
import socket
import sys


def sanitize(prefix, username, hostname):
    if not username or username in {'.', '..'} or '/' in username or '\\' in username:
        raise ValueError('Invalid build username')
    # This helper is only for a new CI prefix, never a user's existing saves.
    if not (prefix.parent / '.iridium-prefix-build').is_file():
        raise ValueError('Refusing to sanitize a prefix outside a marked build directory')
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError('Expected a real prefix directory')
    for path in prefix.rglob('*'):
        if path.is_symlink():
            path.unlink()
    users = prefix / 'drive_c/users'
    old = users / username
    if old.is_dir() and username != 'madeira':
        old.rename(users / 'madeira')
    for name in ['system.reg', 'user.reg', 'userdef.reg']:
        path = prefix / name
        text = path.read_text()
        lines = []
        for line in text.splitlines(keepends=True):
            # Host-drive references include Mac fonts and desktop locations.
            if 'z:\\\\' in line.lower() or '/Users/' in line or '/home/' in line:
                continue
            line = line.replace(username, 'madeira')
            if hostname:
                line = line.replace(hostname, 'iridium')
            lines.append(line)
        path.write_text(''.join(lines))
    if any(path.is_symlink() for path in prefix.rglob('*')):
        raise ValueError('Prefix still contains host links')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: sanitize-prefix.py PREFIX BUILD_USER')
    sanitize(Path(sys.argv[1]), sys.argv[2], socket.gethostname())
