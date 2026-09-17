# Native Steam module dependencies

Original integration code is AGPL-3.0-only, as described in the monorepo LICENSE.
Dependency ownership: the Iridium Steam integration. SteamKit is used because it
implements Steam client authentication, depot authorization, encrypted manifests,
and chunk decompression; Steam OpenID alone cannot download owned game content.

The NuGet lock records exact package versions and SHA-512 content hashes.
Package metadata and the source revisions below identify the source inputs.

| Component | Version / source revision | License |
| --- | --- | --- |
| SteamKit2 | 3.4.0, `1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7` | LGPL-2.1-only; embedded third-party notices also apply |
| protobuf-net / protobuf-net.Core | 3.2.56, `dfdfce61a739cfd76f05fcdacf8a4b3b9e94e684` | Apache-2.0 |
| ZstdSharp.Port | 0.8.7, `0ee6121aaa173b42e68d3c6c8816a68e910e0557` | MIT; translated Zstandard notices also apply |
| System.IO.Hashing | 10.0.1, dotnet/dotnet `fad253f51b461736dfd3cd9c15977bb7493becef` | MIT |
| .NET runtime / NativeAOT | runtime 10.0.12, SDK 10.0.401 | MIT and runtime third-party notices |

Sources: https://github.com/SteamRE/SteamKit,
https://github.com/protobuf-net/protobuf-net,
https://github.com/oleg-st/ZstdSharp,
https://github.com/dotnet/dotnet.

SteamKit is built from the pinned source with the local patch
`ci/patches/steamkit-ios-process-start.patch`. It replaces unsupported iOS/tvOS
process-start inspection with a timestamp for client job IDs. Run
`python3 ci/prepare-steamkit.py` before the rebuild commands in README.md.
Other runtime dependencies are unmodified NuGet packages. No Steam client binaries, game
assets, Steam credentials, or depot keys are bundled. Retain the original license
texts and embedded third-party notices, exact corresponding source (including the
NativeAOT runtime inputs), and the rebuild/relink recipe beside any binary release.
The existing binary audit must cover the new IridiumSteam framework before release;
the pre-existing Madeira binary inventory does not cover this added framework.
Replacing SteamKit is supported by rebuilding this framework from source with the
desired compatible package or project reference and rerunning the tests. The
application loads the replacement through the same five C ABI entry points.
