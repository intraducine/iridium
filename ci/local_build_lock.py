#!/usr/bin/env python3
"""Run one local build per checkout; the OS releases the lock after crashes."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys


def run_locked(root, command):
    root = Path(root).resolve()
    lock = root / '.build/local-ipa.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    # Never unlink a flock file: waiters must keep referring to the same inode.
    with lock.open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another local IPA build is using this checkout. No files were changed.')
        env = dict(os.environ, IRIDIUM_LOCAL_BUILD_LOCKED=str(root))
        # Children retain the lock even if this supervisor is killed first.
        result = subprocess.run(command, cwd=root, env=env, pass_fds=(stream.fileno(),))
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit('Usage: local_build_lock.py ROOT COMMAND [ARG ...]')
    try:
        raise SystemExit(run_locked(sys.argv[1], sys.argv[2:]))
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(75)
