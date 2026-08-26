#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXP="$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON"
PROBE_LIB="$EXP/libvulkan_radeon-exp103.so"
GOD_ICD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
LOG="$EXP/results-4x8"
mkdir -p "$LOG"

if [ ! -f "$PROBE_LIB" ]; then
    echo "Missing probe driver: $PROBE_LIB" >&2
    echo "Run: experiments/EXP-103-GFX1013-DOT-SILICON/build-exp103-anywhere.sh" >&2
    exit 1
fi
if [ ! -f "$GOD_ICD" ]; then
    echo "Missing GOD ICD: $GOD_ICD" >&2
    exit 1
fi

ABS_LIB="$(readlink -f "$PROBE_LIB")"
PROBE_ICD="$EXP/radv-exp103-dot-probe.json"
printf '%s\n' "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"$ABS_LIB\",\"api_version\":\"1.4.0\"}}" > "$PROBE_ICD"

cd "$ROOT/bench"
python3 gen_kernels.py 8 64 _mini
python3 gen_kernels.py
gcc -O2 -Wall -Wextra -o bench bench.c -lvulkan

run_capture() {
    local name="$1"; shift
    set +e
    "$@" >"$LOG/$name.out" 2>"$LOG/$name.isa"
    local rc=$?
    set -e
    echo "$rc" >"$LOG/$name.rc"
    echo "=== $name (rc=$rc) ==="
    cat "$LOG/$name.out"
    grep -Eo 'v_dot4c_i32_i8|v_dot4_i32_i8|v_dot4_u32_u8|v_mad_i32_i24|v_mul_i32_i24|v_mad_u32_u24|v_mul_u32_u24' "$LOG/$name.isa" | sort | uniq -c | sort -nr || true
}

COMMON=(env -u ACO_DEBUG MESA_SHADER_CACHE_DISABLE=true)

echo '=== GOD SOFTWARE BASELINES ==='
run_capture god-sdot-mini "${COMMON[@]}" RADV_DEBUG=shaders VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench dot_sdot_mini.spv sdot 64 8 fast
run_capture god-udot-mini "${COMMON[@]}" RADV_DEBUG=shaders VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench dot_udot_mini.spv udot 64 8 fast

echo '=== RAW SDOT4 CONTROL ==='
run_capture probe-sdot4-mini "${COMMON[@]}" BC250_DOT_PROBE=sdot4 RADV_DEBUG=shaders VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD" ./bench dot_sdot_mini.spv sdot 64 8 fast

if ! grep -q 'v_dot4_i32_i8' "$LOG/probe-sdot4-mini.isa"; then
    echo 'EXP103 INVALID: SDOT4 mode did not emit v_dot4_i32_i8.' >&2
    exit 3
fi
if [ "$(cat "$LOG/probe-sdot4-mini.rc")" -eq 0 ]; then
    echo 'EXP103 SURPRISE: native SDOT4 passed. Do not continue automatically; re-audit known hardware result.' >&2
    exit 4
fi

echo 'Known-broken SDOT4 control reproduced.'

echo '=== RAW UDOT4 CANDIDATE ==='
run_capture probe-udot4-mini "${COMMON[@]}" BC250_DOT_PROBE=udot4 RADV_DEBUG=shaders VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD" ./bench dot_udot_mini.spv udot 64 8 fast

if ! grep -q 'v_dot4_u32_u8' "$LOG/probe-udot4-mini.isa"; then
    echo 'EXP103 INVALID: UDOT4 mode did not emit v_dot4_u32_u8.' >&2
    exit 5
fi
if [ "$(cat "$LOG/probe-udot4-mini.rc")" -ne 0 ]; then
    echo 'EXP103 RESULT: UDOT4_FAIL. Kill unsigned-bias route.'
    exit 10
fi

echo 'EXP103 RESULT: UDOT4_CORRECT. Running throughput A/B.'

for r in 1 2 3 4 5; do
    echo "=== GOD UDOT software run $r ==="
    "${COMMON[@]}" VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench dot_udot.spv udot 16384 16 | tee "$LOG/god-udot-perf-$r.out"
    echo "=== native UDOT4 run $r ==="
    "${COMMON[@]}" BC250_DOT_PROBE=udot4 VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD" ./bench dot_udot.spv udot 16384 16 | tee "$LOG/probe-udot4-perf-$r.out"
done

python3 - "$LOG" <<'PY'
import pathlib,re,statistics,sys
p=pathlib.Path(sys.argv[1])
def vals(prefix):
    out=[]
    for f in sorted(p.glob(prefix+'*.out')):
        m=re.search(r'best:\s*([0-9.]+) ms\s+throughput:\s*([0-9.]+) Gdot/s',f.read_text())
        if m: out.append((float(m.group(1)),float(m.group(2))))
    return out
for name,prefix in [('GOD_SOFTWARE','god-udot-perf-'),('NATIVE_UDOT4','probe-udot4-perf-')]:
    v=vals(prefix)
    print(name,'runs',len(v),'median_best_ms',statistics.median(x[0] for x in v),'median_Gdot_s',statistics.median(x[1] for x in v))
a=statistics.median(x[0] for x in vals('god-udot-perf-'))
b=statistics.median(x[0] for x in vals('probe-udot4-perf-'))
print('NATIVE_SPEEDUP_X',a/b)
print('NATIVE_TIME_REDUCTION_PCT',(a-b)/a*100.0)
PY

echo EXP103_UDOT4_SURVIVED
