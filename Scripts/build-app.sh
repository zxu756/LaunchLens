#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RENDER_DOCS_SCREENSHOTS=0
for arg in "$@"; do
    case "$arg" in
        --render-docs-screenshots)
            RENDER_DOCS_SCREENSHOTS=1
            ;;
        *)
            echo "Error: Unknown option '$arg' (supported: --render-docs-screenshots)" >&2
            exit 2
            ;;
    esac
done

APP_NAME="LaunchLens"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICONSET="$BUILD_DIR/AppIcon.iconset"

echo "==> Building $APP_NAME (release, arm64, macOS 14.0+)..."
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE" "$ICONSET"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Generating AppIcon.icns..."
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Ad-hoc signing & verifying..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$RENDER_DOCS_SCREENSHOTS" -eq 1 || "${LAUNCHLENS_RENDER_DOCS_SCREENSHOTS:-0}" == "1" ]]; then
    mkdir -p "$ROOT/docs"
    echo "==> Rendering 2x Retina screenshots (EN + zh-Hans) to docs/..."
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --export-screenshots "$ROOT/docs" --lang en
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --export-screenshots "$ROOT/docs" --lang zh
fi

echo "✓ Built $APP_BUNDLE"
