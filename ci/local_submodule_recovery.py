#!/usr/bin/env python3
"""Recover interrupted clones and header-only artifact directories without deleting source."""
from pathlib import Path
import subprocess
import sys
import tempfile


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def recover(root: Path, modules: list[str]) -> None:
    root = root.resolve()
    for module in modules:
        path = root / module
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise RuntimeError(f"Unsafe dependency path: {module}")
        entry = git(root, "ls-tree", "HEAD", "--", module)
        if not entry.startswith("160000 commit "):
            raise RuntimeError(f"Not a pinned submodule: {module}")
        if not path.exists():
            continue
        if not path.is_dir():
            raise RuntimeError(f"Dependency path is not a directory: {module}")
        children = list(path.iterdir())
        if not children:
            continue
        if not (path / ".git").exists():
            # Prepared-runtime archives can provide just include/. That is not a
            # compilable or version-verified submodule, even if it is nonempty.
            backups = root / ".build/local-submodule-backups"
            backups.mkdir(parents=True, exist_ok=True)
            backup = Path(tempfile.mkdtemp(prefix=module.replace("/", "__") + "-source-", dir=backups)) / "source"
            path.rename(backup)
            print(f"Preserved unversioned dependency {module} at {backup}; initializing pinned source.", flush=True)
            continue

        # Git clones all modules before checking them out. If a later clone
        # fails, earlier modules can contain only .git with *no index*. HEAD can
        # already equal the expected commit, so an ordinary update skips them.
        top = git(path, "rev-parse", "--show-toplevel")
        parent = git(path, "rev-parse", "--show-superproject-working-tree")
        index = Path(git(path, "rev-parse", "--git-path", "index"))
        if not index.is_absolute():
            index = path / index
        if (Path(top).resolve() == path.resolve() and parent and Path(parent).resolve() == root
                and {p.name for p in children} == {".git"} and not index.exists()):
            print(f"Complete interrupted no-checkout submodule: {module}", flush=True)
            # No source/index exists to overwrite. Never do this to a populated,
            # intentionally modified or standalone checkout.
            subprocess.run(["git", "-C", str(path), "reset", "--hard", "HEAD"], check=True)


def main():
    recover(Path(__file__).resolve().parents[1], sys.argv[1:])


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Submodule preparation: " + str(error), file=sys.stderr)
        sys.exit(1)
