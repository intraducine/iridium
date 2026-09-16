#!/usr/bin/env python3
"""Prepare all host build tools before a local IPA build changes dependencies.

Only missing Homebrew tools are installed. Existing tools, source trees and
compiler caches are not removed. Set IRIDIUM_AUTO_INSTALL_BUILD_TOOLS=0 for a
read-only check that reports all missing packages together.
"""
import argparse
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

# Match the macOS Actions recipe, plus rustup required by the native preflight.
# Windows cross-compilers come from the digest-locked LLVM-MinGW input, not brew.
FORMULAE = {
    "cmake": ("cmake",),
    "ninja": ("ninja",),
    "bison": ("bison",),
    "flex": ("flex",),
    "pkgconf": ("pkg-config",),
    "llvm": ("llvm-objcopy", "llvm-ar", "clang", "clang++"),
    "xcodegen": ("xcodegen",),
    "meson": ("meson",),
    "zstd": ("zstd",),
    "rustup": ("rustup",),
}
KEG_ONLY = {"bison", "flex", "llvm"}
SYSTEM_TOOLS = ("git", "make", "patch", "tar", "curl", "unzip", "xxd", "zsh", "ditto", "shasum")


def capture(command, env):
    return subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def require_output(command, env):
    result = capture(command, env)
    if result.returncode:
        raise RuntimeError(shlex.join(command) + " failed:\n" + result.stderr.strip())
    return result.stdout.strip()


def validate_host():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Local IPA builds require an Apple Silicon Mac; do not run the terminal through Rosetta.")
    if sys.version_info < (3, 11):
        raise RuntimeError("Python 3.11 or newer is required. Install it with: brew install python")


def build_path(root, prefix, original):
    directories = [root / "testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"]
    directories += [prefix / "opt" / name / "bin" for name in FORMULAE]
    directories += [prefix / "bin", prefix / "sbin", Path.home() / ".cargo/bin"]
    return os.pathsep.join(dict.fromkeys([str(p) for p in directories] + original.split(os.pathsep)))


def missing_formulae(prefix, env):
    missing = []
    for formula, commands in FORMULAE.items():
        # Apple's old bison/flex and the SDK clang are not substitutes for the
        # Homebrew packages explicitly selected by the compiler recipes.
        search = str(prefix / "opt" / formula / "bin") if formula in KEG_ONLY else env["PATH"]
        if any(shutil.which(command, path=search) is None for command in commands):
            missing.append(formula)
    return missing


def prepare_environment(root, *, install=True, environ=None):
    validate_host()
    env = dict(os.environ if environ is None else environ)
    original = env.get("PATH", "")
    brew = shutil.which("brew", path=original)
    if brew is None and Path("/opt/homebrew/bin/brew").is_file():
        brew = "/opt/homebrew/bin/brew"
    if brew is None:
        raise RuntimeError("Homebrew is required. Install Homebrew, then rerun this command; no source was changed.")
    prefix = Path(require_output([brew, "--prefix"], env))
    env["PATH"] = build_path(root, prefix, original)

    # Preserve build-local-ipa.sh's historical Xcode-beta default when present.
    beta = Path("/Applications/Xcode-beta.app/Contents/Developer")
    if not env.get("DEVELOPER_DIR") and (beta / "Platforms/iPhoneOS.platform").is_dir():
        env["DEVELOPER_DIR"] = str(beta)
    if not env.get("DEVELOPER_DIR"):
        selected = capture(["xcode-select", "-p"], env)
        if selected.returncode == 0 and (Path(selected.stdout.strip()) / "Platforms/iPhoneOS.platform").is_dir():
            env["DEVELOPER_DIR"] = selected.stdout.strip()
        else:
            for app in ("Xcode-beta.app", "Xcode.app"):
                candidate = Path("/Applications") / app / "Contents/Developer"
                if (candidate / "Platforms/iPhoneOS.platform").is_dir():
                    env["DEVELOPER_DIR"] = str(candidate)
                    break

    # Diagnose all Apple/system prerequisites before installing packages.
    errors = ["Missing macOS tool: " + tool for tool in SYSTEM_TOOLS
              if shutil.which(tool, path=env["PATH"]) is None]
    for command in (["xcodebuild", "-version"], ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]):
        try:
            require_output(command, env)
        except (OSError, RuntimeError) as error:
            errors.append(str(error))
    if errors:
        raise RuntimeError("Local build preflight failed:\n" + "\n".join(errors)
                           + "\nSelect a full Xcode installation with its iPhoneOS SDK (not CommandLineTools).")

    missing = missing_formulae(prefix, env)
    if missing:
        command = [brew, "install", "--formula", *missing]
        print("Missing local build packages: " + ", ".join(missing), flush=True)
        if not install:
            raise RuntimeError("Install all missing packages with:\n" + shlex.join(command))
        print("+ " + shlex.join(command), flush=True)
        brew_env = dict(env, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_UPGRADE="1",
                        HOMEBREW_NO_INSTALL_CLEANUP="1", HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1")
        result = subprocess.run(command, env=brew_env, check=False)
        if result.returncode:
            raise RuntimeError("Homebrew could not install the build tools. No native source was changed.\nRetry: "
                               + shlex.join(command))
        missing = missing_formulae(prefix, env)
        if missing:
            raise RuntimeError("Packages still have missing executables: " + ", ".join(missing)
                               + "\nCheck their Homebrew installations before compiling.")

    # An installed-but-broken executable is different from a missing package.
    broken = []
    for commands in FORMULAE.values():
        for command in commands:
            result = capture([command, "--version"], env)
            if result.returncode:
                broken.append(command + ": " + result.stderr.strip())
    if broken:
        raise RuntimeError("Build tools could not run:\n" + "\n".join(broken))

    metal = capture(["xcrun", "--sdk", "iphoneos", "metal", "--version"], env)
    if metal.returncode:
        if not install:
            raise RuntimeError("Metal toolchain is missing. Run: xcodebuild -downloadComponent MetalToolchain")
        print("Installing the missing Xcode Metal toolchain.", flush=True)
        subprocess.run(["xcodebuild", "-downloadComponent", "MetalToolchain"], env=env, check=True)
        require_output(["xcrun", "--sdk", "iphoneos", "metal", "--version"], env)
    print("Local build tool preflight passed.", flush=True)
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-env", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Report missing tools without installing them")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.write_env.unlink(missing_ok=True)  # A failed preflight must not leave a usable stale environment.
    env = prepare_environment(root, install=not args.check and os.environ.get("IRIDIUM_AUTO_INSTALL_BUILD_TOOLS", "1") != "0")
    args.write_env.parent.mkdir(parents=True, exist_ok=True)
    values = {key: env[key] for key in ("PATH", "DEVELOPER_DIR") if key in env}
    args.write_env.write_text("".join("export " + key + "=" + shlex.quote(value) + "\n" for key, value in values.items()))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Local build setup: " + str(error), file=sys.stderr)
        sys.exit(69)
