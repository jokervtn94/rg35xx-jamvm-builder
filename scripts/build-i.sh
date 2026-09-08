#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/I"
OUT="$ROOT/dist/I"
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

# Trace every GETFIELD executed by the single target method bt.a(I)Object.
# On this method all four GETFIELDs are reference fields, so this safely reveals
# object pointer, prepared field offset and raw memory value without guessing
# source-bytecode offsets.
old0='''#define GETFIELD_QUICK_0(offset, type)                     \\
{                                                          \\
    Object *obj = (Object *)*--ostack;                     \\
    NULL_POINTER_CHECK(obj);                               \\
    PUSH_0(INST_DATA(obj, type, offset), 3);               \\
}'''
old1='''#define GETFIELD_QUICK_1(offset, type)                     \\
{                                                          \\
    Object *obj = (Object *)cache.i.v1;                    \\
    NULL_POINTER_CHECK(obj);                               \\
    PUSH_0(INST_DATA(obj, type, offset), 3);               \\
}'''
old2='''#define GETFIELD_QUICK_2(offset, type)                     \\
{                                                          \\
    Object *obj = (Object *)cache.i.v2;                    \\
    NULL_POINTER_CHECK(obj);                               \\
    PUSH_1(INST_DATA(obj, type, offset), 3);               \\
}'''
for n,x in [('0',old0),('1',old1),('2',old2)]:
    if x not in s: raise SystemExit('ERROR: GETFIELD_QUICK_'+n+' baseline block not found')

trace=r'''#define RG35XX_I_TRACE_GETFIELD(obj, offset, raw, level)                         \
{                                                                                \
    if(mb && mb->class && mb->name && mb->type &&                               \
       strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&                         \
       strcmp(mb->name, "a") == 0 &&                                           \
       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {                       \
        long rg_pc_index = (long)(pc - (CodePntr)mb->code);                     \
        fprintf(stderr,                                                          \
          "RG35XX-JAMVM-I: GETFIELD level=%d pc_index=%ld obj=0x%08lx offset=%u addr=0x%08lx raw=0x%08lx\\n", \
          (level), rg_pc_index, (unsigned long)(uintptr_t)(obj),                 \
          (unsigned)(offset),                                                    \
          (unsigned long)((uintptr_t)(obj) + (uintptr_t)(offset)),               \
          (unsigned long)(uintptr_t)(raw));                                      \
        fflush(stderr);                                                          \
    }                                                                            \
}
'''
anchor=old0
s=s.replace(anchor, trace + r'''#define GETFIELD_QUICK_0(offset, type)                     \
{                                                          \
    Object *obj = (Object *)*--ostack;                     \
    type rg_raw;                                           \
    NULL_POINTER_CHECK(obj);                               \
    rg_raw = INST_DATA(obj, type, offset);                 \
    RG35XX_I_TRACE_GETFIELD(obj, offset, rg_raw, 0);       \
    PUSH_0(rg_raw, 3);                                     \
}''',1)
s=s.replace(old1,r'''#define GETFIELD_QUICK_1(offset, type)                     \
{                                                          \
    Object *obj = (Object *)cache.i.v1;                    \
    type rg_raw;                                           \
    NULL_POINTER_CHECK(obj);                               \
    rg_raw = INST_DATA(obj, type, offset);                 \
    RG35XX_I_TRACE_GETFIELD(obj, offset, rg_raw, 1);       \
    PUSH_0(rg_raw, 3);                                     \
}''',1)
s=s.replace(old2,r'''#define GETFIELD_QUICK_2(offset, type)                     \
{                                                          \
    Object *obj = (Object *)cache.i.v2;                    \
    type rg_raw;                                           \
    NULL_POINTER_CHECK(obj);                               \
    rg_raw = INST_DATA(obj, type, offset);                 \
    RG35XX_I_TRACE_GETFIELD(obj, offset, rg_raw, 2);       \
    PUSH_1(rg_raw, 3);                                     \
}''',1)

oldret='''#define RETURN_0                                           \\
    *lvars++ = *--ostack;                                  \\
    goto methodReturn;\n\n#define RETURN_1                                           \\
    *lvars++ = cache.i.v1;                                 \\
    goto methodReturn;\n\n#define RETURN_2                                           \\
    *lvars++ = cache.i.v2;                                 \\
    goto methodReturn;'''
if oldret not in s: raise SystemExit('ERROR: RETURN block not found')
newret=r'''#define RG35XX_I_TRACE_RETURN(value, level)                                      \
{                                                                                \
    if(mb && mb->class && mb->name && mb->type &&                               \
       strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&                         \
       strcmp(mb->name, "a") == 0 &&                                           \
       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {                       \
        fprintf(stderr, "RG35XX-JAMVM-I: BT_GET_RETURN level=%d value=0x%08lx lvar0=0x%08lx index=%ld\\n", \
                (level), (unsigned long)(uintptr_t)(value),                     \
                (unsigned long)lvars[0], (long)lvars[1]);                       \
        fflush(stderr);                                                          \
    }                                                                            \
}

#define RETURN_0                                           \
{                                                          \
    uintptr_t rg = *--ostack;                              \
    RG35XX_I_TRACE_RETURN(rg, 0);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}
#define RETURN_1                                           \
{                                                          \
    uintptr_t rg = cache.i.v1;                             \
    RG35XX_I_TRACE_RETURN(rg, 1);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}
#define RETURN_2                                           \
{                                                          \
    uintptr_t rg = cache.i.v2;                             \
    RG35XX_I_TRACE_RETURN(rg, 2);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}'''
s=s.replace(oldret,newret,1)

start_marker="    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"; end_marker="        DISPATCH(0, 3);\n    })"
start=s.find(start_marker); end=s.find(end_marker,start)
if start<0 or end<0: raise SystemExit('ERROR: CHECKCAST block not found')
end+=len(end_marker)
replacement=r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];
        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_index = (long)(pc - (CodePntr)mb->code);
            fprintf(stderr, "RG35XX-JAMVM-I: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_index=%ld\\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>", pc_index);
            fflush(stderr); exit(92);
        }
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException, CLASS_CB(obj->class)->name);
        DISPATCH(0, 3);
    })'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
print('Applied RG35XX I GETFIELD diagnostic')
PY
CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=I; echo name=I-getfield-offset-trace; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "diagnostic=trace every GETFIELD in bt.a(int), raw address/value and return; exit 92"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"; cp -f "$BIN" "$OUT/jamvm-I-getfield-offset-unstripped"; cp -f "$BIN" "$OUT/jamvm-I-getfield-offset-stripped"
"$STRIP" "$OUT/jamvm-I-getfield-offset-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"; "$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM I GETFIELD offset trace
Traces all GETFIELD operations inside bt.a(int):Object, logging cache level, prepared pc index, source object pointer, field offset, exact address and raw value. Then traces the return and guards the known invalid CHECKCAST. Exit 92 on the known low pointer.
EOF
echo BUILD COMPLETE
