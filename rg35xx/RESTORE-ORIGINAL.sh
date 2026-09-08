#!/bin/sh
set -eu

TARGET="/mnt/mmc/CFW/java/bin/jamvm"
BACKUP="/mnt/mmc/CFW/java/bin/jamvm.original-before-github-tests"

echo "RG35XX JamVM restore"
echo "===================="

if [ ! -f "$BACKUP" ]; then
  echo "ERROR: original backup not found:"
  echo "$BACKUP"
  exit 2
fi

cp -f "$BACKUP" "$TARGET"
chmod 700 "$TARGET"
sync

echo "Original JamVM restored."
sha256sum "$TARGET" "$BACKUP" 2>/dev/null || true
