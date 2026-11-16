#!/bin/bash
# Signs the app bundle with the local "MacTweaks Dev" identity, or ad-hoc if it doesn't exist.
# The certificate is self-signed (untrusted), so codesign only finds it by hash and only
# while its keychain is in the search list; the list is restored right after signing.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$1
KEYCHAIN="$PWD/.signing/dev.keychain-db"

if [ ! -f "$KEYCHAIN" ]; then
    echo "warning: no signing identity (run 'make signing'); ad-hoc signing, Accessibility permission resets each build"
    exec codesign --force --sign - "$APP"
fi

security unlock-keychain -p mactweaks-dev "$KEYCHAIN"
HASH=$(security find-identity "$KEYCHAIN" | awk '/"MacTweaks Dev"/ { print $2; exit }')

ORIGINAL=$(security list-keychains -d user | xargs)
trap 'security list-keychains -d user -s $ORIGINAL' EXIT
security list-keychains -d user -s $ORIGINAL "$KEYCHAIN"
codesign --force --sign "$HASH" "$APP"
