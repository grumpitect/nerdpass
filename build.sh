#!/bin/zsh
# Runs the tests, builds Nerdpass.app, and installs it (quitting a running copy first): over /Applications/Nerdpass.app
# when one is there (for example from Homebrew), otherwise to ~/Applications.
#
# Usage:
#   ./build.sh
#   SIGN_IDENTITY="My Signing" ./build.sh      (sign with a certificate in your own keychain)
#   NO_1PASSWORD=1 ./build.sh                  (skip the maintainer's 1Password certificate)
#
# Signing: with SIGN_IDENTITY, that identity; otherwise the maintainer's "Nerdative Signing" certificate from
# 1Password when it is reachable (Tools/sign.sh); otherwise ad hoc. A stable certificate keeps macOS permissions
# (audio input, Accessibility for the volume keys) across rebuilds; ad hoc signatures change every build, so macOS
# asks again.
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
elif [ -z "${NO_1PASSWORD:-}" ] && Tools/sign.sh --check 2>/dev/null; then
  Tools/sign.sh "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

DEST=~/Applications; [ -d /Applications/Nerdpass.app ] && DEST=/Applications
mkdir -p "$DEST"
pkill -x "Nerdpass" 2>/dev/null || true
rm -rf "${DEST:?}/Nerdpass.app"
cp -R "$APP" "$DEST/"
echo "installed: $DEST/Nerdpass.app"
