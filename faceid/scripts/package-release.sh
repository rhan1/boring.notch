#!/usr/bin/env bash
# Build a shareable zip: the app (face model inside), the sudo module built for
# the same signing certificate, and the installers.
#   FACEID_SIGN_IDENTITY  codesigning identity (default "Archie Dev")
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITY="${FACEID_SIGN_IDENTITY:-Archie Dev}"
VERSION="${1:?usage: package-release.sh <version-tag>}"
OUT="$ROOT/.build/release/$VERSION"
APP="$ROOT/.build/dd/Build/Products/Release/boringNotch.app"
MODEL="$ROOT/faceid/model/FaceEmbedding.mlmodelc"
[[ -d "$APP" && -d "$MODEL" ]] || { echo "build the app and fetch the model first"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/BoringNotch-FaceID"
PKG="$OUT/BoringNotch-FaceID"
ditto "$APP" "$PKG/boringNotch.app"
ditto "$MODEL" "$PKG/boringNotch.app/Contents/Resources/FaceEmbedding.mlmodelc"
codesign --force --sign "$IDENTITY" "$PKG/boringNotch.app"
codesign --verify --deep --strict "$PKG/boringNotch.app"

(cd "$ROOT/faceid/pam" && FACEMAC_SIGN_IDENTITY="$IDENTITY" ./build.sh >/dev/null && clang -O2 -o pamcheck pamcheck.c -lpam)
mkdir -p "$PKG/sudo"
cp "$ROOT/faceid/pam/"{pam_facemac.so,pamcheck,install.sh} "$PKG/sudo/"
cp "$ROOT/faceid/scripts/install.sh" "$PKG/install.sh"
cp "$ROOT/faceid/README.md" "$PKG/README.md"

(cd "$OUT" && ditto -c -k --keepParent BoringNotch-FaceID "BoringNotch-FaceID-$VERSION.zip")
(cd "$ROOT/faceid/model" && ditto -c -k --keepParent FaceEmbedding.mlmodelc "$OUT/FaceEmbedding.mlmodelc.zip")
ls -lh "$OUT"/*.zip
