#!/bin/sh
# Builds a self-contained, end-user release of TinRoof Transcode:
#
#   1. Compiles FFmpeg and its codec libraries (x264, x265, SVT-AV1, libvpx, Opus, LAME, Snappy)
#      from source as static libraries for macOS $MIN_MACOS and later.
#   2. Links the app against those static libraries and bundles a static `ffmpeg` tool,
#      so nothing from Homebrew is needed on users' Macs.
#   3. Signs, notarizes and packages a drag-to-Applications DMG.
#
# Usage:
#   ./scripts/build_release.sh
#
# Signing and notarization (optional, needs an Apple Developer account):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=trt-notary     # created once with:
#       xcrun notarytool store-credentials trt-notary --apple-id you@example.com --team-id TEAMID
# Without DEVELOPER_ID the app is ad-hoc signed: fine for testing, but Gatekeeper will warn users.
#
# Build machine only (not needed by users): Xcode, cmake, nasm, pkg-config, autoconf.
set -e
cd "$(dirname "$0")/.."

# Build from a neutral folder so no home-folder paths (and so no user name) end up inside the binaries.
CLEAN_ROOT="${CLEAN_ROOT:-/tmp/trt-build}"
mkdir -p "$CLEAN_ROOT"
if [ "$(pwd -P)" != "$(cd "$CLEAN_ROOT" && pwd -P)" ]; then
  rsync -a --delete --exclude .git --exclude .build --exclude .build-release --exclude build --exclude vendor --exclude TestMedia ./ "$CLEAN_ROOT/"
  (cd "$CLEAN_ROOT" && ./scripts/build_release.sh)
  rm -rf build/release && mkdir -p build && cp -R "$CLEAN_ROOT/build/release" build/
  exit 0
fi
ROOT="$(pwd)"

APP_NAME="${APP_NAME:-TinRoof Transcode}"
BUNDLE_ID="${BUNDLE_ID:-com.tinroof.transcode}"
VERSION="${VERSION:-0.1.2}"
MIN_MACOS="${MIN_MACOS:-14.0}"
ARCH="${ARCH:-arm64}"
JOBS="$(sysctl -n hw.ncpu)"

FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
X264_BRANCH="stable"
X265_VERSION="4.1"
LAME_VERSION="3.100"
OPUS_VERSION="1.5.2"
VPX_VERSION="1.15.2"
SVTAV1_VERSION="3.1.2"
SNAPPY_VERSION="1.2.2"

SRC="$ROOT/vendor/release-src"
PREFIX="$ROOT/vendor/release/$ARCH"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS"
# Only our own .pc files: nothing may leak in from Homebrew.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""
CMAKE_COMMON="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_OSX_ARCHITECTURES=$ARCH \
 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
 -DCMAKE_INSTALL_LIBDIR=lib"

fetch() { # url, archive name
  [ -f "$SRC/$2" ] || curl -fL --retry 3 -o "$SRC/$2" "$1"
}
done_mark() { [ -f "$PREFIX/.built-$1" ]; }
mark() { touch "$PREFIX/.built-$1"; }
step() { printf '\n==> %s\n' "$*"; }

# --- Snappy (Hap) ---------------------------------------------------------------
if ! done_mark snappy; then
  step "snappy $SNAPPY_VERSION"
  fetch "https://github.com/google/snappy/archive/refs/tags/$SNAPPY_VERSION.tar.gz" "snappy-$SNAPPY_VERSION.tar.gz"
  rm -rf "$SRC/snappy-$SNAPPY_VERSION" && tar -xzf "$SRC/snappy-$SNAPPY_VERSION.tar.gz" -C "$SRC"
  rm -rf "$SRC/snappy-build"
  cmake -S "$SRC/snappy-$SNAPPY_VERSION" -B "$SRC/snappy-build" $CMAKE_COMMON -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF
  cmake --build "$SRC/snappy-build" -j "$JOBS"
  cmake --install "$SRC/snappy-build"
  mark snappy
fi

# --- x264 -----------------------------------------------------------------------
if ! done_mark x264; then
  step "x264 ($X264_BRANCH)"
  rm -rf "$SRC/x264" && git clone --depth 1 -b "$X264_BRANCH" https://code.videolan.org/videolan/x264.git "$SRC/x264"
  (cd "$SRC/x264" && ./configure --prefix="$PREFIX" --enable-static --disable-cli --enable-pic \
      --host="aarch64-apple-darwin" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
    && make -j "$JOBS" && make install)
  mark x264
