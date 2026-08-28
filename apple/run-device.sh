#!/bin/bash
# Build, install and launch on a connected device WITHOUT the debugger.
#
# Xcode's Run attaches LLDB, which on a device resolves symbols by reading
# device memory and shows the "taking longer than expected" dialog. For simply
# seeing whether a change works, that wait buys nothing. This path skips it and
# takes about 7 seconds warm. The FIRST run builds everything for the device
# from scratch and takes several minutes; that cost is paid once.
#
# Use Xcode's Run when you actually need breakpoints.
set -euo pipefail

SCHEME="${1:-CascadeiOS}"
BUNDLE="${2:-xyz.chaosinc.cascade.ios}"
DERIVED="/tmp/cascade-devicebuild"

# Matched on the UUID rather than by column, because device names contain
# spaces and shift every column after them.
DEVICE=$(xcrun devicectl list devices 2>/dev/null \
  | grep connected \
  | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
  | head -1)
if [ -z "$DEVICE" ]; then
  echo "No connected device. Plug one in, or trust this Mac on it." >&2
  exit 1
fi

xcodebuild -project Cascade.xcodeproj -scheme "$SCHEME" \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build -quiet

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -print -quit)
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE"
