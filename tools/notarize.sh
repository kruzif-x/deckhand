#!/bin/bash
# notarize.sh — build, sign, package and notarise Deckhand.
#
#   ./tools/notarize.sh                                  # uses a keychain profile named "deckhand"
#   ./tools/notarize.sh --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#                       --key-id XXXXXXXXXX --issuer 00000000-0000-0000-0000-000000000000
#
# Notarisation needs ONE of:
#   * App Store Connect API key + its Issuer ID (Users and Access ▸ Integrations ▸ App Store Connect API)
#   * a stored keychain profile:  xcrun notarytool store-credentials deckhand \
#                                   --apple-id you@example.com --team-id S6TR6PN5VQ --password <app-specific>
#
# The app is signed with "Developer ID Application" from build.sh; then the DMG is signed as well, so
# Gatekeeper accepts the download in one step.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Resources/../Deckhand.app/Contents/Info.plist 2>/dev/null || echo "0.1b")
DMG="app/dist/Deckhand-${VERSION}.dmg"
AUTH=()

while [ $# -gt 0 ]; do
    case "$1" in
        --key)     AUTH+=(--key "$2"); shift 2 ;;
        --key-id)  AUTH+=(--key-id "$2"); shift 2 ;;
        --issuer)  AUTH+=(--issuer "$2"); shift 2 ;;
        --profile) AUTH+=(--keychain-profile "$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ ${#AUTH[@]} -gt 0 ] || AUTH=(--keychain-profile deckhand)

echo "→ building and signing the app"
( cd app && ./build.sh >/dev/null )

echo "→ staging the DMG"
STAGE=$(mktemp -d)
cp -R app/Deckhand.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p app/dist
rm -f "$DMG"
hdiutil create -volname "Deckhand ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

SIGN_ID=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
echo "→ signing the DMG as $SIGN_ID"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG" >/dev/null

echo "→ submitting to the notary service (this usually takes a minute or two)"
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait

echo "→ stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "→ Gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo
echo "done: $DMG"
ls -lh "$DMG"
