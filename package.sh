#!/bin/bash
# Optional: create a ZIP for transfer after a successful build.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
MAGICTAP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
MAGICTAP_ARCH=$(uname -m)
MAGICTAP_ZIP="$PWD/dist/MagicTap-$MAGICTAP_VERSION-$MAGICTAP_ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent dist/MagicTap.app "$MAGICTAP_ZIP"
printf 'Packaged: %s\n' "$MAGICTAP_ZIP"
