#!/usr/bin/env bash
# Build pam_facemac.so. It only trusts a Boring Notch signed with the same
# certificate as this module, so build it with the identity that signs the app:
#   FACEMAC_SIGN_IDENTITY="<your codesigning identity>" ./build.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
IDENTITY="${FACEMAC_SIGN_IDENTITY:-Archie Dev}"
CERT_SHA1="${FACEMAC_CERT_SHA1:-$(security find-identity -v -p codesigning | awk -v id="\"$IDENTITY\"" 'index($0, id) {print $2; exit}')}"
[[ -n "$CERT_SHA1" ]] || { echo "codesigning identity \"$IDENTITY\" not found"; exit 1; }
IDENT="${FACEMAC_IDENTIFIER:-theboringteam.boringnotch}"
REQ="identifier \\\"${IDENT}\\\" and certificate leaf = H\\\"${CERT_SHA1}\\\""
clang -Wall -Wextra -O2 -bundle -o pam_facemac.so pam_facemac.c \
  -DFACEMAC_REQUIREMENT="\"$REQ\"" -lpam -framework Security -framework CoreFoundation
codesign --force --sign "$IDENTITY" pam_facemac.so
echo "built $(pwd)/pam_facemac.so (pinned cert $CERT_SHA1)"
