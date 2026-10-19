#!/usr/bin/env bash
# Download the compiled SFace face-recognition model (Apache-2.0, OpenCV Zoo)
# into faceid/model/. To build it yourself from the ONNX original instead, use
# FaceMac's converter: https://github.com/c1osed1/FaceMac (scripts/fetch-model.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/../model"
URL="${FACEID_MODEL_URL:-https://github.com/rhan1/boring.notch/releases/download/v2.7.3-faceid.1/FaceEmbedding.mlmodelc.zip}"
if [[ -d "$DEST/FaceEmbedding.mlmodelc" ]]; then echo "model already present"; exit 0; fi
mkdir -p "$DEST"
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/model.zip" "$URL"
ditto -x -k "$TMP/model.zip" "$DEST"
rm -rf "$TMP"
echo "model saved to $DEST/FaceEmbedding.mlmodelc"
