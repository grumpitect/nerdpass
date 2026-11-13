#!/bin/zsh
# Signs an app with the "Nerdative Signing" certificate kept in 1Password (see Tools/setup_signing.sh): reads it with
# the 1Password CLI, loads it into a temporary keychain with a random password, signs, and deletes the keychain.
# The certificate never stays on disk and the login keychain isn't touched.
#
# Usage:  Tools/sign.sh path/to/App.app       (1Password may ask for Touch ID)
#         Tools/sign.sh --check               (exit 0 when the certificate is reachable in 1Password)
set -euo pipefail

REF="op://Private/Nerdative Signing"
IDENTITY="Nerdative Signing"
command -v op >/dev/null || { echo "error: needs the 1Password CLI (brew install 1password-cli)" >&2; exit 1; }
if [ "${1:-}" = "--check" ]; then
  op read "$REF/password" >/dev/null 2>&1
  exit $?
fi
APP="${1:?usage: Tools/sign.sh path/to/App.app}"

WORK=$(mktemp -d)
chmod 700 "$WORK"
KEYCHAIN="$WORK/signing.keychain-db"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

op read --out-file "$WORK/certificate.p12" "$REF/certificate/p12" >/dev/null
P12_PASSWORD=$(op read "$REF/password")
KEYCHAIN_PASSWORD=$(/usr/bin/openssl rand -hex 24)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$WORK/certificate.p12"
# Lets codesign use the key without a prompt (the temporary keychain's own password, not the login password).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

codesign --force --deep --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
