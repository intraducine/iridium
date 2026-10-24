# FEX iOS bridge

Retained bridge for the [embedded runtime SDK](../../../iridium-runtime-sdk/README.md).
The current app uses a separate Madeira backend.

## Build and test

From the FEX root:

```sh
./iridium/ios/build_embedded_translator.sh --platform host
ctest --test-dir build-iridium-ios-host --output-on-failure
```

Use `--platform device` (default) or `simulator` for Apple compile checks. The
script selects `IRIDIUM_IOS_EMBEDDED=ON` and emits
`build-iridium-ios-<platform>/artifacts/libiridium-fex-ios-embedded.a`.
Default builds refresh the SDK aliases `-host`, `-iphoneos`, and `-iphonesimulator`.
Do not link through the compatibility `-current` alias.

## Contract

The C bridge owns readiness, direct-win64 validation, guest startup, polling,
and exit collection through `iridium_fex_ios_*`. The SDK owns bundle assembly;
the Wine bridge owns userland and prefix staging.

Execution maps ELF segments/interpreter, builds guest argv/environment/stack,
handles supported relocations/TLS entries, and enters FEXCore. A partial Darwin
syscall bridge handles loader, memory, file, pipe/socket, signal-bookkeeping,
and exit operations. Unsupported calls return Linux `ENOSYS`.

A preloader requires a sibling Unix Wine companion and its PT_INTERP interpreter.
The bridge executes the companion with `WINELOADERNOEXEC=1`. Blocked low-address
Wine shared data uses the supported high-address fallback in rebuilt userland.

Readiness requires usable translation and JIT, including required debugger
bootstrap. Host tests cover contracts, probe failures, split RX/RW execution,
and a guarded native-wineserver smoke path. These do not prove complete iOS
syscall/thread/TLS support or physical-device gameplay.
