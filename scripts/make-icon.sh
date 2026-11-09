#!/bin/zsh
# Renders Icon/AppIcon.html with headless Chrome and builds Resources/AppIcon.icns.
# Needs Google Chrome and network access (the DEMO label uses JetBrains Mono from Google Fonts).
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$work/profile" \
    --default-background-color=00000000 --force-device-scale-factor=1 \
    --window-size=1024,1024 --virtual-time-budget=5000 \
    --screenshot="$work/icon_1024.png" "file://$PWD/Icon/AppIcon.html" >/dev/null 2>&1

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
cp "$work/icon_1024.png" Icon/AppIcon-1024.png
echo "Wrote Resources/AppIcon.icns and Icon/AppIcon-1024.png"
