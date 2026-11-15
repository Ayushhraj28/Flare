#!/bin/bash
# Builds dist/Flare.app from the Swift package. Needs only the Xcode command-line tools.
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "› Building Flare ($CONFIG)…"
swift build -c "$CONFIG" --product Flare 2>&1 | grep -v "ld: warning: search path" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Flare"
[ -x "$BIN" ] || { echo "Build failed: $BIN not found" >&2; exit 1; }

# The icon comes from Scripts/AppIcon-1024.png (the Flare mark on a dark titanium plate).
# Rebuilt whenever the artwork is newer than the .icns.
if [ -f Scripts/AppIcon-1024.png ] && { [ ! -f Scripts/AppIcon.icns ] || [ Scripts/AppIcon-1024.png -nt Scripts/AppIcon.icns ]; }; then
  echo "› Rendering icon…"
  ICONSET=Scripts/AppIcon.iconset
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" Scripts/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" Scripts/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Scripts/AppIcon.icns
  rm -rf "$ICONSET"
fi

APP="dist/Flare.app"
rm -rf "$APP" dist/Gauntlet.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flare"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate when there is one: macOS then recognises every
# rebuild as the same app, so the Accessibility permission survives. The bundle identifier is
# still dev.sunhacks.gauntlet, so permissions granted to Gauntlet carry over to Flare.
# The signed copy goes to ~/Applications, because folders synced by iCloud (such as Desktop)
# attach Finder metadata that codesign rejects.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  INSTALLED="$HOME/Applications/Flare.app"
  mkdir -p "$HOME/Applications"
  pkill -x Flare 2>/dev/null || true
  pkill -x Gauntlet 2>/dev/null || true
  rm -rf "$INSTALLED" "$HOME/Applications/Gauntlet.app"   # the app was called Gauntlet before
  ditto --norsrc --noextattr --noqtn "$APP" "$INSTALLED"
  xattr -cr "$INSTALLED"
  codesign --force --sign "$IDENTITY" --identifier dev.sunhacks.gauntlet "$INSTALLED"
  rm -rf "$APP"         # keep exactly one Flare on disk, so macOS permissions never point at a stale copy
  echo "✓ Installed and signed $INSTALLED (permissions persist across rebuilds)"
  echo "  Run it:  open \"$INSTALLED\""
else
  codesign --force --sign - --identifier dev.sunhacks.gauntlet "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "✓ Built $APP (ad-hoc signed: re-grant Accessibility after each rebuild)"
  echo "  Run it:  open $APP"
fi
