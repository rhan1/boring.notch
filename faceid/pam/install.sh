#!/usr/bin/env bash
# Hook FaceMac into sudo. Adds pam_facemac ahead of Touch ID in
# /etc/pam.d/sudo_local (kept by macOS across updates).
#   install:   sudo ./install.sh   (from Terminal with Full Disk Access — macOS 26 requires it to edit /etc/pam.d)
#   uninstall: sudo ./install.sh --uninstall
# macOS 26 forbids creating files in /etc/pam.d, so sudo_local is rewritten in
# place and the backup lives next to the module. Every step is checked, and a
# sudo that cannot start PAM afterwards triggers an automatic restore.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib/pam
DEST=$LIB/pam_facemac.so
CONF=/etc/pam.d/sudo_local
BACKUP=$LIB/sudo_local.facemac-backup
USER_NAME="${SUDO_USER:-$(stat -f %Su "$HERE")}"

# pam_start loads every module in a policy, so it fails if any module cannot
# load — exactly the failure that would lock sudo out.
sudo_starts_pam() { "$HERE/pamcheck" sudo "$USER_NAME"; }

write_conf() {  # $1 = module path to insert
  { grep '^#' "$BACKUP" || true
    echo "auth       sufficient     $1"
    grep -v '^#' "$BACKUP" || true; } > "$LIB/sudo_local.new"
  cat "$LIB/sudo_local.new" > "$CONF"      # in-place: creating files in pam.d is denied
  rm -f "$LIB/sudo_local.new"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ -f $BACKUP ]]; then cat "$BACKUP" > "$CONF"; else sed -i '' "\|pam_facemac.so|d" "$CONF"; fi
  rm -f "$DEST" "$BACKUP"
  echo "removed"; cat "$CONF"; exit 0
fi

[[ -f "$HERE/pam_facemac.so" && -x "$HERE/pamcheck" ]] || { echo "build first (pam/build.sh)"; exit 1; }
install -d -o root -g wheel -m 755 "$LIB"
install -o root -g wheel -m 444 "$HERE/pam_facemac.so" "$DEST"
codesign --verify "$DEST"

echo "before:"; cat "$CONF"
sudo_starts_pam || { echo "sudo probe fails even before any change; aborting"; exit 1; }

[[ -f $BACKUP ]] || cp -p "$CONF" "$BACKUP"
trap 'echo "error; restoring"; cat "$BACKUP" > "$CONF"' ERR

# Red control: a module that cannot load must make the check fail.
write_conf "$LIB/does-not-exist.so"
if sudo_starts_pam; then
  cat "$BACKUP" > "$CONF"
  echo "check cannot detect a broken module; restored, nothing installed"; exit 1
fi
echo "  red control failed as expected"

write_conf "$DEST"
echo "after:"; cat "$CONF"
if ! sudo_starts_pam; then
  cat "$BACKUP" > "$CONF"
  echo "sudo could not start PAM with FaceMac; restored"; sudo_starts_pam; exit 1
fi
trap - ERR
echo "installed: sudo tries your face first, then Touch ID, then your password"
