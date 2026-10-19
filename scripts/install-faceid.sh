#!/usr/bin/env bash
# Install Raza's Face ID build of Boring Notch over the official one.
# One-time steps are guarded so this is safe to re-run after every rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/.build/dd/Build/Products/Release/boringNotch.app"
APP=/Applications/boringNotch.app
BACKUP="$ROOT/.backup"
CONTAINER="$HOME/Library/Containers/theboringteam.boringnotch/Data/Library"
SUPPORT="$HOME/Library/Application Support"
[[ -d "$BUILT" ]] || { echo "build first"; exit 1; }

mkdir -p "$BACKUP"
# 1. Keep the official app once, so it can be restored.
if [[ ! -d "$BACKUP/boringNotch-official.app" ]]; then
  ditto "$APP" "$BACKUP/boringNotch-official.app"
  echo "backed up the official app"
fi

# 2. The fork is not sandboxed: bring its settings out of the sandbox container once.
if [[ ! -f "$BACKUP/.prefs-migrated" && -f "$CONTAINER/Preferences/theboringteam.boringnotch.plist" ]]; then
  defaults export "$CONTAINER/Preferences/theboringteam.boringnotch.plist" - | defaults import theboringteam.boringnotch -
  if [[ -d "$CONTAINER/Application Support/boringNotch" ]]; then
    ditto "$CONTAINER/Application Support/boringNotch" "$SUPPORT/boringNotch"
  fi
  touch "$BACKUP/.prefs-migrated"
  echo "migrated Boring Notch settings"
fi

# 3. Face model lives next to the enrollment.
if [[ ! -d "$SUPPORT/FaceMac/FaceEmbedding.mlmodelc" ]]; then
  ditto "$HOME/Projects/FaceMac/Resources/prebuilt/FaceEmbedding.mlmodelc" "$SUPPORT/FaceMac/FaceEmbedding.mlmodelc"
  echo "copied face model"
fi

# 4. Only one app may own the Face ID socket.
pkill -x FaceMac 2>/dev/null || true
pkill -x boringNotch 2>/dev/null || true
sleep 1

# 5. Swap the app. A new signature invalidates old permission grants; clear them
#    once so macOS asks again instead of silently refusing.
SIG_BEFORE=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)
rm -rf "$APP"
ditto "$BUILT" "$APP"
if [[ "$SIG_BEFORE" != "Archie Dev" ]]; then
  tccutil reset All theboringteam.boringnotch >/dev/null || true
  echo "reset permissions for the re-signed app"
fi
open "$APP"
echo "installed $APP ($(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString))"
