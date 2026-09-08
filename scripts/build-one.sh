#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-${MODE:-}}"
case "$MODE" in
  A|B|C|D) ;;
  *) echo "ERROR: mode must be A, B, C, or D" >&2; exit 2 ;;
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
  A) NAME="A-no-cache"; EXTRA="--disable-int-caching" ;;
  B) NAME="B-no-cache-no-inline"; EXTRA="--disable-int-caching --disable-int-inlining" ;;
  C) NAME="C-no-inline"; EXTRA="--disable-int-inlining" ;;
  D) NAME="D-checkcast-diagnostic"; EXTRA="" ;;
esac

if [ "$MODE" = D ]; then
  python3 - "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1]; 
               
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException,
                            CLASS_CB(obj->class)->name);

        DISPATCH(0, 3);
    })'''
new = '''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];

        /* RG35XX diagnostic guard: the captured crash showed obj == 0x1.
           Never dereference obviously-invalid low addresses.  Emit enough
           interpreter context to identify the producing bytecode instead. */
        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_off = (long)((char*)pc - (char*)mb->code);
            long depth = (long)(ostack - frame->ostack);
            fprintf(stderr,
                    "RG35XX-JAMVM-D: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc=%p pc_off=%ld depth=%ld\\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>",
                    (void*)pc, pc_off, depth);
            if(depth >= 1) fprintf(stderr, "RG35XX-JAMVM-D: stack[-1]=0x%08lx\\n", (unsigned long)ostack[-1]);
            if(depth >= 2) fprintf(stderr, "RG35XX-JAMVM-D: stack[-2]=0x%08lx\\n", (unsigned long)ostack[-2]);
            if(depth >= 3) fprintf(stderr, "RG35XX-JAMVM-D: stack[-3]=0x%08lx\\n", (unsigned long)ostack[-3]);
            if(depth >= 4) fprintf(stderr, "RG35XX-JAMVM-D: stack[-4]=0x%08lx\\n", (unsigned long)ostack[-4]);
            fflush(stderr);
            exit(86);
        }

        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException,
                            CLASS_CB(obj->class)->name);

        DISPATCH(0, 3);
    })'''
if old not in s:
    raise SystemExit('ERROR: CHECKCAST_QUICK source block not found; refusing blind patch')
p.write_text(s.replace(old, new, 1))
print('Applied RG35XX CHECKCAST diagnostic patch')
PY
fi

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
  [ "$MODE" = D ] && echo "diagnostic=guard CHECKCAST_QUICK low object pointers (<4096), log context, exit 86"
  "$CC" --version | head -n 1
} > "$OUT/build-config.txt"

cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF $EXTRA > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n 1)"
[ -n "$BIN" ] || { echo "ERROR: built jamvm binary not found" >&2; exit 10; }
cp -f "$BIN" "$OUT/jamvm"
cp -f "$BIN" "$OUT/jamvm-$NAME"
cp -f "$BIN" "$OUT/jamvm-$NAME-unstripped"
cp -f "$BIN" "$OUT/jamvm-$NAME-stripped"
"$STRIP" "$OUT/jamvm-$NAME-stripped" || true
sha256sum "$OUT/jamvm" "$OUT/jamvm-$NAME" "$OUT/jamvm-$NAME-unstripped" "$OUT/jamvm-$NAME-stripped" > "$OUT/SHA256SUMS.txt"
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

D diagnostic behavior:
- keeps the default JamVM interpreter configuration
- guards CHECKCAST_QUICK against obviously-invalid low object pointers
- logs BAD_CHECKCAST with target class, owner class, method, signature, PC offset and stack slots
- exits with code 86 after logging instead of dereferencing the invalid pointer

Deploy jamvm to /mnt/mmc/CFW/java/bin/jamvm using the supplied installer.
Keep FreeJ2ME core/runtime/game unchanged.
EOF
echo "BUILD COMPLETE: $NAME"
