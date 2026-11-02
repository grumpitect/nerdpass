#!/bin/zsh
# Runs the tests, builds Nerdpass.app, and installs it (quitting a running copy first): over /Applications/Nerdpass.app
# when one is there (for example from Homebrew), otherwise to ~/Applications.
#
# Usage:
#   ./build.sh
#   SIGN_IDENTITY="Nerdpass Signing" ./build.sh
#
# Set SIGN_IDENTITY to a code signing identity (a free self-signed certificate is enough) so macOS keeps
# Nerdpass's audio input access across rebuilds. Without it the app is signed ad hoc, and macOS asks for that
# access again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

# Build caches live in ~/Library/Caches (macOS empties $TMPDIR now and then).
CACHE="$HOME/Library/Caches/Nerdpass-build"
SCRATCH="$CACHE/swiftpm"
swift test --scratch-path "$SCRATCH" 2>&1 | grep -E "error: |Executed [0-9]+ tests" | tail -3
swift build -c release --product App --scratch-path "$SCRATCH" 2>&1 | grep -E "error|Build complete" | tail -2

BUILD="$CACHE/app"
APP="$BUILD/Nerdpass.app"
rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/App" "$APP/Contents/MacOS/Nerdpass"
cp Info.plist "$APP/Contents/Info.plist"
# Build number = number of commits, so every installed build is unique and increasing (repo files untouched).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 0)" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

DEST=~/Applications; [ -d /Applications/Nerdpass.app ] && DEST=/Applications
mkdir -p "$DEST"
pkill -x "Nerdpass" 2>/dev/null || true
rm -rf "${DEST:?}/Nerdpass.app"
cp -R "$APP" "$DEST/"
echo "installed: $DEST/Nerdpass.app"
