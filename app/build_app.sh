#!/bin/zsh
# Build BVRD.app, sign it, and install it to /Applications.
#
#   ./build_app.sh              build, install, open
#   ./build_app.sh --no-open    build and install
#   ./build_app.sh --no-install build only (make_dmg.sh uses this)
set -euo pipefail

# Name, bundle id, copyright, signing certificate.
APP_NAME="BVRD"
BUNDLE_ID="com.tommy.bvrd"
COPYRIGHT_OWNER="Tommy Wallace"
SIGNING_CERT="Developer ID Application: Thomas Wallace (X8C8U86FTS)"

PYTHON_VERSION="3.12.16"

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$APP_DIR")"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
YEAR="$(date +%Y)"
# /tmp, not Documents. iCloud files make codesign fail. Override with BVRD_BUILD_DIR.
BUILD="${BVRD_BUILD_DIR:-/private/tmp/bvrd-build}"
BUNDLE="$BUILD/$APP_NAME.app"
RUNTIME="$BUILD/runtime/python"
INSTALL_DIR="/Applications"
UV="${UV:-$(command -v uv || echo "$PROJECT_DIR/.bootstrap/bin/uv")}"

echo "Compiling Swift (release)..."
swift build -c release --package-path "$APP_DIR" --arch arm64
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --arch arm64 --show-bin-path)"

# Rebuild Python only when the version or requirements change.
STAMP="$PYTHON_VERSION $(shasum -a 256 "$PROJECT_DIR/engine/requirements.txt" | cut -d' ' -f1)"
if [[ ! -x "$RUNTIME/bin/python3" || "$(cat "$BUILD/runtime/.stamp" 2>/dev/null)" != "$STAMP" ]]; then
    echo "Building the bundled Python runtime ($PYTHON_VERSION)..."
    [[ -x "$UV" ]] || { echo "uv is required: brew install uv"; exit 1; }
    rm -rf "$BUILD/runtime" "$BUILD/python-dist"
    UV_PYTHON_INSTALL_DIR="$BUILD/python-dist" "$UV" python install "$PYTHON_VERSION" --no-bin
    PY_DIST="$(find "$BUILD/python-dist" -maxdepth 1 -type d -name "cpython-$PYTHON_VERSION-macos-aarch64-none" | head -1)"
    mkdir -p "$BUILD/runtime"
    ditto "$PY_DIST" "$RUNTIME"
    rm -rf "$BUILD/python-dist"
    rm -f "$RUNTIME/lib/python3.12/EXTERNALLY-MANAGED"
    "$UV" pip install --python "$RUNTIME/bin/python3" --no-deps --only-binary :all: --no-cache \
        -r "$PROJECT_DIR/engine/requirements.txt"
    "$UV" pip uninstall --python "$RUNTIME/bin/python3" pip >/dev/null 2>&1 || true

    # Drop what the voice engine never uses: tests, Tk, the IDE, headers, docs, extra tools.
    LIB="$RUNTIME/lib/python3.12"
    rm -rf "$LIB"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data,__phello__} \
           "$LIB"/lib-dynload/_tkinter* "$LIB"/site-packages/*/tests "$LIB"/site-packages/scipy/*/tests \
           "$LIB"/site-packages/mlx/{include,lib/cmake,share} \
           "$RUNTIME"/lib/{tcl*,tk*,itcl*,thread*,libtcl*,pkgconfig} "$RUNTIME"/{include,share}
    find "$RUNTIME/bin" -mindepth 1 ! -name python3 ! -name python3.12 -delete
    find "$RUNTIME" -name __pycache__ -type d -prune -exec rm -rf {} +
    echo "$STAMP" > "$BUILD/runtime/.stamp"
fi

echo "Checking licenses..."
NOTICES="$BUILD/THIRD_PARTY_NOTICES.md"
"$RUNTIME/bin/python3" -I "$PROJECT_DIR/tools/check_licenses.py" \
    "$RUNTIME/lib/python3.12/site-packages" "$RUNTIME/lib/python3.12/LICENSE.txt" "$NOTICES"

echo "Assembling $APP_NAME.app..."
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$BUNDLE"
RES="$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$RES/server"
cp "$BIN_DIR/BVRD" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/BVRDPlayer" "$BUNDLE/Contents/Helpers/BVRDPlayer"
cp "$APP_DIR/Resources/AppIcon.icns" "$APP_DIR/Resources/model_manifest.json" "$NOTICES" "$RES/"
sed "s/{{APP_NAME}}/$APP_NAME/g" "$APP_DIR/Resources/Credits.html" > "$RES/Credits.html"
ditto "$RUNTIME" "$RES/python"
cp "$PROJECT_DIR/speakd.py" "$RES/server/"
rsync -a --exclude __pycache__ --exclude requirements.txt "$PROJECT_DIR/engine" "$RES/server/"
# Only voices marked starter in voices.json. Personal clips in that folder stay out.
mkdir -p "$RES/Voices"
"$RUNTIME/bin/python3" -I - "$PROJECT_DIR/voices" "$RES/Voices" <<'PY'
import json, shutil, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
voices = {k: v for k, v in json.loads((src / "voices.json").read_text()).items() if v.get("starter")}
for name in voices:
    shutil.copy2(src / f"{name}.wav", dst)
(dst / "voices.json").write_text(json.dumps(voices, indent=2, ensure_ascii=False))
shutil.copy2(src / "CREDITS.md", dst)
print(f"Bundled {len(voices)} starter voices")
PY
# Precompile so the signed app doesn't write .pyc files later.
"$RES/python/bin/python3" -I -m compileall -q -j 0 "$RES/python/lib/python3.12" "$RES/server" >/dev/null

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$BUILD_NUMBER</string>
    <key>NSHumanReadableCopyright</key>    <string>© $YEAR $COPYRIGHT_OWNER. MIT License.</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# codesign rejects Finder junk and quarantine flags.
xattr -cr "$BUNDLE"

# Libraries, then Python and the player, then the app.
# Hardened runtime and a timestamp are required to notarize.
# Python gets the entitlements so its native libraries can run.
ENTITLEMENTS="$APP_DIR/Resources/entitlements.plist"
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk -v cert="$SIGNING_CERT" 'index($0, cert) {print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
    echo "Signing with $SIGNING_CERT..."
    SIGN_FLAGS=(--options runtime --timestamp)
else
    echo "Signing ad-hoc ($SIGNING_CERT not found; macOS will forget permissions after each rebuild)..."
    SIGN_ID="-"
    SIGN_FLAGS=(--timestamp=none)
fi
sign() { codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$@" 2> >(grep -v "replacing existing signature" >&2); }
find "$RES/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 \
    | xargs -0 -n 40 codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" 2> >(grep -v "replacing existing signature" >&2)
sign --entitlements "$ENTITLEMENTS" "$RES/python/bin/python3.12"
sign "$BUNDLE/Contents/Helpers/BVRDPlayer"
sign --entitlements "$ENTITLEMENTS" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
echo "Built $BUNDLE ($(du -sh "$BUNDLE" | cut -f1))"

[[ "${1:-}" == "--no-install" ]] && exit 0

echo "Installing to $INSTALL_DIR..."
pkill -f "$APP_NAME.app/Contents/Resources/server/speakd.py" 2>/dev/null || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$BUNDLE" "$INSTALL_DIR/$APP_NAME.app"

if [[ "${1:-}" != "--no-open" ]]; then
    open "$INSTALL_DIR/$APP_NAME.app"
fi
echo "Done: $INSTALL_DIR/$APP_NAME.app"
