#!/usr/bin/env bash
#
# flash-watch.sh — the ONE correct way to get a watch (or phone) build onto the device.
#
# Why this exists: every Pinch build is version 1.0 (1), so a flash is otherwise invisible —
# you cannot tell a fresh binary from a stale one. Combined with (a) the wrong default Xcode
# (`xcode-select` points at the stable Xcode, but an OS-27 watch can ONLY be installed to with
# the Xcode 27 beta's developer disk image) and (b) several stray DerivedData trees you might
# install from by accident, it is very easy to "flash" and ship old code. This script removes
# all three traps: it forces the beta toolchain, uses ONE build path, installs from exactly
# what it just built, and prints the build stamp it shipped so you can confirm it in
# Settings → Build on the device. If the on-device stamp matches, the new code is really there.
#
# Usage:
#   infra/flash-watch.sh            # watch (default)
#   infra/flash-watch.sh phone      # iPhone
#   infra/flash-watch.sh watch --clean   # uninstall first (wipes pairing/UserDefaults), then install
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
XC="/Users/josh/Downloads/Xcode-beta.app/Contents/Developer"   # the only toolchain with the OS-27 DDI

# Device identifiers (from `xcrun devicectl list devices`). The xcodebuild -destination uses the
# hardware UDID; devicectl uses its own coredevice id.
WATCH_BUILD_ID="00008310-000F33C43E10E01E"
WATCH_CTL_ID="742C6676-C376-5C2C-9026-8B49C52EEFA0"
PHONE_BUILD_ID="86CBC7C2-4D90-5695-9AC7-C650208AB738"          # devicectl id == build id for the phone
PHONE_CTL_ID="86CBC7C2-4D90-5695-9AC7-C650208AB738"

TARGET="${1:-watch}"
CLEAN=0
for a in "$@"; do [ "$a" = "--clean" ] && CLEAN=1; done

case "$TARGET" in
  watch)
    SCHEME="Pinch"; BUNDLE="com.joshua.kappler.pinch.watch"
    DESTID="$WATCH_BUILD_ID"; CTLID="$WATCH_CTL_ID"; PRODSUBDIR="Debug-watchos" ;;
  phone)
    SCHEME="PinchPhone"; BUNDLE="com.joshua.kappler.pinch.phone"
    DESTID="$PHONE_BUILD_ID"; CTLID="$PHONE_CTL_ID"; PRODSUBDIR="Debug-iphoneos" ;;
  *) echo "✗ unknown target '$TARGET' (use: watch | phone)"; exit 2 ;;
esac

DD="/tmp/pinch-flash-dd"
APP="$DD/Build/Products/$PRODSUBDIR/$SCHEME.app"

[ -d "$XC" ] || { echo "✗ Xcode 27 beta not found at $XC — install it / fix the path."; exit 1; }
[ -d "$REPO/watch/Pinch.xcodeproj" ] || { echo "✗ watch/Pinch.xcodeproj missing — run: (cd watch && xcodegen generate)"; exit 1; }

echo "▶ Building $SCHEME with Xcode 27 beta → $DD"
DEVELOPER_DIR="$XC" xcodebuild \
  -project "$REPO/watch/Pinch.xcodeproj" -scheme "$SCHEME" \
  -destination "id=$DESTID" -configuration Debug \
  -derivedDataPath "$DD" -allowProvisioningUpdates \
  build | grep -iE 'BuildStamp ->|BUILD (SUCCEEDED|FAILED)|error:' || true

[ -d "$APP" ] || { echo "✗ build produced no app at $APP — build failed, see output above."; exit 1; }

# The stamp that got compiled in is whatever the preBuildScript just wrote to this file.
SHIPPED="$(sed -n 's/.*static let value = "\(.*\)".*/\1/p' "$REPO/watch/Sources/Shared/BuildStamp.swift")"

if [ "$CLEAN" = "1" ]; then
  echo "▶ Uninstalling $BUNDLE (--clean: wipes its UserDefaults/pairing)"
  DEVELOPER_DIR="$XC" xcrun devicectl device uninstall app --device "$CTLID" "$BUNDLE" || true
fi

echo "▶ Installing → device $CTLID"
DEVELOPER_DIR="$XC" xcrun devicectl device install app --device "$CTLID" "$APP"

echo
echo "✅ Flashed $SCHEME. Now open Settings → Build on the device. It MUST read:"
echo
echo "        $SHIPPED"
echo
echo "   If it shows anything else, the new code did NOT land — re-run with --clean."
