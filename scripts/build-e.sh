#!/usr/bin/env bash
set -euo pipefail

ROOT=/work
TARBALL="$ROOT/source/jamvm-2.0.0.tar.gz"
WORK="$ROOT/work/E"
OUT="$ROOT/dist/E"
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

python3 - "$SRC/src/interp/direct.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '    TRACE("Preparing %s.%s%s\\n", CLASS_CB(mb->class)->name, mb->name, mb->type);\n'
if needle not in s:
    raise SystemExit('ERROR: direct.c prepare marker not found')
insert = needle + r'''

    /* RG35XX E: dump original bytecode before JamVM direct-threaded preparation. */
    if(strcmp(CLASS_CB(mb->class)->name, "bd") == 0 &&
       strcmp(mb->name, "b") == 0 &&
       strcmp(mb->type, "(Ljava/lang/String;)Lz;") == 0) {
        int rg_i;
        fprintf(stderr, "RG35XX-JAMVM-E: ORIGINAL owner=%s method=%s type=%s code_size=%d\n",
                CLASS_CB(mb->class)->name, mb->name, mb->type, code_len);
        for(rg_i = 0; rg_i < code_len; rg_i++) {
            if((rg_i % 16) == 0)
                fprintf(stderr, "RG35XX-JAMVM-E: BC %04d:", rg_i);
            fprintf(stderr, " %02x", code[rg_i]);
            if((rg_i % 16) == 15 || rg_i == code_len - 1)
                fprintf(stderr, "\n");
        }
        fflush(stderr);
    }
'''
s = s.replace(needle, insert, 1)
p.write_text(s)
print('Applied original-bytecode dump patch to direct.c')
PY

python3 - "$SRC/src/interp/engine/interp.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
start_marker = "    DEF_OPC_210(OPC_CHECKCAST_QUICK, {"
end_marker = "        DISPATCH(0, 3);\n    })"
start = s.find(start_marker)
if start < 0:
    raise SystemExit('ERROR: CHECKCAST_QUICK start marker not found')
end = s.find(end_marker, start)
if end < 0:
    raise SystemExit('ERROR: CHECKCAST_QUICK end marker not found')
end += len(end_marker)
old = s[start:end]
if old.count('OPC_CHECKCAST_QUICK') != 1 or 'isInstanceOf' not in old:
    raise SystemExit('ERROR: unexpected CHECKCAST_QUICK block')
new = r'''    DEF_OPC_210(OPC_CHECKCAST_QUICK, {
        Class *class = RESOLVED_CLASS(pc);
        Object *obj = (Object*)ostack[-1];

        if((uintptr_t)obj != 0 && (uintptr_t)obj < 4096) {
            long pc_off = (long)((char*)pc - (char*)mb->code);
            int rg_i;
            int rg_start = pc_off > 48 ? (int)pc_off - 48 : 0;
            int rg_end = (int)pc_off + 24;
            if(rg_end > mb->code_size) rg_end = mb->code_size;
            fprintf(stderr,
                    "RG35XX-JAMVM-E: BAD_CHECKCAST obj=0x%08lx target=%s owner=%s method=%s type=%s pc_off=%ld code_size=%d\n",
                    (unsigned long)(uintptr_t)obj,
                    class ? CLASS_CB(class)->name : "<null>",
                    (mb && mb->class) ? CLASS_CB(mb->class)->name : "<null>",
                    (mb && mb->name) ? mb->name : "<null>",
                    (mb && mb->type) ? mb->type : "<null>",
                    pc_off, mb ? mb->code_size : -1);
            fprintf(stderr,
                    "RG35XX-JAMVM-E: stack[-1]=0x%08lx stack[-2]=0x%08lx stack[-3]=0x%08lx stack[-4]=0x%08lx\n",
                    (unsigned long)ostack[-1],
                    (unsigned long)ostack[-2],
                    (unsigned long)ostack[-3],
                    (unsigned long)ostack[-4]);
            if(mb && mb->code) {
                unsigned char *rg_code = (unsigned char*)mb->code;
                fprintf(stderr, "RG35XX-JAMVM-E: RUNTIME_BYTES start=%d end=%d\n", rg_start, rg_end);
                for(rg_i = rg_start; rg_i < rg_end; rg_i++) {
                    if(((rg_i - rg_start) % 16) == 0)
                        fprintf(stderr, "RG35XX-JAMVM-E: RT %04d:", rg_i);
                    fprintf(stderr, " %02x", rg_code[rg_i]);
                    if(((rg_i - rg_start) % 16) == 15 || rg_i == rg_end - 1)
                        fprintf(stderr, "\n");
                }
            }
            fflush(stderr);
            exit(87);
        }

        if((obj != NULL) && !isInstanceOf(class, obj->class))
            THROW_EXCEPTION(java_lang_ClassCastException,
                            CLASS_CB(obj->class)->name);

        DISPATCH(0, 3);
    })'''
