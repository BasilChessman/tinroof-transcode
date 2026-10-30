#!/bin/sh
# Regenerates docs/screenshots (used by the README and the in-app guide), then rebuilds the
# app so its guide contains the new images. Run before build_release.sh after UI changes.
set -e
cd "$(dirname "$0")/.."
[ -f TestMedia/sample_pal_ac3.mpg ] || ./scripts/make_test_media.sh
./scripts/build_app.sh >/dev/null
TRT_SCREENSHOTS="$PWD/docs/screenshots" TRT_SAMPLE="$PWD/TestMedia/sample_pal_ac3.mpg" \
  "build/TinRoof Transcode.app/Contents/MacOS/TinRoof Transcode" 2>/dev/null | grep -E 'written|check:'
./scripts/build_app.sh
