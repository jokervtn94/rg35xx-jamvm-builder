#!/usr/bin/env bash
set -euo pipefail
ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/L"
OUT="$ROOT/dist/L"
CROSS_ROOT="${CROSS_ROOT:-/opt/miyoo}"
TRIPLE="${CROSS_TRIPLE:-arm-miyoo-linux-uclibcgnueabi}"
SYSROOT="${SYSROOT:-$CROSS_ROOT/$TRIPLE/sysroot}"
export PATH="$CROSS_ROOT/bin:$PATH"
CC="$TRIPLE-gcc"; READELF="$TRIPLE-readelf"; STRIP="$TRIPLE-strip"
command -v "$CC" >/dev/null; command -v "$READELF" >/dev/null; test -f "$TARBALL"
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'jamvm-*' | head -n1)"; test -n "$SRC"

python3 - "$SRC/src/interp/direct.c" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
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
if old not in s:
    raise SystemExit('ERROR: direct.c ALOAD_0 prepare block not found')
new=r'''                case OPC_ALOAD_0:
                {
#ifdef USE_CACHE
                    if(cache < 2)
                        cache++;
#endif
                    /* Production correctness fix:
                       never fuse ALOAD_0 + GETFIELD into GETFIELD_THIS.
                       Local slot 0 is writable bytecode state (ASTORE_0), so
                       GETFIELD_THIS can observe a stale method-entry receiver.
                       Preserve Java semantics by loading the current local slot. */
                    opcode = OPC_ILOAD_0;
                    pc += 1;
                    break;
                }'''
s=s.replace(old,new,1)
p.write_text(s)
print('Applied JamVM L production ALOAD_0 prepare fix')
PY

CFLAGS="-O2 -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
 echo mode=L; echo name=L-production-aload0-fix; echo triple=$TRIPLE; echo cflags=$CFLAGS; echo "configure=$COMMON_CONF";
 echo "fix=disable unsafe direct.c ALOAD_0+GETFIELD fusion to GETFIELD_THIS";
 echo "diagnostics=none"; echo "guards=none"; "$CC" --version | head -n1;
} > "$OUT/build-config.txt"
cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n1)"; [ -n "$BIN" ] || exit 10
cp -f "$BIN" "$OUT/jamvm"
cp -f "$BIN" "$OUT/jamvm-L-production-unstripped"
cp -f "$BIN" "$OUT/jamvm-L-production-stripped"
"$STRIP" "$OUT/jamvm-L-production-stripped" || true
sha256sum "$OUT"/jamvm* > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"
"$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README.txt" <<'EOF'
RG35XX JamVM L Production

Production build based on the K fix that passed the KDTT crash point.
Only the correctness patch is retained:
- disable unsafe direct-interpreter fusion ALOAD_0 + GETFIELD -> GETFIELD_THIS
- preserve current local-slot-0 semantics after ASTORE_0

Removed from production:
- diagnostic stderr tracing
- low-pointer CHECKCAST exit guards
- test-only instrumentation
EOF
echo BUILD COMPLETE
