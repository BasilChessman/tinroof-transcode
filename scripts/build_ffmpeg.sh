#!/bin/sh
# Builds an ffmpeg with the encoders Homebrew's build lacks — notably Hap / Hap Alpha / Hap Q
# (needs libsnappy) — and installs it into vendor/ffmpeg.
#
#   ./scripts/build_ffmpeg.sh            # then: FFMPEG=vendor/ffmpeg/bin/ffmpeg ./scripts/build_app.sh
#
# The result links Homebrew's shared libraries, so it runs on Macs that have the same
# Homebrew packages. For distribution, build the dependencies statically.
#
# NotchLC: ffmpeg can only decode it (no open-source encoder exists), so it is supported
# for opening and converting from, not as an export codec.
set -e
cd "$(dirname "$0")/.."
VER="${FFMPEG_VERSION:-$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}' | sed 's/-.*//')}"
VER="${VER:-8.0}"
PREFIX="$(pwd)/vendor/ffmpeg"
SRC="vendor/src/ffmpeg-$VER"

brew list snappy >/dev/null 2>&1 || brew install snappy
for p in x264 x265 lame opus libvpx svt-av1 pkg-config nasm; do brew list $p >/dev/null 2>&1 || brew install $p; done

mkdir -p vendor/src
if [ ! -d "$SRC" ]; then
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "vendor/src/ffmpeg-$VER.tar.xz"
  tar -xf "vendor/src/ffmpeg-$VER.tar.xz" -C vendor/src
fi

BREW="$(brew --prefix)"
cd "$SRC"
./configure --prefix="$PREFIX" \
  --enable-gpl --enable-version3 \
  --enable-libsnappy --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus \
  --enable-libvpx --enable-libsvtav1 \
  --enable-videotoolbox --enable-audiotoolbox \
  --disable-ffplay --disable-doc --disable-debug \
  --extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib"
make -j"$(sysctl -n hw.ncpu)"
make install
"$PREFIX/bin/ffmpeg" -hide_banner -encoders | grep -E ' hap ' && echo "Hap encoder available: $PREFIX/bin/ffmpeg"
