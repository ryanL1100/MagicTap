#!/bin/bash
# Build a local app bundle. Does not install, launch, or alter system permissions.
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "MagicTap requires macOS and the Xcode command line tools." >&2
  exit 1
fi
xcrun --find clang >/dev/null
xcrun --find swiftc >/dev/null
MAGICTAP_ARCH=$(uname -m)
MAGICTAP_MIN_OS=14.0
MAGICTAP_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/magictap-build.XXXXXX")
trap 'rm -rf "$MAGICTAP_BUILD_DIR"' EXIT
MAGICTAP_APP="$PWD/dist/MagicTap.app"
mkdir -p "$MAGICTAP_APP/Contents/MacOS" "$MAGICTAP_APP/Contents/Resources"
xcrun clang -O2 -Wall -Wextra -arch "$MAGICTAP_ARCH" -mmacosx-version-min="$MAGICTAP_MIN_OS" \
  -c Sources/TouchBridge.c -o "$MAGICTAP_BUILD_DIR/TouchBridge.o"
xcrun swiftc -O -swift-version 5 -target "$MAGICTAP_ARCH-apple-macosx$MAGICTAP_MIN_OS" \
  -import-objc-header Sources/TouchBridge.h \
  Sources/TapRecognizer.swift Sources/TrackpadRecognizer.swift Sources/SystemActions.swift Sources/MagicTap.swift \
  "$MAGICTAP_BUILD_DIR/TouchBridge.o" \
  -framework SwiftUI -framework AppKit -framework ApplicationServices \
  -framework IOKit -framework CoreFoundation -framework CoreAudio \
  -o "$MAGICTAP_APP/Contents/MacOS/MagicTap"
cp Resources/Info.plist "$MAGICTAP_APP/Contents/Info.plist"
plutil -lint "$MAGICTAP_APP/Contents/Info.plist"
codesign --force --sign "${MAGICTAP_SIGN_IDENTITY:--}" "$MAGICTAP_APP"
codesign --verify --deep --strict "$MAGICTAP_APP"
"$MAGICTAP_APP/Contents/MacOS/MagicTap" --self-test
printf 'Built: %s\n' "$MAGICTAP_APP"
