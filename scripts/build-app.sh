#!/bin/bash
# Builds Buoy.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh            # release build → build/Buoy.app
#   scripts/build-app.sh --install  # …and copy it to /Applications
#   scripts/build-app.sh --run      # …and launch it
#
# Release builds store data in ~/Library/Application Support/Buoy.
# Debug builds (`swift run Buoy`) use ~/Library/Application Support/Buoy-Dev,
# so development never touches your real tasks.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

SDK_ARGS=()
if [[ -n "${BUOY_SDK:-}" ]]; then
  SDK_ARGS=(--sdk "$BUOY_SDK")
fi

echo "==> Building (release)..."
swift build -c release --product Buoy ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${SDK_ARGS[@]+"${SDK_ARGS[@]}"})"

APP="build/Buoy.app"
echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Buoy" "$APP/Contents/MacOS/Buoy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> Generating app icon..."
  scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad hoc)..."
codesign --force --sign - --timestamp=none "$APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "==> Installing to /Applications..."
  if pgrep -x Buoy >/dev/null; then
    osascript -e 'tell application "Buoy" to quit' || true
    sleep 1
  fi
  rm -rf /Applications/Buoy.app
  cp -R "$APP" /Applications/Buoy.app
  APP="/Applications/Buoy.app"
fi

echo "Built ${APP}"

if [[ $RUN -eq 1 ]]; then
  open "$APP"
fi
