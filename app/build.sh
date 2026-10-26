#!/bin/bash
# Build Deckhand.app — a self-contained native app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Deckhand.app"

echo "→ building (release)"
swift build -c release 2>&1 | grep -E "error:|warning: " | grep -v "^$" || true
BIN=".build/release/Deckhand"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Deckhand"
cp ".build/release/StreamDockMCP" "$APP/Contents/MacOS/deckhand-mcp"
if [ -f "Resources/AppIcon.icns" ]; then cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Deckhand</string>
    <key>CFBundleDisplayName</key><string>Deckhand</string>
    <key>CFBundleExecutable</key><string>Deckhand</string>
    <key>CFBundleIdentifier</key><string>com.rolandchia.deckhand</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string><string>ms</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.rolandchia.deckhand.profile</string>
            <key>UTTypeDescription</key><string>Deckhand Profile</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>sdprofile</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Deckhand Profile</string>
            <key>LSItemContentTypes</key><array><string>com.rolandchia.deckhand.profile</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key><string>Independent implementation. No vendor code executed beyond the MIT-licensed HID transport.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the Accessibility grant across rebuilds; ad-hoc signing
# produces a new cdhash every build, so macOS silently drops the previous grant.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$SIGN_ID" ]; then
    echo "→ signing as: $SIGN_ID"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP" \
        2>&1 | grep -v "replacing existing signature" || true
else
    echo "→ signing (ad-hoc — Accessibility must be re-granted after every build)"
    codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo
echo "built: $(pwd)/$APP"
echo "run:   open $APP      (or ./$APP/Contents/MacOS/Deckhand for console output)"
