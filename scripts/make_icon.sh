#!/bin/sh
# Builds Resources/AppIcon.icns from the artwork in Resources/AppIcon-source.png.
# To change the icon, replace AppIcon-source.png (square, ideally 1024 px or larger) and run this.
set -e
cd "$(dirname "$0")/.."
swift scripts/prepare_icon.swift Resources/AppIcon-source.png Resources/AppIcon-1024.png
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "Built Resources/AppIcon.icns"
