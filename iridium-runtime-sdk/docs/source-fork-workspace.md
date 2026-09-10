# Source Fork Workspace

The runtime effort owns two sibling source trees outside the app repo:

- `$IRIDIUM_WINE_ROOT`
- `$IRIDIUM_FEX_ROOT`

These are the long-lived porting workspaces for the real iOS engine.

Rules for the first milestone:
- `iridium-wine-ios`: win64-only, direct-launch-only, no desktop shell, no launcher flows, no installer UX
- `iridium-fex-ios`: x64-to-arm64 translator, external-JIT-dependent, iOS readiness probing
- OpenGL-only real-game milestone
- `runtime-host.bin` and the embedded host core stay in this SDK repo and consume outputs from those forks
- the FEX fork must also expose the canonical alias manifests at `$IRIDIUM_FEX_ROOT/build-iridium-ios-host`, `$IRIDIUM_FEX_ROOT/build-iridium-ios-iphoneos`, and `$IRIDIUM_FEX_ROOT/build-iridium-ios-iphonesimulator`; the SDK validates those manifests during package resolution
- Xcode consumers select `iphoneos` vs `iphonesimulator` in destination-aware build settings; do not treat `build-iridium-ios-current` as the product link path

`bootstrap_source_forks.sh` is the supported way to create or refresh those sibling repos.
