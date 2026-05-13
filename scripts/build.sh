#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OmniDrag"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-$APP_NAME}"
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SOURCE_APP_ICON_PNG="$ROOT_DIR/Resources/Assets/DragAppIconSource.png"
ICONSET_DIR="$BUILD_DIR/$APP_NAME.iconset"
STATUS_ICON_TMP="$BUILD_DIR/StatusIcon.template.png"
GENERATED_APP_ICON_ICNS="$BUILD_DIR/$APP_NAME.icns"
GENERATED_STATUS_ICON_PNG="$BUILD_DIR/StatusIcon.png"

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

plutil -lint "$ROOT_DIR/Resources/Info.plist" >/dev/null

if [[ ! -f "$SOURCE_APP_ICON_PNG" ]]; then
  echo "Missing app icon source PNG: $SOURCE_APP_ICON_PNG" >&2
  exit 1
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

APP_ICON_MASTER_PNG="$BUILD_DIR/DragAppIconSource.1024.png"
sips -z 1024 1024 "$SOURCE_APP_ICON_PNG" --out "$APP_ICON_MASTER_PNG" >/dev/null

swift - "$STATUS_ICON_TMP" "$SOURCE_APP_ICON_PNG" <<'SWIFT'
import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
let targetSize = NSSize(width: 128, height: 128)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(targetSize.width),
    pixelsHigh: Int(targetSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = targetSize

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
context.shouldAntialias = true
NSGraphicsContext.current = context

NSColor.clear.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: targetSize)).fill()

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fatalError("Failed to read source image")
}
sourceImage.draw(
    in: NSRect(origin: .zero, size: targetSize),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)

NSGraphicsContext.restoreGraphicsState()

guard let source = rep.cgImage else {
    fatalError("Failed to create status icon image")
}

let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(targetSize.width),
    pixelsHigh: Int(targetSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let width = output.pixelsWide
let height = output.pixelsHigh
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context2 = CGContext(
    data: output.bitmapData,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: output.bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context2.clear(CGRect(x: 0, y: 0, width: width, height: height))
context2.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: source)
context2.setFillColor(CGColor(gray: 0, alpha: 1))
context2.fill(CGRect(x: 0, y: 0, width: width, height: height))

try output.representation(using: .png, properties: [:])!.write(to: outputURL)
SWIFT
cp "$STATUS_ICON_TMP" "$GENERATED_STATUS_ICON_PNG"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP_ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
done
for size in 32 64 256 512 1024; do
  base=$((size / 2))
  sips -z "$size" "$size" "$APP_ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_${base}x${base}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$GENERATED_APP_ICON_ICNS"
rm -f "$APP_ICON_MASTER_PNG"
rm -f "$STATUS_ICON_TMP"

swiftc \
  "$ROOT_DIR"/Sources/*.swift \
  -O \
  -target "$TARGET_ARCH-apple-macos13.0" \
  -sdk "$SDKROOT" \
  -framework AppKit \
  -framework ApplicationServices \
  -o "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$GENERATED_APP_ICON_ICNS" "$RESOURCES_DIR/OmniDrag.icns"
cp "$GENERATED_STATUS_ICON_PNG" "$RESOURCES_DIR/StatusIcon.png"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
file "$MACOS_DIR/$APP_NAME"
lipo -info "$MACOS_DIR/$APP_NAME"
