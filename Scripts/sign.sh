#!/usr/bin/env bash
set -euo pipefail

# Signs FlipNinja.app with a stable local identity. A stable certificate keeps
# the Accessibility (TCC) grant alive across rebuilds, because the designated
# requirement is tied to the certificate rather than the binary's cdhash.
#
# Usage: Scripts/sign.sh <path-to-app>

APP="${1:?usage: sign.sh <path-to-app>}"
[ -d "$APP" ] || { echo "not an app bundle: $APP"; exit 1; }

SIGN_ID="FlipNinja Development Signing"
SIGN_DIR="$HOME/.flipninja"
KEYCHAIN="$SIGN_DIR/flipninja.keychain-db"
KEYCHAIN_PASS="flipninja"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_openssl() {
    if [ -x "/opt/homebrew/bin/openssl" ]; then
        echo "/opt/homebrew/bin/openssl"
    elif [ -x "/usr/local/opt/openssl/bin/openssl" ]; then
        echo "/usr/local/opt/openssl/bin/openssl"
    elif command -v openssl >/dev/null 2>&1; then
        echo "openssl"
    else
        echo ""
    fi
}

set_user_trust() {
    swift "$ROOT/Scripts/trust_signing_cert.swift" "$SIGN_DIR/signing.der"
}

ensure_signing_identity() {
    # Already usable? (cert present in keychain AND trusted in user domain)
    if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; then
        return 0
    fi

    # Cert exists but lost trust? Re-apply the user-domain trust.
    if security find-certificate -c "$SIGN_ID" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "==> Re-applying trust for $SIGN_ID..."
        security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
        set_user_trust
        return 0
    fi

    local openssl_cmd
    openssl_cmd="$(find_openssl)"
    if [ -z "$openssl_cmd" ]; then
        echo "    openssl not found; cannot create a stable signing identity."
        return 1
    fi

    echo "==> Creating stable self-signed signing identity (one-time)..."
    mkdir -p "$SIGN_DIR"
    local key="$SIGN_DIR/signing.key"
    local crt="$SIGN_DIR/signing.crt"
    local der="$SIGN_DIR/signing.der"
    local p12="$SIGN_DIR/signing.p12"

    rm -f "$key" "$crt" "$der" "$p12"
    "$openssl_cmd" req -x509 -newkey rsa:2048 -sha256 -nodes \
        -keyout "$key" -out "$crt" -days 3650 \
        -subj "/CN=$SIGN_ID" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=critical,digitalSignature" 2>/dev/null
    "$openssl_cmd" pkcs12 -export -legacy -inkey "$key" -in "$crt" \
        -out "$p12" -passout "pass:$KEYCHAIN_PASS" 2>/dev/null
    "$openssl_cmd" x509 -in "$crt" -outform der -out "$der"

    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

    rm -f "$p12"
    set_user_trust
    echo "    signing identity ready."
}

echo "==> Code signing..."
if ensure_signing_identity; then
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    codesign --force --timestamp=none --sign "$SIGN_ID" --keychain "$KEYCHAIN" "$APP"
else
    echo "==> Falling back to ad-hoc signature."
    codesign --force --sign - "$APP"
fi