fi

# --- x265 -----------------------------------------------------------------------
if ! done_mark x265; then
  step "x265 $X265_VERSION"
  fetch "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$X265_VERSION.tar.gz" "x265_$X265_VERSION.tar.gz"
  rm -rf "$SRC/x265_$X265_VERSION" && tar -xzf "$SRC/x265_$X265_VERSION.tar.gz" -C "$SRC"
  # x265 4.1 requests pre-3.x CMake policies that CMake 4 rejects.
  sed -i '' -E '/cmake_policy\(SET CMP00(25|54) OLD\)/d' "$SRC/x265_$X265_VERSION/source/CMakeLists.txt"
  # With CMP0025 NEW, Apple's compiler reports "AppleClang"; x265 only enables its Clang/ARM setup for "Clang".
  sed -i '' -E 's/\$\{CMAKE_CXX_COMPILER_ID\} STREQUAL "Clang"/${CMAKE_CXX_COMPILER_ID} MATCHES "Clang"/' "$SRC/x265_$X265_VERSION/source/CMakeLists.txt"
  rm -rf "$SRC/x265-build"
  cmake -S "$SRC/x265_$X265_VERSION/source" -B "$SRC/x265-build" $CMAKE_COMMON -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
  cmake --build "$SRC/x265-build" -j "$JOBS"
  cmake --install "$SRC/x265-build"
  mark x265
fi

# --- LAME (MP3) -----------------------------------------------------------------
if ! done_mark lame; then
  step "lame $LAME_VERSION"
  fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION.tar.gz"
  rm -rf "$SRC/lame-$LAME_VERSION" && tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$SRC"
  # lame's export list names a symbol that no longer exists.
  sed -i '' '/lame_init_old/d' "$SRC/lame-$LAME_VERSION/include/libmp3lame.sym"
  (cd "$SRC/lame-$LAME_VERSION" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend \
      --disable-decoder --host=aarch64-apple-darwin && make -j "$JOBS" && make install)
  mark lame
fi

# --- Opus -----------------------------------------------------------------------
if ! done_mark opus; then
  step "opus $OPUS_VERSION"
  fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" "opus-$OPUS_VERSION.tar.gz"
  rm -rf "$SRC/opus-$OPUS_VERSION" && tar -xzf "$SRC/opus-$OPUS_VERSION.tar.gz" -C "$SRC"
  (cd "$SRC/opus-$OPUS_VERSION" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-doc \
      --disable-extra-programs --host=aarch64-apple-darwin && make -j "$JOBS" && make install)
  mark opus
fi

# --- libvpx (VP8/VP9) -----------------------------------------------------------
if ! done_mark vpx; then
  step "libvpx $VPX_VERSION"
  rm -rf "$SRC/libvpx" && git clone --depth 1 -b "v$VPX_VERSION" https://chromium.googlesource.com/webm/libvpx "$SRC/libvpx"
  (cd "$SRC/libvpx" && ./configure --prefix="$PREFIX" --target=arm64-darwin22-gcc --disable-shared --enable-static \
      --enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth \
      --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
    && make -j "$JOBS" && make install)
  mark vpx
fi

# --- SVT-AV1 --------------------------------------------------------------------
if ! done_mark svtav1; then
  step "SVT-AV1 $SVTAV1_VERSION"
  fetch "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v$SVTAV1_VERSION/SVT-AV1-v$SVTAV1_VERSION.tar.gz" "svtav1-$SVTAV1_VERSION.tar.gz"
  rm -rf "$SRC/SVT-AV1-v$SVTAV1_VERSION" && tar -xzf "$SRC/svtav1-$SVTAV1_VERSION.tar.gz" -C "$SRC"
  rm -rf "$SRC/svtav1-build"
  cmake -S "$SRC/SVT-AV1-v$SVTAV1_VERSION" -B "$SRC/svtav1-build" $CMAKE_COMMON -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF
  cmake --build "$SRC/svtav1-build" -j "$JOBS"
  cmake --install "$SRC/svtav1-build"
  mark svtav1
fi

