#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXP="$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON"
PROBE_LIB="$EXP/libvulkan_radeon-exp103.so"
GOD_ICD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
LOG="$EXP/results-dot2"
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

cd "$EXP"
python3 gen_dot2_kernels.py 8 64 _mini
python3 gen_dot2_kernels.py
python3 make_bench_dot2.py "$ROOT/bench/bench.c" "$EXP/bench-dot2.c"
gcc -O2 -Wall -Wextra -o bench-dot2 bench-dot2.c -lvulkan

run_capture() {
    local name="$1"; shift
    set +e
    "$@" >"$LOG/$name.out" 2>"$LOG/$name.isa"
    local rc=$?
    set -e
    echo "$rc" >"$LOG/$name.rc"
    echo "=== $name (rc=$rc) ==="
    cat "$LOG/$name.out"
    grep -Eo 'v_dot2_i32_i16|v_dot2_u32_u16|v_mad_i32_i24|v_mul_i32_i24|v_mul_lo_u32|v_mul_lo_i32|v_add_[^ ,\t]*' "$LOG/$name.isa" | sort | uniq -c | sort -nr | head -30 || true
}

COMMON=(env -u ACO_DEBUG MESA_SHADER_CACHE_DISABLE=true)

echo '=== GOD DOT2 SOFTWARE BASELINES ==='
run_capture god-sdot2-mini "${COMMON[@]}" RADV_DEBUG=shaders VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench-dot2 dot_sdot2_mini.spv sdot2 64 8 fast
run_capture god-udot2-mini "${COMMON[@]}" RADV_DEBUG=shaders VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench-dot2 dot_udot2_mini.spv udot2 64 8 fast

for kind in sdot2 udot2; do
    op='v_dot2_i32_i16'
    [ "$kind" = udot2 ] && op='v_dot2_u32_u16'

    echo "=== RAW $kind CANDIDATE ==="
    run_capture "probe-$kind-mini" "${COMMON[@]}" BC250_DOT_PROBE=dot2 RADV_DEBUG=shaders VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD" ./bench-dot2 "dot_${kind}_mini.spv" "$kind" 64 8 fast

    if ! grep -q "$op" "$LOG/probe-$kind-mini.isa"; then
        echo "EXP103 $kind INVALID: intended native opcode $op absent." | tee "$LOG/$kind-result.txt"
        continue
    fi

    if [ "$(cat "$LOG/probe-$kind-mini.rc")" -ne 0 ]; then
        echo "EXP103 $kind RESULT: NATIVE_INCORRECT" | tee "$LOG/$kind-result.txt"
        continue
    fi

    echo "EXP103 $kind RESULT: NATIVE_CORRECT" | tee "$LOG/$kind-result.txt"
    for r in 1 2 3 4 5; do
        echo "=== GOD $kind software run $r ==="
        "${COMMON[@]}" VK_DRIVER_FILES="$GOD_ICD" VK_ICD_FILENAMES="$GOD_ICD" ./bench-dot2 "dot_${kind}.spv" "$kind" 16384 16 | tee "$LOG/god-$kind-perf-$r.out"
        echo "=== native $kind run $r ==="
        "${COMMON[@]}" BC250_DOT_PROBE=dot2 VK_DRIVER_FILES="$PROBE_ICD" VK_ICD_FILENAMES="$PROBE_ICD" ./bench-dot2 "dot_${kind}.spv" "$kind" 16384 16 | tee "$LOG/probe-$kind-perf-$r.out"
    done
done

python3 - "$LOG" <<'PY'
import pathlib,re,statistics,sys
p=pathlib.Path(sys.argv[1])

def vals(prefix):
    out=[]
    for f in sorted(p.glob(prefix+'*.out')):
        m=re.search(r'best:\s*([0-9.]+) ms\s+throughput:\s*([0-9.]+) Gdot/s',f.read_text())
        if m:
            out.append((float(m.group(1)),float(m.group(2))))
    return out

for kind in ('sdot2','udot2'):
    a=vals(f'god-{kind}-perf-')
    b=vals(f'probe-{kind}-perf-')
    if not a or not b:
        print(kind,'NO_VALID_NATIVE_PERF_DATA')
        continue
    am=statistics.median(x[0] for x in a)
    bm=statistics.median(x[0] for x in b)
    ag=statistics.median(x[1] for x in a)
    bg=statistics.median(x[1] for x in b)
    print(kind,'GOD_SOFTWARE_MEDIAN_MS',am,'GDOT_S',ag)
    print(kind,'NATIVE_MEDIAN_MS',bm,'GDOT_S',bg)
    print(kind,'NATIVE_SPEEDUP_X',am/bm)
    print(kind,'NATIVE_TIME_REDUCTION_PCT',(am-bm)/am*100.0)
PY

echo EXP103_DOT2_MATRIX_DONE
