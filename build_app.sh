#!/bin/bash
# PixView.app 을 build/ 아래에 만든다. (맥에서 실행, Xcode 또는 Command Line Tools 필요)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/PixView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PixView "$APP/Contents/MacOS/PixView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "완료: $APP  (Applications 폴더로 옮겨서 사용하세요)"
