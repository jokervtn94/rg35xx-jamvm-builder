#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/K"
OUT="$ROOT/dist/K"
CROSS_ROOT="${CROSS_ROOT:-/opt/miyoo}"
TRIPLE="${CROSS_TRIPLE:-arm-miyoo-linux-uclibcgnueabi}"
SYSROOT="${SYSROOT:-$CROSS_ROOT/$TRIPLE/sysroot}"
export PATH="$CROSS_ROOT/bin:$PATH"
CC="$TRIPLE-gcc"; READELF="$TRIPLE-readelf"; STRIP="$TRIPLE-strip"
command -v "$CC" >/dev/null; command -v "$READELF" >/dev/null; test -f "$TARBALL"
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'jamvm-*' | head -n1)"; test -n "$SRC"

python3 - "$SRC/src/interp/direct.c" "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
pd=Path(sys.argv[1]); sd=pd.read_text()
pi=Path(sys.argv[2]); si=pi.read_text()

old=r'''                case OPC_ALOAD_0:
                {
                    FieldBlock *fb;
#ifdef USE_CACHE
                    if(cache < 2) 
                        cache++;
#endif
                    /* If the next instruction is GETFIELD, this is an instance method
                       and the field is not 2-slots rewrite it to GETFIELD_THIS.  We
                       can safely resolve the field because as an instance method
                       the class must be initialised */

                    if((code[++pc] == OPC_GETFIELD) && !(mb->access_flags & ACC_STATIC)
                                    && (fb = resolveField(mb->class, READ_U2_OP(code + pc)))
                                    && !((*fb->type == 'J') || (*fb->type == 'D'))) {
                        if(*fb->type == 'L' || *fb->type == '[')
                            opcode = OPC_GETFIELD_THIS_REF;
                        else
                            opcode = OPC_GETFIELD_THIS;

                        operand.i = fb->u.offset;
                        pc += 3;
                    } else
                        opcode = OPC_ILOAD_0;
                    break;
                }'''
if old not in sd:
    raise SystemExit('ERROR: direct.c ALOAD_0 prepare block not found')
new=r'''                case OPC_ALOAD_0:
                {
#ifdef USE_CACHE
                    if(cache < 2)
                        cache++;
#endif
                    /* RG35XX K correctness fix.
                       Do NOT fuse ALOAD_0 + GETFIELD into GETFIELD_THIS.
                       Java bytecode may overwrite local slot 0 using ASTORE_0.
                       KDTT bt.a(int) does exactly that: local 0 starts as `this`,
                       then becomes a linked-list node.  GETFIELD_THIS uses the
                       method-entry receiver and therefore reads the wrong object.
                       Preserve Java semantics by loading current local slot 0. */
                    if(strcmp(CLASS_CB(mb->class)->name, "bt") == 0 &&
                       strcmp(mb->name, "a") == 0 &&
                       strcmp(mb->type, "(I)Ljava/lang/Object;") == 0) {
                        fprintf(stderr,
                          "RG35XX-JAMVM-K: PREPARE ALOAD_0 source_pc=%d -> ILOAD_0 current-local semantics\n",
                          pc);
                        fflush(stderr);
                    }
                    opcode = OPC_ILOAD_0;
                    pc += 1;
                    break;
                }'''
sd=sd.replace(old,new,1)
pd.write_text(sd)

# Safety guard only: if the known low pointer survives the actual prepare-layer fix,
# exit 94 rather than crashing natively.
start_marker="    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"; end_marker="        DISPATCH(0, 3);\n    })"
start=si.find(start_marker); end=si.find(end_marker,start)
if start<0 or end<0: raise SystemExit('ERROR: CHECKCAST block not found')
end+=len(end_marker)
replacement=r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];
        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_index = (long)(pc - (CodePntr)mb->code);
            fprintf(stderr, "RG35XX-JAMVM-K: LOWPTR_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_index=%ld\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>", pc_index);
            fflush(stderr); exit(94);
        }
        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException, CLASS_CB(obj->class)->name);
        DISPATCH(0, 3);
    })'''
si=si[:start]+replacement+si[end:]
pi.write_text(si)
print('Applied RG35XX K direct prepare-layer ALOAD_0 correctness fix')
PY

CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=K; echo name=K-direct-prepare-aload0-fix; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "fix=disable direct.c ALOAD_0+GETFIELD fusion to GETFIELD_THIS; preserve current lvars[0] semantics";
 echo "guard=exit 94 on low-pointer CHECKCAST"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"; cp -f "$BIN" "$OUT/jamvm-K-direct-prepare-fix-unstripped"; cp -f "$BIN" "$OUT/jamvm-K-direct-prepare-fix-stripped"
"$STRIP" "$OUT/jamvm-K-direct-prepare-fix-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"; "$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM K direct prepare-layer ALOAD_0 correctness fix

This fixes the actual direct interpreter preparation path. JamVM previously
fused ALOAD_0 + GETFIELD into GETFIELD_THIS for instance methods. That is only
valid while local slot 0 still contains the receiver. KDTT bt.a(int) overwrites
slot 0 with ASTORE_0 and later uses it as a linked-list node, so the fusion reads
the stale entry-time receiver instead of the current local value.

K disables this unsafe fusion and preserves current-local semantics.
If low pointer 0x1 still reaches CHECKCAST, safety guard exits 94.
EOF
echo BUILD COMPLETE
