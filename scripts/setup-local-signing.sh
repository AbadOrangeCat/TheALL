#!/bin/bash
# Create a stable, local-only Debug signing identity. No trust settings change.
set -euo pipefail
umask 077

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "$project_dir/Local.xcconfig" ]; then
    echo 'Local.xcconfig already exists; preserve it and configure signing manually.' >&2
    exit 1
fi
signing_tmp="$(mktemp -d "${TMPDIR:-/tmp}/theall-signing.XXXXXX")"
trap 'rm -rf "$signing_tmp"' EXIT
login_keychain="$HOME/Library/Keychains/login.keychain-db"
identity_name="TheAll Local Development $(date +%Y%m%d%H%M%S)"

cat > "$signing_tmp/openssl.cnf" <<EOF
[req]
prompt = no
distinguished_name = identity
x509_extensions = signing
[identity]
CN = $identity_name
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
    -config "$signing_tmp/openssl.cnf" -keyout "$signing_tmp/key.pem" \
    -out "$signing_tmp/cert.pem" 2>"$signing_tmp/openssl.log"
import_password="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -inkey "$signing_tmp/key.pem" -in "$signing_tmp/cert.pem" \
    -name "$identity_name" -out "$signing_tmp/identity.p12" -passout stdin <<< "$import_password"
/usr/bin/security import "$signing_tmp/identity.p12" -k "$login_keychain" -P "$import_password" -T /usr/bin/codesign
unset import_password
identity_sha="$(/usr/bin/openssl x509 -in "$signing_tmp/cert.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"

cat > "$project_dir/Local.xcconfig" <<EOF
// Local development only. Keep this certificate across Debug rebuilds.
// Imported in login Keychain; no system/user trust settings were changed.
THEALL_CODE_SIGN_STYLE[config=Debug] = Manual
CODE_SIGN_IDENTITY[config=Debug] = $identity_sha
OTHER_CODE_SIGN_FLAGS[config=Debug] = \$(inherited) --keychain "$login_keychain" --timestamp=none
EOF
echo "Local Debug signing configured: $identity_name"
echo 'Build without CODE_SIGN_IDENTITY=-. Keep Local.xcconfig and its Keychain identity.'
