#!/usr/bin/env bash
# Install Boring Notch with Face ID over the official Boring Notch.
#   From a release zip:  ./install.sh            (uses ./boringNotch.app next to this script)
#   From source:         faceid/scripts/install.sh   (uses the Xcode build output)
# Safe to re-run after every rebuild; one-time steps are guarded.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." 2>/dev/null && pwd || true)"
if [[ -d "$HERE/boringNotch.app" ]]; then
  BUILT="$HERE/boringNotch.app"
else
  BUILT="$ROOT/.build/dd/Build/Products/Release/boringNotch.app"
fi
APP=/Applications/boringNotch.app
BACKUP="$HOME/Library/Application Support/boringNotch-FaceID/backup"
CONTAINER="$HOME/Library/Containers/theboringteam.boringnotch/Data/Library"
SUPPORT="$HOME/Library/Application Support"
[[ -d "$BUILT" ]] || { echo "No boringNotch.app found. Build it first (see faceid/README.md)."; exit 1; }

mkdir -p "$BACKUP"
# 1. Keep the official app once, so it can be restored.
if [[ -d "$APP" && ! -d "$BACKUP/boringNotch-official.app" ]]; then
  if ! codesign -dvv "$APP" 2>&1 | grep -q "TeamIdentifier=not set"; then
    ditto "$APP" "$BACKUP/boringNotch-official.app"
    echo "backed up the official app to $BACKUP"
  fi
fi

# 2. This build isn't sandboxed: bring settings out of the sandbox container once.
#    Import by file path — `defaults import <bundle-id>` would write back into
#    the container, where this build doesn't look.
if [[ ! -f "$BACKUP/.prefs-migrated" && -f "$CONTAINER/Preferences/theboringteam.boringnotch.plist" ]]; then
  defaults export "$CONTAINER/Preferences/theboringteam.boringnotch.plist" - \
    | defaults import "$HOME/Library/Preferences/theboringteam.boringnotch.plist" -
  if [[ -d "$CONTAINER/Application Support/boringNotch" ]]; then
    ditto "$CONTAINER/Application Support/boringNotch" "$SUPPORT/boringNotch"
  fi
  touch "$BACKUP/.prefs-migrated"
  echo "migrated your Boring Notch settings"
fi

# 3. The face model: release builds carry it inside the app; source builds get
#    it from faceid/model (run faceid/scripts/fetch-model.sh first).
if [[ ! -d "$BUILT/Contents/Resources/FaceEmbedding.mlmodelc" && ! -d "$SUPPORT/FaceMac/FaceEmbedding.mlmodelc" ]]; then
  if [[ -d "$ROOT/faceid/model/FaceEmbedding.mlmodelc" ]]; then
    mkdir -p "$SUPPORT/FaceMac"
    ditto "$ROOT/faceid/model/FaceEmbedding.mlmodelc" "$SUPPORT/FaceMac/FaceEmbedding.mlmodelc"
    echo "installed the face model"
  else
    echo "warning: no face model found; run faceid/scripts/fetch-model.sh"
  fi
fi

# 4. Quit running copies (and the standalone FaceMac app, which would fight
#    over the Face ID socket), then wait until they're gone.
pkill -f "FaceMac.app/Contents/MacOS/FaceMac" 2>/dev/null || true
osascript -e 'tell application id "theboringteam.boringnotch" to quit' 2>/dev/null || true
pkill -f "boringNotch.app/Contents/MacOS/boringNotch" 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -f "boringNotch.app/Contents/MacOS/boringNotch" >/dev/null || break; sleep 0.5; done

# 5. Swap the app. A re-signed app invalidates old permission grants; clear them
#    once so macOS asks again instead of silently refusing.
SIG_BEFORE=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)
SIG_AFTER=$(codesign -dvv "$BUILT" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)
rm -rf "$APP"
ditto "$BUILT" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
if [[ "$SIG_BEFORE" != "$SIG_AFTER" ]]; then
  tccutil reset All theboringteam.boringnotch >/dev/null || true
  echo "reset permissions for the re-signed app (macOS will ask again)"
fi
open "$APP"
echo "installed $APP ($(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString))"
