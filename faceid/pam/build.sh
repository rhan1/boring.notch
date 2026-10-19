#!/usr/bin/env bash
# Build pam_facemac.so. The pinned requirement must match how scripts/bundle.sh
# signs the app (identifier + signing certificate SHA-1).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
CERT_SHA1="${FACEMAC_CERT_SHA1:-$(security find-identity -v -p codesigning | awk '/"Archie Dev"/{print $2; exit}')}"
IDENT="${FACEMAC_IDENTIFIER:-theboringteam.boringnotch}"
REQ="identifier \\\"${IDENT}\\\" and certificate leaf = H\\\"${CERT_SHA1}\\\""
clang -Wall -Wextra -O2 -bundle -o pam_facemac.so pam_facemac.c \
  -DFACEMAC_REQUIREMENT="\"$REQ\"" -lpam -framework Security -framework CoreFoundation
codesign --force --sign "${FACEMAC_SIGN_IDENTITY:-Archie Dev}" pam_facemac.so
echo "built $(pwd)/pam_facemac.so (pinned cert $CERT_SHA1)"
