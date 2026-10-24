# PSP checks

These fixtures test the historical Libretro host. The current player uses
native PPSSPP iOS; its device validation is separate.

With a trusted host-architecture component exporting the required Libretro API
and `ir_ppsspp_boot_pending`:

```sh
python3 ci/check-ppsspp.py --component /path/to/ppsspp_libretro.dylib \
  --api-header /path/to/libretro.h --assets /path/to/PPSSPP/assets
```

The runner compiles the actual bridge and uses temporary files. Original MIPS
fixtures cover frames, audio buffers, input, cancellation, repeated sessions,
and teardown. It does not build/download the engine or prove device gameplay,
audibility, performance, or save-game compatibility.

For the source-built native H.264 startup check on an Apple Silicon Mac:

```sh
python3 ci/check-ppsspp-native-codec.py --output .build/ppsspp/host-codec-check
```

Regenerate its original red-frame input with FFmpeg:

```sh
ffmpeg -f lavfi -i color=c=red:s=16x16:r=1 -frames:v 1 -c:v libx264 \
  -profile:v baseline -x264-params keyint=1:bframes=0 \
  -bsf:v filter_units=remove_types=6 -f h264 red-frame.h264
```

Fixtures are AGPL-3.0-only. Supplied engines, headers, and assets retain their licenses.
