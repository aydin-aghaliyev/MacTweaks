#!/bin/bash
# Creates a self-signed "MacTweaks Dev" code-signing identity in a project-local keychain.
# A stable signature lets macOS remember Accessibility permission across rebuilds
# (ad-hoc signatures change every build, so the permission would reset each time).
# Your login keychain is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=.signing
KEYCHAIN="$PWD/$DIR/dev.keychain-db"
PASS=mactweaks-dev # protects only this throwaway local keychain
NAME="MacTweaks Dev"

if [ -f "$KEYCHAIN" ]; then echo "Already exists: $KEYCHAIN"; exit 0; fi
mkdir -p "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS"

# create-keychain adds itself to the search list; restore the original list afterwards.
ORIGINAL=$(security list-keychains -d user | xargs)
security create-keychain -p "$PASS" "$KEYCHAIN"
security list-keychains -d user -s $ORIGINAL
security set-keychain-settings "$KEYCHAIN" # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "Created \"$NAME\" in $KEYCHAIN"
