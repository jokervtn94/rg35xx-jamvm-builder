#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/H"
OUT="$ROOT/dist/H"
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
old='''#define RETURN_0                                           \\
    *lvars++ = *--ostack;                                  \\
    goto methodReturn;\n\n#define RETURN_1                                           \\
    *lvars++ = cache.i.v1;                                 \\
    goto methodReturn;\n\n#define RETURN_2                                           \\
    *lvars++ = cache.i.v2;                                 \\
    goto methodReturn;'''
if old not in s: raise SystemExit('ERROR: RETURN block not found')
new=r'''#define RG35XX_H_TRACE_RETURN(value, level)                                      \
{                                                                                \
    if(mb && mb->class && mb->name && mb->type &&                               \
       strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&                         \
       strcmp(mb->name, "a") == 0 &&                                           \
       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {                       \
        uintptr_t rg_node = lvars[0];                                            \
        fprintf(stderr, "RG35XX-JAMVM-H: BT_GET_RETURN level=%d value=0x%08lx node=0x%08lx index=%ld\n", \
                (level), (unsigned long)(uintptr_t)(value),                     \
                (unsigned long)rg_node, (long)lvars[1]);                        \
        if(rg_node > 4096) {                                                     \
            uintptr_t *rgw = (uintptr_t*)rg_node;                               \
            Object *rgo = (Object*)rg_node;                                     \
            fprintf(stderr, "RG35XX-JAMVM-H: NODE class=0x%08lx words=%08lx,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx\n", \
                    (unsigned long)(uintptr_t)rgo->class,                        \
                    (unsigned long)rgw[0], (unsigned long)rgw[1],               \
                    (unsigned long)rgw[2], (unsigned long)rgw[3],               \
                    (unsigned long)rgw[4], (unsigned long)rgw[5],               \
                    (unsigned long)rgw[6], (unsigned long)rgw[7]);              \
        }                                                                        \
        fflush(stderr);                                                          \
    }                                                                            \
}

#define RETURN_0                                           \
{                                                          \
    uintptr_t rg = *--ostack;                              \
    RG35XX_H_TRACE_RETURN(rg, 0);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}

#define RETURN_1                                           \
{                                                          \
    uintptr_t rg = cache.i.v1;                             \
    RG35XX_H_TRACE_RETURN(rg, 1);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}

#define RETURN_2                                           \
{                                                          \
    uintptr_t rg = cache.i.v2;                             \
    RG35XX_H_TRACE_RETURN(rg, 2);                          \
    *lvars++ = rg;                                         \
    goto methodReturn;                                     \
}'''
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
            fprintf(stderr, "RG35XX-JAMVM-H: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_index=%ld\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>", pc_index);
            fflush(stderr); exit(91);
        }
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException, CLASS_CB(obj->class)->name);
        DISPATCH(0, 3);
    })'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
print('Applied RG35XX H node-memory diagnostic')
PY
CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=H; echo name=H-node-memory-trace; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "diagnostic=dump bt.a(int) node memory and returned value; exit 91"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"; cp -f "$BIN" "$OUT/jamvm-H-node-memory-unstripped"; cp -f "$BIN" "$OUT/jamvm-H-node-memory-stripped"
"$STRIP" "$OUT/jamvm-H-node-memory-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"; "$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM H node-memory trace
Dumps the selected b-node pointer and its first 8 machine words immediately before bt.a(int) returns, then guards the known invalid CHECKCAST. Exit 91 on the known low pointer.
EOF
echo BUILD COMPLETE
