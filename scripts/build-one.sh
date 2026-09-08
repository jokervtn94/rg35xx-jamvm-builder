#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-${MODE:-}}"
case "$MODE" in
  A|B|C) ;;
  *)
    echo "ERROR: mode must be A, B, or C" >&2
    exit 2
    ;;
esac

ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/$MODE"
OUT="$ROOT/dist/$MODE"

CROSS_ROOT="${CROSS_ROOT:-/opt/miyoo}"
TRIPLE="${CROSS_TRIPLE:-arm-miyoo-linux-uclibcgnueabi}"
SYSROOT="${SYSROOT:-$CROSS_ROOT/$TRIPLE/sysroot}"

export PATH="$CROSS_ROOT/bin:$PATH"

CC="$TRIPLE-gcc"
READELF="$TRIPLE-readelf"
STRIP="$TRIPLE-strip"

command -v "$CC" >/dev/null
command -v "$READELF" >/dev/null
test -f "$TARBALL"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

tar -xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'jamvm-*' | head -n 1)"
test -n "$SRC"

case "$MODE" in
  A)
    NAME="A-no-cache"
    EXTRA="--disable-int-caching"
    ;;
  B)
    NAME="B-no-cache-no-inline"
    EXTRA="--disable-int-caching --disable-int-inlining"
    ;;
  C)
    NAME="C-no-inline"
    EXTRA="--disable-int-inlining"
    ;;
esac

CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"

{
  echo "mode=$MODE"
  echo "name=$NAME"
  echo "cross_root=$CROSS_ROOT"
  echo "triple=$TRIPLE"
  echo "sysroot=$SYSROOT"
  echo "cflags=$CFLAGS"
  echo "configure=$COMMON_CONF $EXTRA"
  "$CC" --version | head -n 1
} > "$OUT/build-config.txt"

cd "$SRC"

CC="$CC --sysroot=$SYSROOT" \
CFLAGS="$CFLAGS" \
./configure $COMMON_CONF $EXTRA > "$OUT/configure.log" 2>&1

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1

BIN="$(find . -type f -name jamvm -perm -111 | head -n 1)"
if [ -z "$BIN" ]; then
  echo "ERROR: built jamvm binary not found" >&2
  exit 10
fi

cp -f "$BIN" "$OUT/jamvm"
cp -f "$BIN" "$OUT/jamvm-$NAME"
cp -f "$BIN" "$OUT/jamvm-$NAME-unstripped"
cp -f "$BIN" "$OUT/jamvm-$NAME-stripped"
"$STRIP" "$OUT/jamvm-$NAME-stripped" || true

sha256sum \
  "$OUT/jamvm" \
  "$OUT/jamvm-$NAME" \
  "$OUT/jamvm-$NAME-unstripped" \
  "$OUT/jamvm-$NAME-stripped" > "$OUT/SHA256SUMS.txt"

file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"
"$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
"$READELF" -d "$OUT/jamvm" > "$OUT/readelf-d.txt" || true
"$READELF" -l "$OUT/jamvm" > "$OUT/readelf-l.txt" || true

grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
if grep -q "Tag_ABI_VFP_args" "$OUT/readelf-A.txt"; then
  echo "WARNING: VFP argument ABI tag found; inspect readelf-A.txt" | tee "$OUT/ABI-WARNING.txt"
fi

cp "$ROOT/rg35xx/INSTALL-ON-RG35XX.sh" "$OUT/INSTALL-ON-RG35XX.sh"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"

cat > "$OUT/README-TEST.txt" <<EOF
RG35XX JamVM test build: $NAME

FILE TO DEPLOY:
  jamvm

AUTOMATIC INSTALL ON RG35XX:
  Put this whole folder on the SD card.
  Run INSTALL-ON-RG35XX.sh from this same folder.
  It will preserve the original JamVM at:
  /mnt/mmc/CFW/java/bin/jamvm.original-before-github-tests

TEST TARGET:
  /mnt/mmc/Roms/JAVA/KDTT-Tam_Quoc_Chi_320x240_vh_by_zeplaovn.jar

INTERPRETATION:
A = stack caching OFF; inlining left at default.
B = stack caching OFF + interpreter inlining OFF.
C = interpreter inlining OFF; caching left at default.

Do not modify FreeJ2ME core/runtime, Smart-Fit, PNG, font, audio, or the game
while comparing A/B/C.

After installing, launch KDTT normally and observe whether it still crashes.
To return to the original JamVM, run RESTORE-ORIGINAL.sh.
EOF

echo "BUILD COMPLETE: $NAME"
