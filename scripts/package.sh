#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OmniDrag"
APP_VERSION="1.0.1"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
APP_BUNDLE_NAME="${APP_NAME}${TARGET_ARCH:+-${TARGET_ARCH}}"
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  APP_BUNDLE_NAME="$APP_NAME"
fi
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME.app"
PKG_PATH="$DIST_DIR/$APP_NAME-$TARGET_ARCH.pkg"
PKG_ROOT="$BUILD_DIR/pkgroot"
COMPONENT_PLIST="$BUILD_DIR/package-components.plist"

"$ROOT_DIR/scripts/build.sh"
rm -f "$PKG_PATH"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
ditto "$APP_DIR" "$PKG_ROOT/Applications/$APP_BUNDLE_NAME.app"

cat > "$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key>
        <string>Applications/$APP_BUNDLE_NAME.app</string>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
    </dict>
</array>
</plist>
EOF

pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --install-location "/" \
  --identifier "com.omnidrag.pkg" \
  --version "$APP_VERSION" \
  "$PKG_PATH" >/dev/null

echo "Packaged $PKG_PATH"
