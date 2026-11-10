#!/bin/zsh
# Builds DemoImages.app (release, universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"

NAME=DemoImages
APP=build/$NAME.app
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
# Universal builds need full Xcode (xcbuild); with only the Command Line Tools,
# build for this Mac's architecture.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode not found: building for $(uname -m) only"
    ARCH_FLAGS=()
fi
swift build -c release "${ARCH_FLAGS[@]}"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$NAME

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# Icon source: Icon/AppIcon.html, rendered by scripts/make-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.egluu.demoimages</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.image</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.movie</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd build && rm -f $NAME.zip && ditto -c -k --keepParent $NAME.app $NAME.zip)
echo "Built $APP ($VERSION) and build/$NAME.zip"
