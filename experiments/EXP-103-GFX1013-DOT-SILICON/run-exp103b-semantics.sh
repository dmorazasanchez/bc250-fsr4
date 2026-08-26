#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXP="$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON"
PROBE_LIB="$EXP/libvulkan_radeon-exp103.so"
LOG="$EXP/results-semantics"
mkdir -p "$LOG"

if [ ! -f "$PROBE_LIB" ]; then
    echo "Missing already-built EXP103 probe driver: $PROBE_LIB" >&2
    echo "Run the main EXP103 campaign first; EXP103B itself requires no Mesa rebuild." >&2
    exit 1
fi

ABS_LIB="$(readlink -f "$PROBE_LIB")"
PROBE_ICD="$EXP/radv-exp103-dot-probe.json"
printf '%s\n' "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"$ABS_LIB\",\"api_version\":\"1.4.0\"}}" > "$PROBE_ICD"

cd "$ROOT/bench"
python3 gen_kernels.py 1 1 _one
python3 gen_kernels.py 2 1 _two
python3 "$EXP/make_bench_semantics.py" bench.c "$EXP/bench-semantics.c"
gcc -O2 -Wall -Wextra -o "$EXP/bench-semantics" "$EXP/bench-semantics.c" -lvulkan

cd "$EXP"
python3 gen_dot2_kernels.py 1 1 _one
python3 make_bench_dot2.py bench-semantics.c bench-dot2-semantics.c
gcc -O2 -Wall -Wextra -o bench-dot2-semantics bench-dot2-semantics.c -lvulkan

COMMON=(env -u ACO_DEBUG MESA_SHADER_CACHE_DISABLE=true RADV_DEBUG=shaders VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD")

run_case() {
    local family="$1" name="$2" probe="$3" bin="$4" kernel="$5" kind="$6" iter="$7" unroll="$8" a="$9" b="${10}"
    local base="$LOG/${family}-${name}"
    set +e
    "${COMMON[@]}" BC250_DOT_PROBE="$probe" BC250_A="$a" BC250_B="$b" \
       "$bin" "$kernel" "$kind" "$iter" "$unroll" fast >"$base.out" 2>"$base.isa"
    local rc=$?
    set -e
    printf '%s\n' "$rc" >"$base.rc"
    printf '%-9s %-16s rc=%d  ' "$family" "$name" "$rc"
    grep -E 'SEM A=|verify:' "$base.out" | tr '\n' ' '
    grep -m1 'MISMATCH' "$base.isa" 2>/dev/null | tr '\n' ' ' || true
    printf '\n'
}

# Hand-picked packed values. These isolate each byte/half lane and stress sign bits.
VECTORS=(
  'zero:0x00000000:0x00000000'
  'one:0x00000001:0x00000001'
  'lane0:0x0000007f:0x00000003'
  'lane1:0x00007f00:0x00000300'
  'lane2:0x007f0000:0x00030000'
  'lane3:0x7f000000:0x03000000'
  'ones:0x01010101:0x01010101'
  'posmax:0x7f7f7f7f:0x01010101'
  'signbit:0x80808080:0x01010101'
  'minus1:0xffffffff:0x01010101'
  'mixed:0x807f01ff:0x01ff7f80'
  'sentinel:0x538453d8:0xa9728948'
)

echo '=== EXP103B ONE-DOT SDOT4 / UDOT4 SEMANTICS ==='
for v in "${VECTORS[@]}"; do
    IFS=: read -r name a b <<<"$v"
    run_case sdot4-one "$name" sdot4 ./bench-semantics "$ROOT/bench/dot_sdot_one.spv" sdot 1 1 "$a" "$b"
    run_case udot4-one "$name" udot4 ./bench-semantics "$ROOT/bench/dot_udot_one.spv" udot 1 1 "$a" "$b"
done

echo '=== EXP103B TWO-DOT SDOT4 CHAIN (forces first compact accumulation opportunity) ==='
for v in "${VECTORS[@]}"; do
    IFS=: read -r name a b <<<"$v"
    run_case sdot4-two "$name" sdot4 ./bench-semantics "$ROOT/bench/dot_sdot_two.spv" sdot 1 2 "$a" "$b"
done

echo '=== EXP103B ONE-DOT DOT2 SEMANTICS ==='
for v in "${VECTORS[@]}"; do
    IFS=: read -r name a b <<<"$v"
    run_case sdot2-one "$name" dot2 ./bench-dot2-semantics dot_sdot2_one.spv sdot2 1 1 "$a" "$b"
    run_case udot2-one "$name" dot2 ./bench-dot2-semantics dot_udot2_one.spv udot2 1 1 "$a" "$b"
done

echo '=== OPCODE COUNTS ==='
for family in sdot4-one sdot4-two udot4-one sdot2-one udot2-one; do
    echo "[$family]"
    cat "$LOG/$family"-*.isa 2>/dev/null | \
      grep -Eo 'v_dot4c_i32_i8|v_dot4_i32_i8|v_dot4_u32_u8|v_dot2_i32_i16|v_dot2_u32_u16' | \
      sort | uniq -c | sort -nr || true
done

echo '=== MACHINE-READABLE MAP ==='
python3 - "$LOG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
for f in sorted(p.glob('*.out')):
    txt=f.read_text(errors='replace')
    m=re.search(r'SEM A=(0x[0-9a-fA-F]+) B=(0x[0-9a-fA-F]+) GOT=(0x[0-9a-fA-F]+)',txt)
    if not m: continue
    rc=(f.with_suffix('.rc').read_text().strip() if f.with_suffix('.rc').exists() else '?')
    print(f'{f.stem} rc={rc} A={m.group(1)} B={m.group(2)} GOT={m.group(3)}')
PY

echo "EXP103B_RESULTS=$LOG"
echo EXP103B_COMPLETE
