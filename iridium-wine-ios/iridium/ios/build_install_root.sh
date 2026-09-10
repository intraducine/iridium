#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h:h}
SCRIPT_ROOT=${0:A:h}
source "$SCRIPT_ROOT/userland_validation.sh"

function usage() {
  cat >&2 <<'EOF'
usage:
  build_install_root.sh \
    [--build-root <path>] \
    [--install-root <path>] \
    [--jobs <count>] \
    [--platform <device|simulator|host|linux-x86_64>] \
    [--embedded-server-only] \
    [--container-image <tag>] \
    [--configure-arg <arg>]
EOF
}

function platform_sysroot_for_name() {
  case "$1" in
    device) echo "iphoneos" ;;
    simulator) echo "iphonesimulator" ;;
    host) echo "macosx" ;;
    *)
      echo "unsupported platform: $1" >&2
      exit 64
      ;;
  esac
}

function deployment_target_for_platform() {
  case "$1" in
    device|simulator) echo "18.0" ;;
    host) echo "15.0" ;;
    *) echo "" ;;
  esac
}

function validate_install_root_basics() {
  local install_root="$1"

  if [[ ! -f "$install_root/bin/wineserver" ]]; then
    echo "real install root is missing bin/wineserver" >&2
    exit 75
  fi

  if [[ ! -f "$install_root/bin/wine64" && ! -f "$install_root/bin/wine" ]]; then
    echo "real install root is missing a launchable Wine binary" >&2
    exit 75
  fi

  if [[ ! -d "$install_root/lib/wine" && ! -d "$install_root/lib64/wine" ]]; then
    echo "real install root is missing lib/wine or lib64/wine" >&2
    exit 75
  fi

  if [[ ! -d "$install_root/share/wine" ]]; then
    echo "real install root is missing share/wine" >&2
    exit 75
  fi
}

function build_linux_x86_64_install_root() {
  local dockerfile="$SCRIPT_ROOT/docker/linux_x86_64_builder.Dockerfile"
  local configure_invocation="/src/wine/configure"
  local arg=""

  DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"
  if [[ -z "$DOCKER_BIN" ]]; then
    echo "docker is required to build the linux-x86_64 Wine install root" >&2
    exit 69
  fi

  if ! "$DOCKER_BIN" version >/dev/null 2>&1; then
    echo "docker is installed but the daemon is not reachable; start Docker Desktop or another compatible daemon before building the linux-x86_64 Wine install root" >&2
    exit 69
  fi

  if [[ ! -f "$dockerfile" ]]; then
    echo "linux-x86_64 builder image definition is missing at $dockerfile" >&2
    exit 66
  fi

  for arg in "${EFFECTIVE_CONFIGURE_ARGS[@]}"; do
    configure_invocation+=" ${(q)arg}"
  done

  mkdir -p "$FINAL_BUILD_ROOT" "$INSTALL_ROOT"

  "$DOCKER_BIN" build \
    --platform linux/amd64 \
    -t "$CONTAINER_IMAGE" \
    -f "$dockerfile" \
    "$SCRIPT_ROOT/docker" >&2

  "$DOCKER_BIN" run \
    --rm \
    --platform linux/amd64 \
    -e JOBS="$JOBS" \
    -v "$ROOT:/src/wine" \
    -v "$FINAL_BUILD_ROOT:/work/build" \
    -v "$INSTALL_ROOT:/work/install-root" \
    "$CONTAINER_IMAGE" \
    /bin/bash -lc "set -euo pipefail; mkdir -p /work/build /work/install-root; cd /work/build; $configure_invocation; make -j${(q)JOBS}; make install; /src/wine/iridium/ios/stage_linux_runtime_deps.sh --install-root /work/install-root" >&2
}

