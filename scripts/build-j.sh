#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/J"
OUT="$ROOT/dist/J"
CROSS_ROOT="${CROSS_ROOT:-/opt/miyoo}"
TRIPLE="${CROSS_TRIPLE:-arm-miyoo-linux-uclibcgnueabi}"
SYSROOT="${SYSROOT:-$CROSS_ROOT/$TRIPLE/sysroot}"
export PATH="$CROSS_ROOT/bin:$PATH"
CC="$TRIPLE-gcc"; READELF="$TRIPLE-readelf"; STRIP="$TRIPLE-strip"
command -v "$CC" >/dev/null; command -v "$READELF" >/dev/null; test -f "$TARBALL"
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'jamvm-*' | head -n1)"; test -n "$SRC"
python3 - "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''    DEF_OPC_210(OPC_ALOAD_0, {\n        if(mb->access_flags & ACC_STATIC)\n            OPCODE_REWRITE(OPC_ILOAD_0);\n        else\n            OPCODE_REWRITE(OPC_ALOAD_THIS);\n        DISPATCH(0, 0);\n    })'''
if old not in s:
    raise SystemExit('ERROR: ALOAD_0 rewrite block not found')
new='''    DEF_OPC_210(OPC_ALOAD_0, {\n        /* RG35XX J correctness fix:\n           local slot 0 is writable Java bytecode state.  Rewriting ALOAD_0\n           to ALOAD_THIS is invalid after ASTORE_0 because ALOAD_THIS uses the\n           executeJava() entry-time `this` snapshot instead of lvars[0].\n           Use ILOAD_0's word-load handler for both reference and integer data. */\n        OPCODE_REWRITE(OPC_ILOAD_0);\n        DISPATCH(0, 0);\n    })'''
s=s.replace(old,new,1)

# Keep a low-pointer CHECKCAST guard as a safety diagnostic.  If the fix works,
# KDTT should never hit this path.  Exit 93 rather than native SIGSEGV if it does.
start_marker="    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"; end_marker="        DISPATCH(0, 3);\n    })"
start=s.find(start_marker); end=s.find(end_marker,start)
if start<0 or end<0: raise SystemExit('ERROR: CHECKCAST block not found')
end+=len(end_marker)
replacement=r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];
        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_index = (long)(pc - (CodePntr)mb->code);
            fprintf(stderr, "RG35XX-JAMVM-J: LOWPTR_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_index=%ld\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>", pc_index);
            fflush(stderr); exit(93);
        }
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException, CLASS_CB(obj->class)->name);
        DISPATCH(0, 3);
    })'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
print('Applied RG35XX J ALOAD_0 correctness fix')
PY
CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=J; echo name=J-aload0-correctness-fix; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "fix=never rewrite ALOAD_0 to ALOAD_THIS; always read current lvars[0]";
 echo "guard=exit 93 on low-pointer CHECKCAST"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"; cp -f "$BIN" "$OUT/jamvm-J-aload0-fix-unstripped"; cp -f "$BIN" "$OUT/jamvm-J-aload0-fix-stripped"
"$STRIP" "$OUT/jamvm-J-aload0-fix-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"; "$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM J ALOAD_0 correctness fix

Root-cause fix under test:
JamVM rewrites ALOAD_0 to ALOAD_THIS for instance methods.  ALOAD_THIS uses an
entry-time `this` snapshot, but Java bytecode may overwrite local slot 0 with
ASTORE_0.  KDTT bt.a(int) does exactly that, then reads local 0 as a b-node.
Using stale `this` can therefore read the wrong object field and produce 0x1.

J disables that unsafe rewrite and makes ALOAD_0 always read current lvars[0].
A low-pointer CHECKCAST guard exits 93 only if corruption still occurs.
EOF
echo BUILD COMPLETE