# --- FFmpeg ---------------------------------------------------------------------
if ! done_mark ffmpeg; then
  step "FFmpeg $FFMPEG_VERSION"
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  rm -rf "$SRC/ffmpeg-$FFMPEG_VERSION" && tar -xf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$SRC"
  (cd "$SRC/ffmpeg-$FFMPEG_VERSION" && ./configure --prefix="$PREFIX" \
      --arch="$ARCH" --cc=clang --cxx=clang++ \
      --enable-static --disable-shared --pkg-config-flags=--static \
      --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
      --enable-zlib --enable-bzlib --enable-iconv \
      --enable-gpl --enable-version3 \
      --enable-libx264 --enable-libx265 --enable-libsvtav1 --enable-libvpx --enable-libopus --enable-libmp3lame \
      --enable-libsnappy \
      --disable-ffplay --disable-ffprobe --disable-doc --disable-debug \
      --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" --extra-libs="-lc++ -liconv" \
    && make -j "$JOBS" && make install)
  mark ffmpeg
fi

# --- Flattened pkg-config files for SwiftPM -------------------------------------
# SwiftPM reads Libs/Requires but not their .private variants, which static linking needs.
PC_STATIC="$PREFIX/pkgconfig-static"
rm -rf "$PC_STATIC" && mkdir -p "$PC_STATIC"
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
  awk '
    /^Libs\.private:/ { sub(/^Libs\.private:/, ""); lp = lp " " $0; next }
    /^Requires\.private:/ { sub(/^Requires\.private:/, ""); rp = rp (rp == "" ? "" : ", ") $0; next }
    { lines[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        l = lines[i]
        if (l ~ /^Libs:/) l = l " " lp
        if (l ~ /^Requires:/ && rp != "") { if (l ~ /^Requires:[ \t]*$/) l = "Requires: " rp; else l = l ", " rp }
        print l
      }
      if (rp != "" && !hasreq) {}
    }' "$pc" > "$PC_STATIC/$(basename "$pc")"
  grep -q '^Requires:' "$PC_STATIC/$(basename "$pc")" || true
done

# --- App --------------------------------------------------------------------------
step "Building $APP_NAME against static FFmpeg"
export PKG_CONFIG_LIBDIR="$PC_STATIC"
export PKG_CONFIG_PATH="$PC_STATIC"  # SwiftPM reads PKG_CONFIG_PATH, not PKG_CONFIG_LIBDIR
SCRATCH="$ROOT/.build-release"
swift build -c release --product TinRoofTranscode --scratch-path "$SCRATCH" \
  -Xswiftc -target -Xswiftc "$ARCH-apple-macos$MIN_MACOS" -Xcc -mmacosx-version-min="$MIN_MACOS" \
  -Xlinker -lc++ -Xlinker -liconv
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/TinRoofTranscode"

OUT_DIR="$ROOT/build/release"
APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
SKIP_SWIFT_BUILD=1 BIN="$BIN" OUT="$APP" APP_NAME="$APP_NAME" BUNDLE_ID="$BUNDLE_ID" VERSION="$VERSION" \
  FFMPEG="$PREFIX/bin/ffmpeg" MIN_MACOS="$MIN_MACOS" ./scripts/build_app.sh

# --- Verify self-containment --------------------------------------------------------
step "Checking for external library dependencies"
bad=0
for f in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/bin/ffmpeg"; do
  deps="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' || true)"
  if [ -n "$deps" ]; then echo "error: $f links non-system libraries:"; echo "$deps"; bad=1; fi
  if strings -a "$f" | grep -q "$HOME"; then echo "error: $f contains the home folder path $HOME"; bad=1; fi
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
  echo "$(basename "$f"): minimum macOS $minos"
done
[ $bad -eq 0 ] || exit 1
echo "Encoders: $("$APP/Contents/Resources/bin/ffmpeg" -hide_banner -encoders | awk '{print $2}' | grep -x -E 'libx264|libx265|libsvtav1|libvpx-vp9|hap|prores_ks|dnxhd|cfhd|libopus|libmp3lame' | tr '\n' ' ')"

# --- Sign ---------------------------------------------------------------------------
if [ -n "$DEVELOPER_ID" ]; then
  step "Signing with $DEVELOPER_ID"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Resources/bin/ffmpeg"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  step "No DEVELOPER_ID: ad-hoc signing (for testing only)"
  codesign --force --sign - "$APP/Contents/Resources/bin/ffmpeg"
  codesign --force --sign - "$APP"
fi

# --- DMG ----------------------------------------------------------------------------
step "Creating DMG"
DMG="$OUT_DIR/TinRoof-Transcode-$VERSION.dmg"
STAGE="$OUT_DIR/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    step "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
  else
    echo "warning: NOTARY_PROFILE not set; the DMG is signed but not notarized."
  fi
fi
step "Done: $DMG"
