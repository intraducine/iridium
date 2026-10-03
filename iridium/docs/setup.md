# Setup

Iridium is a monorepo. The current iOS app uses the Madeira integration in
`testrepos/Madeira`, the Steam NativeAOT framework, and the built-in JIT helper.
Start with the root [IPA build guide](../../docs/actions-ipa.md) and
[local build guide](../../docs/local-ipa-build.md).

## Current app prerequisites

- An Apple Silicon Mac, Homebrew, Python 3.11 or newer for the local build, and
  full Xcode 27 with its iPhoneOS SDK. The Actions recipe uses Python 3.12.
- A working Xcode toolchain with its license and first-run setup completed.
  Set `DEVELOPER_DIR` when selecting a particular full Xcode installation;
  Command Line Tools alone are insufficient.
- .NET SDK **10.0.401** for the Steam framework.
- The initial Linux userland, media, prefix, graphics, and JIT inputs prepared
  using the root IPA guide. A fresh checkout cannot build the complete runtime
  from the incremental app command alone.

The local command checks host tools before changing dependencies and can install
missing Homebrew tools together. Set `IRIDIUM_AUTO_INSTALL_BUILD_TOOLS=0` to
report missing tools without installing them. It does not upgrade all tools or
clear existing caches.

## Clone and build

```sh
git clone https://github.com/intraducine/iridium.git
cd iridium
```

The root `.gitmodules` and `DEPENDENCIES.json` pin external sources. Prepare
those sources and the initial runtime inputs with the root build guide; do not
substitute independently cloned latest dependency heads.

After preparation, run from the monorepo root:

```sh
bash ci/build-local-ipa.sh
```

This command generates `iridium/apps/ios/IridiumStikJIT.xcodeproj` from
`iridium/apps/ios/stikjit.yml`, which includes `madeira.yml` and `project.yml`.
It builds the Release app without Xcode signing, then stages and audits the IPA
with the anonymous main-app memory entitlement carrier. The output still uses
`Iridium-unsigned.ipa`. For standalone installation, sign the app and helper and
confirm increased-memory-limit in Iridium's final signature and profile.
LiveContainer uses its host process's effective signing/JIT rights; importing
the guest IPA does not grant those rights.
No Apple account credentials, certificate, profile, or pairing file belongs in
Actions or the source checkout.

Logs and reusable outputs remain in `.build`. Retry the same command after
fixing a failure. Do not delete saves, game folders, or prefixes to repair a
build. A completed build does not establish device compatibility.

## Source validation

From the monorepo root:

```sh
python3 check-public-source.py
python3 ci/check-standards.py
python3 -B -m unittest discover -s ci -p 'test_*.py'
git diff --check
```

Swift package checks run from the `iridium/` component directory. The root
workflow supplies the current iOS SDK, Steam NativeAOT, simulator, helper,
application, and package checks. A simulator fixture does not establish account
login, downloads, or game behavior on an iPhone or iPad.

## Earlier runtime component development

`iridium-runtime-sdk`, `iridium-fex-ios`, and `iridium-wine-ios` remain sibling
directories within the monorepo for the earlier embedded-runtime contracts and
tests. Their component READMEs describe their own host/device/simulator builds.
The `iridium/scripts/doctor.sh`, `bootstrap.sh`, and `generate-project.sh`
helpers still target that older path and generate `Iridium.xcodeproj` from
`project.yml`. They are not the complete Madeira/Steam/JIT IPA build entry point.
The older app-stage path expects Amethyst framework inputs; current release
preparation uses the graphics inputs in the root workflow instead.

## Device setup and validation

Use [the JIT guide](builtin-stikjit-ios27.md) for standalone built-in JIT and
LiveContainer external JIT. Built-in JIT requires debugging permission, a valid
pairing file, and LocalDevVPN; it is unavailable when Iridium is hosted.

In **Settings → Runtime → Display & Memory**, choose resolution and the maximum
JIT code pool for the next launch. Automatic checks the current app memory
limit and tries smaller pools if allocation fails. Smaller pools can limit games.

In **Launch Support → External JIT App**, select the route. Automatic tries
LiveContainer2, StikDebug, LiveContainer, then a LiveContainer3 fallback. Pending
JIT requests are bounded; close the player to cancel, and restart if requested.

Use [the manual validation runbook](manual-validation-runbook.md) to record
rendering, input, audio, saves, and shutdown separately on a physical device.
Results from the earlier embedded runtime do not validate Madeira or the release
IPA. Real Steam account/download and recipient-signing checks remain outstanding.
