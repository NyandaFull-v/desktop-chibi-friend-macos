#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
APP_NAME="デスクトップちびフレンド"
BUNDLE="$ROOT/dist/$APP_NAME.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

if swift build -c release --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  echo "Apple Silicon / Intel 共用版を作成しました。"
else
  echo "共用版を作れない環境のため、このMac用として作成します。"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

cp "$BIN_DIR/DesktopChibiFriendMac" "$BUNDLE/Contents/MacOS/DesktopChibiFriendMac"
cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"
ditto "$ROOT/Resources" "$BUNDLE/Contents/Resources"
chmod +x "$BUNDLE/Contents/MacOS/DesktopChibiFriendMac"
codesign --force --deep --sign - "$BUNDLE"

rm -f "$ROOT/dist/${APP_NAME}_v0.4.1-mac.zip"
ditto -c -k --keepParent "$BUNDLE" "$ROOT/dist/${APP_NAME}_v0.4.1-mac.zip"
echo
echo "完成: $BUNDLE"
echo "配布ZIP: $ROOT/dist/${APP_NAME}_v0.4.1-mac.zip"
