#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NEW="$SCRIPT_DIR/jamvm"
TARGET="/mnt/mmc/CFW/java/bin/jamvm"
BACKUP="/mnt/mmc/CFW/java/bin/jamvm.original-before-github-tests"

echo "RG35XX JamVM test installer"
echo "==========================="

if [ ! -f "$NEW" ]; then
  echo "ERROR: jamvm test binary not found beside this script:"
  echo "$NEW"
  exit 2
fi

if [ ! -f "$TARGET" ]; then
  echo "ERROR: original JamVM target not found:"
  echo "$TARGET"
  exit 3
fi

if [ ! -f "$BACKUP" ]; then
  echo "Creating one-time backup..."
  cp -p "$TARGET" "$BACKUP"
  chmod 700 "$BACKUP" 2>/dev/null || true
  sync
else
  echo "Original backup already exists; keeping it unchanged."
fi

echo "Installing test JamVM..."
cp -f "$NEW" "$TARGET"
chmod 700 "$TARGET"
sync

echo
echo "Installed:"
ls -l "$TARGET" 2>/dev/null || true
sha256sum "$TARGET" "$BACKUP" 2>/dev/null || true

echo
echo "DONE."
echo "Now launch KDTT normally."
echo "To restore the original JamVM, run RESTORE-ORIGINAL.sh from this folder."