typeset DEFAULT_APPLE_BUILD_ROOT="$ROOT/build-iridium-ios/wine-build"
typeset DEFAULT_APPLE_INSTALL_ROOT="$ROOT/build-iridium-ios/install-root"
typeset DEFAULT_LINUX_BUILD_ROOT="$ROOT/build-iridium-linux-x86_64/wine-build"
typeset DEFAULT_LINUX_INSTALL_ROOT="$ROOT/build-iridium-linux-x86_64/install-root"
typeset BUILD_ROOT="$DEFAULT_APPLE_BUILD_ROOT"
typeset INSTALL_ROOT="$DEFAULT_APPLE_INSTALL_ROOT"
typeset BUILD_ROOT_EXPLICIT=0
typeset INSTALL_ROOT_EXPLICIT=0
typeset JOBS=""
typeset MAKE_BIN=""
typeset DOCKER_BIN=""
typeset PLATFORM="host"
typeset CONTAINER_IMAGE="iridium-wine-linux-x86_64-builder:local"
typeset EMBEDDED_SERVER_ONLY=0
typeset SYSROOT=""
typeset DEPLOYMENT_TARGET=""
typeset SDKROOT=""
typeset BUILD_SUFFIX=""
typeset FINAL_BUILD_ROOT=""
typeset HOST_CFLAGS=""
typeset HOST_CXXFLAGS=""
typeset HOST_LDFLAGS=""
typeset -a BASE_CONFIGURE_ARGS EXTRA_CONFIGURE_ARGS EFFECTIVE_CONFIGURE_ARGS
BASE_CONFIGURE_ARGS=(
  "--enable-win64"
  "--disable-tests"
  "--without-x"
  "--without-freetype"
  "--enable-wineios-drv"
)
EXTRA_CONFIGURE_ARGS=()
EFFECTIVE_CONFIGURE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-root) BUILD_ROOT="$2"; BUILD_ROOT_EXPLICIT=1; shift 2 ;;
    --install-root) INSTALL_ROOT="$2"; INSTALL_ROOT_EXPLICIT=1; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --embedded-server-only) EMBEDDED_SERVER_ONLY=1; shift 1 ;;
    --container-image) CONTAINER_IMAGE="$2"; shift 2 ;;
    --configure-arg) EXTRA_CONFIGURE_ARGS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

case "$PLATFORM" in
  device|simulator|host|linux-x86_64) ;;
  *)
    echo "unsupported platform: $PLATFORM" >&2
    exit 64
    ;;
esac

if [[ "$EMBEDDED_SERVER_ONLY" -eq 1 && "$PLATFORM" != "device" && "$PLATFORM" != "simulator" ]]; then
  echo "--embedded-server-only is supported only for device and simulator builds" >&2
  exit 64
fi

if [[ "$PLATFORM" == "host" || "$EMBEDDED_SERVER_ONLY" -eq 1 ]]; then
  EXTRA_CONFIGURE_ARGS+=("--without-opengl")
else
  EXTRA_CONFIGURE_ARGS+=("--with-opengl")
fi

if [[ "$PLATFORM" == "linux-x86_64" ]]; then
  if [[ "$BUILD_ROOT_EXPLICIT" -eq 0 ]]; then
    BUILD_ROOT="$DEFAULT_LINUX_BUILD_ROOT"
  fi
  if [[ "$INSTALL_ROOT_EXPLICIT" -eq 0 ]]; then
    INSTALL_ROOT="$DEFAULT_LINUX_INSTALL_ROOT"
  fi
fi

if [[ -z "$JOBS" ]]; then
  JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
fi

BUILD_ROOT="${BUILD_ROOT:a}"
INSTALL_ROOT="${INSTALL_ROOT:a}"

if [[ "$PLATFORM" == "device" || "$PLATFORM" == "simulator" ]]; then
  if [[ "$PLATFORM" == "device" ]]; then
    BUILD_SUFFIX="-iphoneos"
  else
    BUILD_SUFFIX="-iphonesimulator"
  fi
elif [[ "$PLATFORM" == "linux-x86_64" ]]; then
  BUILD_SUFFIX="-linux-x86_64"
fi

FINAL_BUILD_ROOT="${BUILD_ROOT}${BUILD_SUFFIX}"
echo "DEBUG: BUILD_ROOT=$BUILD_ROOT"
echo "DEBUG: FINAL_BUILD_ROOT=$FINAL_BUILD_ROOT"
mkdir -p "$FINAL_BUILD_ROOT" "${INSTALL_ROOT:h}"
require_disjoint_paths "$FINAL_BUILD_ROOT" "build root" "$INSTALL_ROOT" "install root"
if [[ "$EMBEDDED_SERVER_ONLY" -eq 0 ]]; then
  reset_managed_output_directory "$INSTALL_ROOT" ".iridium-wine-install-root" "install root" "$ROOT" "$FINAL_BUILD_ROOT"
fi

if [[ ! -x "$ROOT/configure" ]]; then
  echo "Wine configure script is missing at $ROOT/configure" >&2
  exit 66
fi

