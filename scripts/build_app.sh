#!/bin/sh
# Builds the application bundle.
#
#   APP_NAME="TinRoof Transcode" BUNDLE_ID=com.tinroof.transcode ./scripts/build_app.sh
#
# Options (environment):
#   APP_NAME     Display name of the app (default: TinRoof Transcode).
#   BUNDLE_ID    Bundle identifier.
#   VERSION      Short version string.
#   FFMPEG       Path to an ffmpeg binary to copy into the bundle (optional).
#                Without it the app uses ffmpeg from Homebrew or the path set in Settings.
set -e
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-TinRoof Transcode}"
BUNDLE_ID="${BUNDLE_ID:-com.tinroof.transcode}"
VERSION="${VERSION:-0.1.1}"
OUT="${OUT:-build/${APP_NAME}.app}"
MIN_MACOS="${MIN_MACOS:-14.0}"

# build_release.sh builds the binary itself and passes it in BIN.
if [ -z "$SKIP_SWIFT_BUILD" ]; then
  swift build -c release --product TinRoofTranscode
  BIN="$(swift build -c release --show-bin-path)/TinRoofTranscode"
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"
# Illustrated guide: HTML from Resources/Guide, screenshots from docs/screenshots.
mkdir -p "$OUT/Contents/Resources/Guide/images"
cp Resources/Guide/*.html Resources/Guide/*.css "$OUT/Contents/Resources/Guide/"
cp docs/screenshots/*.png "$OUT/Contents/Resources/Guide/images/"
sips -z 256 256 Resources/AppIcon-1024.png --out "$OUT/Contents/Resources/Guide/images/icon.png" >/dev/null
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
if [ -n "$FFMPEG" ]; then
  mkdir -p "$OUT/Contents/Resources/bin"
  cp "$FFMPEG" "$OUT/Contents/Resources/bin/ffmpeg"
fi

doc_type() { # name, role, extensions...
  name="$1"; role="$2"; shift 2
  printf '    <dict>\n      <key>CFBundleTypeName</key><string>%s</string>\n      <key>CFBundleTypeRole</key><string>%s</string>\n      <key>LSHandlerRank</key><string>Alternate</string>\n      <key>CFBundleTypeExtensions</key>\n      <array>' "$name" "$role"
  for e in "$@"; do printf '<string>%s</string>' "$e"; done
  printf '</array>\n    </dict>\n'
}

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
$(doc_type "MPEG Transport Stream" Editor ts m2t mts m2ts mmv rec vid aud avr tp tp0 trp tod)
$(doc_type "MPEG Program Stream" Editor mpg mpeg ps vob vro dat m2p mod dcm)
$(doc_type "MPEG Elementary Stream" Editor m2v m1v mpv)
$(doc_type "MPEG Packetized Stream" Editor pvr vdr)
$(doc_type "Movie" Editor mov dv avi mp4 m4v divx mkv webm wmv asf flv 3gp mxf ogv)
$(doc_type "Audio" Viewer aiff aif m1a m2a mp2 mpa ac3 mp3 wav m4a flac)
$(doc_type "Picture" Viewer jpeg jpg tiff tif png)
  </array>
</dict>
</plist>
EOF

[ -n "$SKIP_SWIFT_BUILD" ] || codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
echo "Built $OUT"
