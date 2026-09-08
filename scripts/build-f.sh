#!/usr/bin/env bash
set -euo pipefail

ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/F"
OUT="$ROOT/dist/F"
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

python3 - "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

old = '''#define RETURN_0                                           \\
    *lvars++ = *--ostack;                                  \\
    goto methodReturn;

#define RETURN_1                                           \\
    *lvars++ = cache.i.v1;                                 \\
    goto methodReturn;

#define RETURN_2                                           \\
    *lvars++ = cache.i.v2;                                 \\
    goto methodReturn;'''
if old not in s:
    raise SystemExit('ERROR: RETURN_0/1/2 block not found; refusing blind patch')
new = r'''#define RG35XX_F_TRACE_RETURN(value, level)                                      \
{                                                                                \
    if(mb && mb->class && mb->name && mb->type &&                               \
       strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&                         \
       strcmp(mb->name, "a") == 0 &&                                           \
       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {                       \
        fprintf(stderr,                                                          \
                "RG35XX-JAMVM-F: BT_RETURN level=%d value=0x%08lx ostack=%p lvars=%p\n", \
                (level), (unsigned long)(uintptr_t)(value),                     \
                (void*)ostack, (void*)lvars);                                   \
        fflush(stderr);                                                          \
    }                                                                            \
}

#define RETURN_0                                           \
{                                                          \
    uintptr_t rg35xx_f_ret = *--ostack;                    \
    RG35XX_F_TRACE_RETURN(rg35xx_f_ret, 0);                \
    *lvars++ = rg35xx_f_ret;                               \
    goto methodReturn;                                     \
}

#define RETURN_1                                           \
{                                                          \
    uintptr_t rg35xx_f_ret = cache.i.v1;                   \
    RG35XX_F_TRACE_RETURN(rg35xx_f_ret, 1);                \
    *lvars++ = rg35xx_f_ret;                               \
    goto methodReturn;                                     \
}

#define RETURN_2                                           \
{                                                          \
    uintptr_t rg35xx_f_ret = cache.i.v2;                   \
    RG35XX_F_TRACE_RETURN(rg35xx_f_ret, 2);                \
    *lvars++ = rg35xx_f_ret;                               \
    goto methodReturn;                                     \
}'''
s = s.replace(old, new, 1)

start_marker = "    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"
end_marker = "        DISPATCH(0, 3);\n    })"
start = s.find(start_marker)
if start < 0:
    raise SystemExit('ERROR: CHECKCAST_QUICK start marker not found')
end = s.find(end_marker, start)
if end < 0:
    raise SystemExit('ERROR: CHECKCAST_QUICK end marker not found')
end += len(end_marker)
block = s[start:end]
if block.count('OPC_CHECKCAST_QUICK') != 1 or 'isInstanceOf' not in block:
    raise SystemExit('ERROR: unexpected CHECKCAST_QUICK block')
replacement = r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];

        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_bytes = (long)((char*)pc - (char*)mb->code);
            long pc_index = (long)(pc - (CodePntr)mb->code);
            fprintf(stderr,
                    "RG35XX-JAMVM-F: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_bytes=%ld pc_index=%ld instruction_size=%u code_size=%d\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>",
                    pc_bytes, pc_index, (unsigned)sizeof(*pc), mb ? mb->code_size : -1);
            fprintf(stderr,
                    "RG35XX-JAMVM-F: stack[-1]=0x%08lx stack[-2]=0x%08lx stack[-3]=0x%08lx stack[-4]=0x%08lx\n",
                    (unsigned long)ostack[-1],
                    (unsigned long)ostack[-2],
                    (unsigned long)ostack[-3],
                    (unsigned long)ostack[-4]);
            fflush(stderr);
            exit(88);
        }

        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException,
                            CLASS_CB(obj->class)->name);

        DISPATCH(0, 3);
    })'''
s = s[:start] + replacement + s[end:]
p.write_text(s)
print('Applied RG35XX F return-path diagnostic')
PY

CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
  echo "mode=F"
  echo "name=F-return-path-trace"
  echo "triple=$TRIPLE"
  echo "cflags=$CFLAGS"
  echo "configure=$COMMON_CONF"
  echo "diagnostic=trace return value of bt.a(I)Object and compare with following bad CHECKCAST; exit 88"
  "$CC" --version | head -n 1
} > "$OUT/build-config.txt"

cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n 1)"
[ -n "$BIN" ] || { echo "ERROR: built jamvm binary not found" >&2; exit 10; }
cp -f "$BIN" "$OUT/jamvm"
cp -f "$BIN" "$OUT/jamvm-F-return-path-trace-unstripped"
cp -f "$BIN" "$OUT/jamvm-F-return-path-trace-stripped"
"$STRIP" "$OUT/jamvm-F-return-path-trace-stripped" || true
sha256sum "$OUT/jamvm" "$OUT/jamvm-F-return-path-trace-unstripped" "$OUT/jamvm-F-return-path-trace-stripped" > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"
"$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
"$READELF" -d "$OUT/jamvm" > "$OUT/readelf-d.txt" || true
"$READELF" -l "$OUT/jamvm" > "$OUT/readelf-l.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM F return-path trace

Purpose:
- Trace the exact object value returned by bt.a(I)Ljava/lang/Object;.
- Compare that value with the operand observed by the immediately-following CHECKCAST z in bd.b(String):z.
- Log prepared instruction index and Instruction size.
- Exit 88 instead of SIGSEGV if the known invalid CHECKCAST operand recurs.

Keep FreeJ2ME core/runtime/game/config/save unchanged.
EOF
echo "BUILD COMPLETE: F-return-path-trace"