if [[ "$PLATFORM" != "linux-x86_64" ]]; then
  if [[ -d /opt/homebrew/bin ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  if [[ -d /opt/homebrew/opt/llvm/bin ]]; then
    export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
  fi

  if [[ "$PLATFORM" == "device" || "$PLATFORM" == "simulator" ]]; then
    SYSROOT=$(platform_sysroot_for_name "$PLATFORM")
    DEPLOYMENT_TARGET=$(deployment_target_for_platform "$PLATFORM")
    export CC="clang"
    export CXX="clang++"
    export AR="ar"
    export RANLIB="ranlib"
    export STRIP="strip"
    SDKROOT="$(xcrun --sdk $SYSROOT --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/${SYSROOT}.platform/Developer/SDKs/${SYSROOT}.sdk")"
    export SDKROOT
    export CFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT -miphoneos-version-min=${DEPLOYMENT_TARGET}"
    export CXXFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT -miphoneos-version-min=${DEPLOYMENT_TARGET}"
    export LDFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT"
  elif [[ -d /opt/homebrew/opt/llvm/bin ]]; then
    export CC="${CC:-clang}"
    export CXX="${CXX:-clang++}"
    [[ -x /opt/homebrew/opt/llvm/bin/llvm-ar ]] && export AR="${AR:-llvm-ar}"
    [[ -x /opt/homebrew/opt/llvm/bin/llvm-ranlib ]] && export RANLIB="${RANLIB:-llvm-ranlib}"
    [[ -x /opt/homebrew/opt/llvm/bin/llvm-dlltool ]] && export DLLTOOL="${DLLTOOL:-llvm-dlltool}"
  fi

  if command -v gmake >/dev/null 2>&1; then
    MAKE_BIN=$(command -v gmake)
  elif command -v make >/dev/null 2>&1; then
    MAKE_BIN=$(command -v make)
  else
    echo "make is required to build the Wine install root" >&2
    exit 69
  fi

  typeset -a PE_TOOLCHAIN
  PE_TOOLCHAIN=(
    x86_64-w64-mingw32-gcc
    x86_64-w64-mingw32-clang
    clang
  )

  typeset HAVE_PE_TOOLCHAIN=0
  for tool in "${PE_TOOLCHAIN[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      HAVE_PE_TOOLCHAIN=1
      break
    fi
  done

  if [[ "$HAVE_PE_TOOLCHAIN" -eq 0 ]]; then
    cat >&2 <<'EOF'
PE-capable Wine cross-toolchain is missing.
Install one of:
  brew install mingw-w64 llvm lld
or provide:
  x86_64-w64-mingw32-{gcc,clang}
and an aarch64-capable clang/lld PE path on PATH.
EOF
    exit 69
  fi
fi

if [[ "$PLATFORM" == "device" || "$PLATFORM" == "simulator" ]]; then
  HOST_CFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT -miphoneos-version-min=${DEPLOYMENT_TARGET}"
  HOST_CXXFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT -miphoneos-version-min=${DEPLOYMENT_TARGET}"
  HOST_LDFLAGS="-target arm64-apple-ios${DEPLOYMENT_TARGET} -isysroot $SDKROOT"
  if [[ "$PLATFORM" == "device" && "$EMBEDDED_SERVER_ONLY" -eq 0 ]]; then
    typeset AMETHYST_ROOT="${IRIDIUM_AMETHYST_ROOT:-${ROOT:h}/Amethyst-iOS}"
    typeset AMETHYST_EGL_FRAMEWORK="$AMETHYST_ROOT/Natives/resources/Frameworks/libEGL.framework/libEGL"
    typeset AMETHYST_EGL_HEADERS="$AMETHYST_ROOT/Natives/external/mesa"
    if [[ -f "$AMETHYST_EGL_FRAMEWORK" && -f "$AMETHYST_EGL_HEADERS/EGL/egl.h" ]]; then
      typeset EGL_LINK_ROOT="$FINAL_BUILD_ROOT/iridium-egl-link"
      mkdir -p "$EGL_LINK_ROOT"
      ln -sf "$AMETHYST_EGL_FRAMEWORK" "$EGL_LINK_ROOT/libEGL.dylib"
      HOST_CFLAGS+=" -I$AMETHYST_EGL_HEADERS"
      HOST_CXXFLAGS+=" -I$AMETHYST_EGL_HEADERS"
      HOST_LDFLAGS+=" -L$EGL_LINK_ROOT -Wl,-rpath,@executable_path/Frameworks"
      export EGL_CFLAGS="${EGL_CFLAGS:-"-I$AMETHYST_EGL_HEADERS"}"
      export EGL_LIBS="${EGL_LIBS:-"-L$EGL_LINK_ROOT -lEGL"}"
      EXTRA_CONFIGURE_ARGS+=("ac_cv_lib_soname_EGL=@rpath/libEGL.framework/libEGL")
      echo "DEBUG: Using Amethyst libEGL for iOS OpenGL checks at $AMETHYST_EGL_FRAMEWORK"
    elif [[ -z "${EGL_CFLAGS:-}" || -z "${EGL_LIBS:-}" ]]; then
      cat >&2 <<EOF
iOS Wine OpenGL support is required but libEGL was not found.
Set IRIDIUM_AMETHYST_ROOT to an Amethyst-iOS checkout containing:
  Natives/external/mesa/EGL/egl.h
  Natives/resources/Frameworks/libEGL.framework/libEGL
or provide EGL_CFLAGS and EGL_LIBS explicitly.
EOF
      exit 66
    fi
  fi
fi

if [[ "$PLATFORM" == "linux-x86_64" ]]; then
  EFFECTIVE_CONFIGURE_ARGS=(
    "--prefix=/work/install-root"
    "${BASE_CONFIGURE_ARGS[@]}"
    "${EXTRA_CONFIGURE_ARGS[@]}"
  )
  build_linux_x86_64_install_root
else
  EFFECTIVE_CONFIGURE_ARGS=(
    "--prefix=$INSTALL_ROOT"
    "${BASE_CONFIGURE_ARGS[@]}"
    "${EXTRA_CONFIGURE_ARGS[@]}"
  )

  if [[ "$PLATFORM" == "device" || "$PLATFORM" == "simulator" ]]; then
    echo "DEBUG: Checking for existing macOS tools at $ROOT/build-iridium-ios/wine-build/tools"
    if [[ ! -d "$ROOT/build-iridium-ios/wine-build/tools/winebuild" ]]; then
      echo "ERROR: macOS Wine build tools not found at $ROOT/build-iridium-ios/wine-build/tools" >&2
      exit 1
    fi

    EFFECTIVE_CONFIGURE_ARGS+=(
      "--host=aarch64-apple-ios"
      "--with-wine-tools=$ROOT/build-iridium-ios/wine-build"
      "CFLAGS=$HOST_CFLAGS"
      "CXXFLAGS=$HOST_CXXFLAGS"
      "LDFLAGS=$HOST_LDFLAGS"
    )
    echo "DEBUG: Updated CONFIGURE_ARGS for iOS"
  fi

  echo "DEBUG: Running main configure in $FINAL_BUILD_ROOT"
  echo "DEBUG: CONFIGURE_ARGS=${EFFECTIVE_CONFIGURE_ARGS[@]}"
  (
    cd "$FINAL_BUILD_ROOT"
    "$ROOT/configure" "${EFFECTIVE_CONFIGURE_ARGS[@]}" >&2
    if [[ "$EMBEDDED_SERVER_ONLY" -eq 0 ]]; then
      "$MAKE_BIN" -j"$JOBS" >&2
      "$MAKE_BIN" install >&2
    fi
  )
fi

if [[ "$EMBEDDED_SERVER_ONLY" -eq 0 ]]; then
  validate_install_root_basics "$INSTALL_ROOT"
fi

if [[ "$PLATFORM" == "device" || "$PLATFORM" == "simulator" ]]; then
  "$SCRIPT_ROOT/build_embedded_wineserver.sh" \
    --build-root "$FINAL_BUILD_ROOT" \
    --output "$FINAL_BUILD_ROOT/artifacts/libiridium-wineserver-ios.a"
fi

if [[ "$PLATFORM" == "linux-x86_64" ]]; then
  typeset EMBEDDED_GUEST_LOADER=""
  if EMBEDDED_GUEST_LOADER=$(require_embedded_guest_wine_loader "$INSTALL_ROOT" "real install root"); then
    echo "DEBUG: embedded guest Wine loader=$EMBEDDED_GUEST_LOADER" >&2
  else
    exit $?
  fi
fi

if [[ "$EMBEDDED_SERVER_ONLY" -eq 1 ]]; then
  echo "$FINAL_BUILD_ROOT/artifacts/libiridium-wineserver-ios.a"
else
  echo "$INSTALL_ROOT"
fi
