#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXP="$ROOT/experiments/EXP-105-UDOT-SDOT-EMULATION"
LIB="$EXP/libvulkan_radeon-exp105.so"
GOD_ICD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
LOG="$EXP/results"
mkdir -p "$LOG"

if [ ! -f "$LIB" ]; then
    echo "Missing EXP105 driver: $LIB" >&2
    echo "Run: ./experiments/EXP-105-UDOT-SDOT-EMULATION/build-exp105-anywhere.sh" >&2
    exit 1
fi
if [ ! -f "$GOD_ICD" ]; then
    echo "Missing CODE GOD ICD: $GOD_ICD" >&2
    exit 1
fi

ABS_LIB="$(readlink -f "$LIB")"
ICD="$EXP/radv-exp105-udot-sdot.json"
printf '%s\n' "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"$ABS_LIB\",\"api_version\":\"1.4.0\"}}" > "$ICD"

cd "$ROOT/bench"
python3 gen_kernels.py 8 64 _mini
python3 gen_kernels.py
gcc -O2 -Wall -Wextra -o bench bench.c -lvulkan

capture() {
    local name="$1"; shift
    set +e
    "$@" >"$LOG/$name.out" 2>"$LOG/$name.isa"
    local rc=$?
    set -e
    printf '%s\n' "$rc" >"$LOG/$name.rc"
    echo "=== $name (rc=$rc) ==="
    cat "$LOG/$name.out"
    echo 'ISA relevant ops:'
    grep -Eo 'v_dot4_u32_u8|v_dot4_i32_i8|v_msad_u8|v_sad_u8|v_mad_i32_i24|v_mul_i32_i24|v_bfe_i32|v_bfe_u32' "$LOG/$name.isa" | sort | uniq -c | sort -nr || true
}

COMMON=(env -u ACO_DEBUG MESA_SHADER_CACHE_DISABLE=true)

echo '=== PRECONDITION: RAW UDOT4 MUST BE REAL AND CORRECT ==='
capture raw-udot4-mini "${COMMON[@]}" BC250_DOT_PROBE=udot4 RADV_DEBUG=shaders VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" ./bench dot_udot_mini.spv udot 64 8 fast

if ! grep -q 'v_dot4_u32_u8' "$LOG/raw-udot4-mini.isa"; then
    echo 'EXP105 BLOCKED: raw UDOT mode did not emit v_dot4_u32_u8.' | tee "$LOG/RESULT.txt"
    exit 20
fi
if [ "$(cat "$LOG/raw-udot4-mini.rc")" -ne 0 ]; then
    echo 'EXP105 BLOCKED: raw v_dot4_u32_u8 is incorrect on GFX1013. Kill UDOT route.' | tee "$LOG/RESULT.txt"
    exit 21
fi

echo 'Raw UDOT4 correctness: PASS'

echo '=== EXACT SIGNED DOT VIA UDOT + BYTE-SUM CORRECTION ==='
capture udot-sdot-mini "${COMMON[@]}" BC250_DOT_PROBE=udot-sdot RADV_DEBUG=shaders VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" ./bench dot_sdot_mini.spv sdot 64 8 fast

if [ "$(cat "$LOG/udot-sdot-mini.rc")" -ne 0 ]; then
    echo 'EXP105 FAIL: exact UDOT-based signed reconstruction is not bit-correct.' | tee "$LOG/RESULT.txt"
    exit 22
fi
if ! grep -q 'v_dot4_u32_u8' "$LOG/udot-sdot-mini.isa"; then
    echo 'EXP105 INVALID: reconstructed SDOT passed but native v_dot4_u32_u8 is absent from ISA.' | tee "$LOG/RESULT.txt"
    exit 23
fi
if grep -q 'v_dot4_i32_i8' "$LOG/udot-sdot-mini.isa"; then
    echo 'EXP105 INVALID: broken signed native dot leaked into reconstructed path.' | tee "$LOG/RESULT.txt"
    exit 24
