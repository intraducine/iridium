# Local incremental IPA builds

From `ci/`, run:

```sh
git pull --ff-only
bash build-local-ipa.sh
```

From the repository root, use `bash ci/build-local-ipa.sh` instead.

The command now checks the complete local host tool set **before** downloading
sources or changing submodules. It installs missing Homebrew tools in one
`brew install --formula ...` invocation: CMake, Ninja, Bison, Flex, pkgconf, LLVM,
XcodeGen, Meson, zstd and rustup. Existing working tools are reused; it does not
run a blanket `brew upgrade`, change shell startup files, or clear build caches.
The build exports keg-only tool paths to all child processes.

Apple Silicon macOS, Homebrew, Python 3.11+, and a full Xcode installation with
its iPhoneOS SDK are required. Set `DEVELOPER_DIR` to select a particular Xcode;
otherwise the active full Xcode is used, with `/Applications/Xcode-beta.app`
and `/Applications/Xcode.app` as fallbacks. Command Line Tools alone are not
sufficient. Metal is downloaded only when `xcrun` cannot find a working compiler.

To check without installing tools:

```sh
IRIDIUM_AUTO_INSTALL_BUILD_TOOLS=0 bash ci/build-local-ipa.sh
```

A failed check reports the full missing-package set and one install command.
Do not use this as a clean-room dependency bootstrap: the existing local runtime
flow still requires staged media/JIT/ANGLE frameworks, a prefix and Linux
userland. The native rebuild updates FEX/Wine/DXMT and uses those staged inputs.
Installing an Actions IPA does not automatically stage development dependencies
into a local checkout.

## Interrupted source preparation

Git can clone multiple submodules before checking any of them out. A later
failure can leave earlier directories containing only `.git`, without an
index—even if HEAD already equals the required commit. Local preparation now
materializes this specific empty state before inspecting tracked modifications.
It does not reset a populated checkout as part of that recovery.

Directories containing only headers restored from artifacts are not complete
submodule sources. Unversioned directories at the selected gitlink paths are
moved intact to unique locations under `.build/local-submodule-backups/` before
Git initializes the pinned checkout. The paths are printed in the build log.
Keep these backups until any local source edits have been reviewed.

## Build output and verification

Every invocation saves console output under `.build/local-build-logs/` and
prints the path. A failure prints that path and exits without packaging an IPA.
The native-input cache and `.build/local-ipa` Xcode directory are retained.
The existing native cache skips native compilation when its inputs match;
this change does not replace it with unconditional native builds.

Run the executable bootstrap and real-Git recovery tests without macOS tools:

```sh
python3 -m unittest discover -s ci -p 'test_local_build_tools.py'
python3 -m unittest discover -s ci -p 'test_local_submodule_recovery.py'
```

The tests use fake Homebrew/Xcode executables and real temporary Git repositories.
They validate setup and recovery behavior, not iOS native compilation or device
execution. A successful Xcode build and device test remain separate requirements.
