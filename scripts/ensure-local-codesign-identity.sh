#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${VIRTUALHID_CODESIGN_IDENTITY:-VirtualHID Local Code Signing}"
KEYCHAIN="${VIRTUALHID_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASSWORD="${VIRTUALHID_CODESIGN_P12_PASSWORD:-virtualhid-local-codesign}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
  echo "$IDENTITY"
  exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virtualhid-codesign.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

OPENSSL_CONFIG="$WORK_DIR/openssl.cnf"
cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[ req_distinguished_name ]
CN = $IDENTITY

[ v3_codesign ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -config "$OPENSSL_CONFIG" \
  -keyout "$WORK_DIR/codesign.key" \
  -out "$WORK_DIR/codesign.crt" >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -legacy \
  -inkey "$WORK_DIR/codesign.key" \
  -in "$WORK_DIR/codesign.crt" \
  -name "$IDENTITY" \
  -out "$WORK_DIR/codesign.p12" \
  -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

security import "$WORK_DIR/codesign.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$WORK_DIR/codesign.crt" >/dev/null

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "\"$IDENTITY\""; then
  echo "failed to create valid local code signing identity: $IDENTITY" >&2
  exit 1
fi

echo "$IDENTITY"
