#!/bin/sh
set -eu
cache=/tmp/iridium-media-sdk
mkdir -p "$cache"
archive="$cache/gstreamer.tar.xz"
if [ ! -f "$archive" ]; then
  curl -L --fail --retry 2 \
    https://gstreamer.freedesktop.org/data/pkg/ios/1.28.6/gstreamer-1.28.6-xcframework.tar.xz \
    -o "$archive"
fi
printf '%s  %s\n' 48437f2a8f17bc1de40097eec9aedc0d307a30c15d9e996bf75bc07562bd79a5 "$archive" | shasum -a 256 -c -
if [ ! -f "$cache/GStreamer.xcframework/ios-arm64/libGStreamer.a" ]; then
  tar -xJf "$archive" -C "$cache"
fi
