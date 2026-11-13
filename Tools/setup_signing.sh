#!/bin/zsh
# One-time setup for maintainers: creates the "Nerdative Signing" certificate (self-signed, for code signing, valid
# 10 years) and keeps it only in 1Password: item "Nerdative Signing" in the Private vault, holding the certificate
# (a .p12 file, "p12" in its "certificate" section) and its password. Nothing is left on this Mac; Tools/sign.sh
# loads it into a temporary keychain whenever an app is signed.
#
# Signing every build and release with the same certificate keeps macOS permissions (audio input, Accessibility for
# the volume keys) across updates. Ad hoc signatures change with every build, so macOS forgets them.
#
# Usage:  Tools/setup_signing.sh          (needs the 1Password CLI, `op`, signed in; it asks for Touch ID)
set -euo pipefail

ITEM="Nerdative Signing"
VAULT="Private"
command -v op >/dev/null || { echo "error: needs the 1Password CLI (brew install 1password-cli)"; exit 1; }
if op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1; then
  echo "1Password already has \"$ITEM\" in the $VAULT vault. Nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Nerdative Signing
O = Nerdative
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD=$(/usr/bin/openssl rand -hex 24)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$ITEM" \
  -out "$WORK/certificate.p12" -passout "pass:$PASSWORD" 2>/dev/null

op item create --category=password --title "$ITEM" --vault "$VAULT" \
  "password=$PASSWORD" "certificate.p12[file]=$WORK/certificate.p12" \
  "notesPlain=Code signing certificate for the Nerdative apps (Nerdpass...). Used by Tools/sign.sh. Keep it: a new certificate makes every user re-grant macOS permissions once." \
  >/dev/null
fingerprint=$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)
echo "Saved \"$ITEM\" to 1Password ($VAULT vault). Certificate SHA-1: $fingerprint"
