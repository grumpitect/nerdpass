#!/bin/bash
# Installs or updates Nerdpass from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/grumpitect/nerdpass/main/install.sh | bash
#
# Downloads the release zip, checks its SHA-256 against the one published in the release notes, quits a running
# Nerdpass, replaces the app where it is already installed (otherwise /Applications, or ~/Applications when
# /Applications is not writable) and opens it. Set NERDPASS_APP_DIR to choose the folder, NERDPASS_NO_OPEN=1 to
# skip opening it. Only uses tools that ship with macOS.
set -euo pipefail

REPO="grumpitect/nerdpass"
say() { printf '\033[1;35mnerdpass\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Nerdpass is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Nerdpass needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "finding the latest release..."
curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" -o "$work/release.json" \
  || fail "couldn't reach GitHub."
json() { plutil -extract "$1" raw -o - "$work/release.json" 2>/dev/null; }
tag=$(json tag_name) || fail "couldn't read the release information."
url=""
for i in 0 1 2 3 4 5 6 7 8 9; do
  name=$(json "assets.$i.name") || break
  case "$name" in Nerdpass-*.zip) url=$(json "assets.$i.browser_download_url"); break ;; esac
done
[ -n "$url" ] || fail "release $tag has no Nerdpass zip."
expected=$(json body | sed -n 's/.*SHA-256: `\([0-9a-f]\{64\}\)`.*/\1/p' | head -1)
[ -n "$expected" ] || fail "release $tag has no published SHA-256."

say "downloading $tag..."
curl -fL --progress-bar "$url" -o "$work/Nerdpass.zip"
actual=$(shasum -a 256 "$work/Nerdpass.zip" | cut -d' ' -f1)
[ "$actual" = "$expected" ] || fail "checksum mismatch (expected $expected, got $actual). Nothing was installed."
ditto -x -k "$work/Nerdpass.zip" "$work/unzipped"
[ -d "$work/unzipped/Nerdpass.app" ] || fail "the zip doesn't contain Nerdpass.app."

# Where to install: an explicit choice, else where it already is, else /Applications (or ~/Applications).
if [ -n "${NERDPASS_APP_DIR:-}" ]; then dir="$NERDPASS_APP_DIR"
elif [ -d "/Applications/Nerdpass.app" ]; then dir="/Applications"
elif [ -d "$HOME/Applications/Nerdpass.app" ]; then dir="$HOME/Applications"
elif [ -w "/Applications" ]; then dir="/Applications"
else dir="$HOME/Applications"
fi
mkdir -p "$dir"

# Quit Nerdpass only if the copy being replaced is the one running.
target="$(cd "$dir" && pwd -P)/Nerdpass.app/Contents/MacOS/Nerdpass"
for pid in $(pgrep -x Nerdpass || true); do
  running=$(ps -o comm= -p "$pid" 2>/dev/null || true)
  [ -n "$running" ] && [ "$(cd "$(dirname "$running")" 2>/dev/null && pwd -P)/Nerdpass" = "$target" ] || continue
  say "quitting the running Nerdpass..."
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
done

rm -rf "${dir:?}/Nerdpass.app.new"
ditto "$work/unzipped/Nerdpass.app" "$dir/Nerdpass.app.new"
rm -rf "${dir:?}/Nerdpass.app"
mv "$dir/Nerdpass.app.new" "$dir/Nerdpass.app"
say "installed $tag in $dir/Nerdpass.app"

if [ -z "${NERDPASS_NO_OPEN:-}" ]; then
  open "$dir/Nerdpass.app"
  say "it's in your menu bar: click it and press start()."
fi