s = s[:start] + new + s[end:]
p.write_text(s)
print('Applied CHECKCAST runtime-byte dump patch to interp.c')
PY

CFLAGS="-O2 -g -mcpu=arm926ej-s -marm -mfloat-abi=soft"
COMMON_CONF="--host=$TRIPLE --prefix=/mnt/mmc/CFW/java --with-classpath-install-dir=/mnt/mmc/CFW/java --disable-shared --without-pic"
{
  echo "mode=E"
  echo "name=E-bytecode-trace"
  echo "triple=$TRIPLE"
  echo "cflags=$CFLAGS"
  echo "configure=$COMMON_CONF"
  echo "diagnostic=dump original bd.b(String):z bytecode before prepare; dump runtime bytes on bad CHECKCAST; exit 87"
  "$CC" --version | head -n 1
} > "$OUT/build-config.txt"

cd "$SRC"
CC="$CC --sysroot=$SYSROOT" CFLAGS="$CFLAGS" ./configure $COMMON_CONF > "$OUT/configure.log" 2>&1
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > "$OUT/build.log" 2>&1
BIN="$(find . -type f -name jamvm -perm -111 | head -n 1)"
[ -n "$BIN" ] || { echo "ERROR: built jamvm binary not found" >&2; exit 10; }
cp -f "$BIN" "$OUT/jamvm"
cp -f "$BIN" "$OUT/jamvm-E-bytecode-trace-unstripped"
cp -f "$BIN" "$OUT/jamvm-E-bytecode-trace-stripped"
"$STRIP" "$OUT/jamvm-E-bytecode-trace-stripped" || true
sha256sum "$OUT/jamvm" "$OUT/jamvm-E-bytecode-trace-unstripped" "$OUT/jamvm-E-bytecode-trace-stripped" > "$OUT/SHA256SUMS.txt"
file "$OUT/jamvm" > "$OUT/file.txt" || true
"$READELF" -h "$OUT/jamvm" > "$OUT/readelf-h.txt"
"$READELF" -A "$OUT/jamvm" > "$OUT/readelf-A.txt" || true
"$READELF" -d "$OUT/jamvm" > "$OUT/readelf-d.txt" || true
"$READELF" -l "$OUT/jamvm" > "$OUT/readelf-l.txt" || true
grep -q "Machine:.*ARM" "$OUT/readelf-h.txt"
cp "$ROOT/rg35xx/RESTORE-ORIGINAL.sh" "$OUT/RESTORE-ORIGINAL.sh"
cat > "$OUT/README-TEST.txt" <<'EOF'
RG35XX JamVM E bytecode trace

Purpose:
- Dump ORIGINAL bytecode of bd.b(Ljava/lang/String;)Lz; before direct-threaded preparation.
- On the known invalid CHECKCAST operand, dump runtime code bytes around the failing PC.
- Exit 87 instead of SIGSEGV.

Keep FreeJ2ME core/runtime/game/config/save unchanged.
EOF
echo "BUILD COMPLETE: E-bytecode-trace"
