#!/bin/sh
# Regenerate Resources/AppIcon.iconset and Resources/AppIcon.icns from
# Resources/AppIcon.svg. Requires librsvg (`brew install librsvg`).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT_DIR/Resources/AppIcon.svg"
ICONSET="$ROOT_DIR/Resources/AppIcon.iconset"

command -v rsvg-convert >/dev/null 2>&1 || {
    echo "Install librsvg (rsvg-convert) to render the app icon." >&2
    exit 1
}

mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" -o "$ICONSET/icon_${size}x${size}.png" "$SOURCE"
    double=$((size * 2))
    rsvg-convert -w "$double" -h "$double" -o "$ICONSET/icon_${size}x${size}@2x.png" "$SOURCE"
done

iconutil --convert icns --output "$ROOT_DIR/Resources/AppIcon.icns" "$ICONSET"
echo "Wrote $ROOT_DIR/Resources/AppIcon.icns"