fi

echo 'Exact UDOT-SDOT correctness: PASS'
if grep -Eq 'v_msad_u8|v_sad_u8' "$LOG/udot-sdot-mini.isa"; then
    echo 'Packed byte-sum instruction present: YES'
else
    echo 'Packed byte-sum instruction present: NO/optimized differently (inspect ISA before integration)'
fi

echo '=== GOD SOFTWARE SDOT ISA ==='
capture god-sdot-mini "${COMMON[@]}" RADV_DEBUG=shaders VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench dot_sdot_mini.spv sdot 64 8 fast
if [ "$(cat "$LOG/god-sdot-mini.rc")" -ne 0 ]; then
    echo 'Invalid baseline: CODE GOD software SDOT correctness failed.' >&2
    exit 25
fi

echo '=== THROUGHPUT: 5 INTERLEAVED PAIRS ==='
for r in 1 2 3 4 5; do
    echo "--- pair $r: GOD software signed dot ---"
    "${COMMON[@]}" VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench dot_sdot.spv sdot 16384 16 | tee "$LOG/god-sdot-perf-$r.out"
    echo "--- pair $r: EXP105 exact UDOT signed dot ---"
    "${COMMON[@]}" BC250_DOT_PROBE=udot-sdot VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" ./bench dot_sdot.spv sdot 16384 16 | tee "$LOG/udot-sdot-perf-$r.out"
done

python3 - "$LOG" <<'PY'
import pathlib,re,statistics,sys
p=pathlib.Path(sys.argv[1])

def vals(prefix):
    out=[]
    for f in sorted(p.glob(prefix+'*.out')):
        t=f.read_text()
        m=re.search(r'kind:\s+\S+\s+median:\s*([0-9.]+) ms\s+best:\s*([0-9.]+) ms\s+throughput:\s*([0-9.]+) Gdot/s',t)
        if not m:
            raise SystemExit(f'cannot parse {f}')
        out.append((float(m.group(1)),float(m.group(2)),float(m.group(3))))
    return out

g=vals('god-sdot-perf-')
u=vals('udot-sdot-perf-')
if len(g)!=5 or len(u)!=5:
    raise SystemExit(f'expected 5+5 perf runs, got {len(g)}+{len(u)}')

g_med=statistics.median(x[0] for x in g)
u_med=statistics.median(x[0] for x in u)
g_bestmed=statistics.median(x[1] for x in g)
u_bestmed=statistics.median(x[1] for x in u)
g_thr=statistics.median(x[2] for x in g)
u_thr=statistics.median(x[2] for x in u)

print('GOD_MEDIAN_DISPATCH_MS',g_med)
print('EXP105_MEDIAN_DISPATCH_MS',u_med)
print('GOD_MEDIAN_OF_BEST_MS',g_bestmed)
print('EXP105_MEDIAN_OF_BEST_MS',u_bestmed)
print('GOD_MEDIAN_GDOT_S',g_thr)
print('EXP105_MEDIAN_GDOT_S',u_thr)
print('EXP105_SPEEDUP_X',g_med/u_med)
print('EXP105_TIME_REDUCTION_PCT',(g_med-u_med)/g_med*100.0)

# Primitive candidate must have a clear margin before it earns expensive
# shader-corpus integration work.
reduction=(g_med-u_med)/g_med*100.0
if reduction >= 20.0:
    verdict='PROMOTE_TO_CORPUS'
elif reduction > 0.0:
    verdict='CORRECT_BUT_MARGIN_TOO_SMALL'
else:
    verdict='REJECT_PERFORMANCE'
print('VERDICT',verdict)
(p/'RESULT.txt').write_text(
    f'EXP105_SPEEDUP_X={g_med/u_med:.6f}\n'
    f'EXP105_TIME_REDUCTION_PCT={reduction:.4f}\n'
    f'VERDICT={verdict}\n')
PY

cat "$LOG/RESULT.txt"
echo EXP105_DONE
