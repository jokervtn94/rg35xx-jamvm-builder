#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/G"
OUT="$ROOT/dist/G"
CROSS_ROOT="${CROSS_ROOT:-/opt/miyoo}"
TRIPLE="${CROSS_TRIPLE:-arm-miyoo-linux-uclibcgnueabi}"
SYSROOT="${SYSROOT:-$CROSS_ROOT/$TRIPLE/sysroot}"
export PATH="$CROSS_ROOT/bin:$PATH"
CC="$TRIPLE-gcc"; READELF="$TRIPLE-readelf"; STRIP="$TRIPLE-strip"
command -v "$CC" >/dev/null; command -v "$READELF" >/dev/null; test -f "$TARBALL"
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'jamvm-*' | head -n 1)"; test -n "$SRC"
python3 - "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='''    PREPARE_MB(mb);\n    pc = (CodePntr)mb->code;\n'''
if needle not in s: raise SystemExit('ERROR: PREPARE_MB marker not found')
insert='''    PREPARE_MB(mb);\n    pc = (CodePntr)mb->code;\n\n    /* RG35XX G: trace object flow only for the two KDTT container methods. */\n    if(mb && mb->class && mb->name && mb->type) {\n        const char *rg_owner = CLASS_CB(mb->class)->name;\n        if(strcmp(rg_owner, "bt") == 0 && strcmp(mb->name, "a") == 0 &&\n           strcmp(mb->type, "(Ljava/lang/Object;)V") == 0) {\n            fprintf(stderr, "RG35XX-JAMVM-G: BT_ADD_ENTRY this=0x%08lx arg=0x%08lx\\n",\n                    (unsigned long)lvars[0], (unsigned long)lvars[1]);\n            fflush(stderr);\n        }\n        if(strcmp(rg_owner, "b") == 0 && strcmp(mb->name, "<init>") == 0 &&\n           strcmp(mb->type, "(Lbt;Ljava/lang/Object;)V") == 0) {\n            fprintf(stderr, "RG35XX-JAMVM-G: NODE_CTOR_ENTRY this=0x%08lx ownerbt=0x%08lx value=0x%08lx\\n",\n                    (unsigned long)lvars[0], (unsigned long)lvars[1], (unsigned long)lvars[2]);\n            fflush(stderr);\n        }\n    }\n'''
s=s.replace(needle,insert,1)
old='''#define RETURN_0                                           \\\n    *lvars++ = *--ostack;                                  \\\n    goto methodReturn;\n\n#define RETURN_1                                           \\\n    *lvars++ = cache.i.v1;                                 \\\n    goto methodReturn;\n\n#define RETURN_2                                           \\\n    *lvars++ = cache.i.v2;                                 \\\n    goto methodReturn;'''
if old not in s: raise SystemExit('ERROR: RETURN block not found')
new=r'''#define RG35XX_G_TRACE_RETURN(value, level)                                      \
{                                                                                \
    if(mb && mb->class && mb->name && mb->type &&                               \
       strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&                         \
       strcmp(mb->name, "a") == 0 &&                                           \
       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {                       \
        fprintf(stderr, "RG35XX-JAMVM-G: BT_GET_RETURN level=%d value=0x%08lx\n", \
                (level), (unsigned long)(uintptr_t)(value));                    \
        fflush(stderr);                                                          \
    }                                                                            \
}\n\n#define RETURN_0 { uintptr_t rg=*--ostack; RG35XX_G_TRACE_RETURN(rg,0); *lvars++=rg; goto methodReturn; }\n#define RETURN_1 { uintptr_t rg=cache.i.v1; RG35XX_G_TRACE_RETURN(rg,1); *lvars++=rg; goto methodReturn; }\n#define RETURN_2 { uintptr_t rg=cache.i.v2; RG35XX_G_TRACE_RETURN(rg,2); *lvars++=rg; goto methodReturn; }'''
s=s.replace(old,new,1)
start_marker="    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"; end_marker="        DISPATCH(0, 3);\n    })"
start=s.find(start_marker); end=s.find(end_marker,start)
if start<0 or end<0: raise SystemExit('ERROR: CHECKCAST block not found')
end+=len(end_marker)
replacement=r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];
        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_index = (long)(pc - (CodePntr)mb->code);
            fprintf(stderr, "RG35XX-JAMVM-G: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_index=%ld\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>", pc_index);
            fflush(stderr); exit(89);
        }
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException, CLASS_CB(obj->class)->name);
        DISPATCH(0, 3);
    })'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
print('Applied RG35XX G object-flow diagnostic')
PY
CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=G; echo name=G-object-flow-trace; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "diagnostic=trace bt.add arg, b.<init> value, bt.get return; exit 89"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"; cp -f "$BIN" "$OUT/jamvm-G-object-flow-unstripped"; cp -f "$BIN" "$OUT/jamvm-G-object-flow-stripped"
"$STRIP" "$OUT/jamvm-G-object-flow-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"; "$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM G object-flow trace
Trace bt.a(Object) input, b.<init> Object input, bt.a(int) Object return, and guarded CHECKCAST. Exit 89 on known low pointer.
EOF
echo BUILD COMPLETE
