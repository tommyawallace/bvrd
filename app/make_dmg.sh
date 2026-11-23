#!/bin/zsh
# Build the app and make dist/<name>-<version>.dmg.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$APP_DIR")"
APP_NAME="$(sed -n 's/^APP_NAME="\(.*\)"/\1/p' "$APP_DIR/build_app.sh")"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
BUILD="${BVRD_BUILD_DIR:-/private/tmp/bvrd-build}"
STAGE="$BUILD/dmg"
DIST="$PROJECT_DIR/dist"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
FINAL_DMG="$DIST/$APP_NAME-$VERSION.dmg"
RW_DMG="$BUILD/$APP_NAME-rw.dmg"

"$APP_DIR/build_app.sh" --no-install

echo "Staging disk image..."
rm -rf "$STAGE" "$RW_DMG"
mkdir -p "$STAGE/.background" "$DIST"
ditto "$BUILD/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
sed "s/{{APP_NAME}}/$APP_NAME/g" "$APP_DIR/Resources/How to Open.txt" > "$STAGE/How to Open.txt"
swift "$PROJECT_DIR/tools/dmg_background.swift" "$APP_NAME" "$STAGE/.background/background.png"

hdiutil create -quiet -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ -format UDRW -ov "$RW_DMG"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk -F'\t' '/\/Volumes\// {print $NF}')"

# Icon positions. Needs Terminal permission to control Finder. Without it, the image still works.
osascript <<APPLESCRIPT || echo "Skipped Finder layout (allow Terminal to control Finder for the styled window)."
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {160, 190}
        set position of item "Applications" of container window to {480, 190}
        set position of item "How to Open.txt" of container window to {320, 320}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$MOUNT/$APP_NAME.app" 2>/dev/null || true
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$RW_DMG" "$STAGE"

SIGNING_CERT="$(sed -n 's/^SIGNING_CERT="\(.*\)"/\1/p' "$APP_DIR/build_app.sh")"
NOTARY_PROFILE="bvrd"
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk -v cert="$SIGNING_CERT" 'index($0, cert) {print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
    echo "Signing the disk image..."
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "Notarizing (Apple's check; this can take a few minutes)..."
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "Notarized and stapled."
    else
        echo "Signed with Developer ID, but not notarized."
        echo "Other Macs will ask once the first time you open it, until this is set up:"
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id X8C8U86FTS"
    fi
else
    echo "Developer ID certificate not found. The disk image is only ad-hoc signed."
fi
mkdir -p "$DIST"
cp -X "$DMG" "$FINAL_DMG"
echo "Created $FINAL_DMG ($(du -h "$FINAL_DMG" | cut -f1))"
