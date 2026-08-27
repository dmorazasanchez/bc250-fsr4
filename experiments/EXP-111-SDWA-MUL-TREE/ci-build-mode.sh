#!/usr/bin/env bash
set -euo pipefail
MODE="${1:?usage: ci-build-mode.sh MODE}"
case "$MODE" in god-gate|history-wide|wide|surgical-history) ;; *) echo "bad mode" >&2; exit 2;; esac
WS="${WORKSPACE:-/workspace}"; BD="${BUILD_DIR:-/build/exp111-$MODE}"
OUT="${OUTPUT:-$WS/experiments/EXP-111-SDWA-MUL-TREE/libvulkan_radeon-exp111-$MODE.so}"
cd /opt/mesa
git reset --hard HEAD >/dev/null
git clean -fdx >/dev/null
git apply "$WS/bc250-fsr4-v3.patch"
python3 "$WS/experiments/EXP-111-SDWA-MUL-TREE/materialize_exp111.py" /opt/mesa "$MODE" --dense-threshold 1024

MODE="$MODE" python3 - <<'PY'
import os
from pathlib import Path
mode = os.environ['MODE']
radv = Path('src/amd/vulkan/radv_shader.c').read_text()
aco = Path('src/amd/compiler/aco_optimizer.cpp').read_text()
helper_start = radv.index('bc250_lower_dense_sdot4x8_one')
helper_end = radv.index('static bool', helper_start + 32)
helper = radv[helper_start:helper_end]
assert helper.count('nir_op_imul24_relaxed') == 4
assert 'nir_imad24_ir3' not in helper
assert 'bool bc250_dense_i24 = false;' in aco
assert 'ctx.bc250_dense_i24 = bc250_i24_mul_count >= 1024;' in aco
if mode == 'surgical-history':
    assert 'bc250_sdwa_mul24_contract_cb' in aco
    assert 'a.size() == 1 && a.sign_extend()' in aco
    assert 'b.size() == 1 && b.sign_extend()' in aco
    assert 'add_opt(v_mul_i32_i24, v_mad_i32_i24, 0x3, "120", bc250_sdwa_mul24_contract_cb);' in aco
    assert 'if (!ctx.bc250_dense_i24)' not in aco
else:
    needle = 'if (!ctx.bc250_dense_i24)'
    assert needle in aco
    idx = aco.index(needle)
    assert 'add_opt(v_mul_i32_i24, v_mad_i32_i24' in aco[idx:idx+256]
print(f'EXP111_STRUCTURE_OK mode={mode}')
PY

cat >> src/amd/compiler/tests/test_sdwa.cpp <<'CPP'

BEGIN_TEST(exp111.sdwa.i24_both_signed)
   if (!setup_cs("v1 v1", GFX10))
      return;

   Temp a_byte1 = bld.pseudo(aco_opcode::p_extract, bld.def(v1), inputs[0], Operand::c32(1u),
                             Operand::c32(8u), Operand::c32(1u));
   Temp b_byte2 = bld.pseudo(aco_opcode::p_extract, bld.def(v1), inputs[1], Operand::c32(2u),
                             Operand::c32(8u), Operand::c32(1u));
   writeout(0, bld.vop2(aco_opcode::v_mul_i32_i24, bld.def(v1), a_byte1, b_byte2));
   finish_opt_test();
END_TEST
CPP

MESON_ARGS=(
  -Dbuildtype=release
  -Dwrap_mode=nodownload
  -Dvulkan-drivers=amd
  -Dgallium-drivers=radeonsi
  -Dllvm=enabled
  -Dbuild-aco-tests=true
  -Dtools=drm-shim
)
if [ -f "$BD/meson-private/coredata.dat" ]; then meson setup --reconfigure "$BD" "$PWD" "${MESON_ARGS[@]}"; else meson setup "$BD" "$PWD" "${MESON_ARGS[@]}"; fi

ACO_TARGET="$(ninja -C "$BD" -t targets all | awk -F: '/src\/amd\/compiler\/tests\/aco_tests([^[:alnum:]_]|$)/ {print $1; exit}')"
if [ -z "$ACO_TARGET" ]; then
  echo 'EXP111_ABORT: ACO test target not generated' >&2
  ninja -C "$BD" -t targets all | grep 'amd/compiler/tests' | head -80 >&2 || true
  exit 7
fi
echo "EXP111_ACO_TEST_TARGET=$ACO_TARGET"
ninja -C "$BD" "$ACO_TARGET"
TESTBIN="$BD/$ACO_TARGET"
[ -x "$TESTBIN" ] || { echo "EXP111_ABORT: test binary missing: $TESTBIN" >&2; exit 7; }
"$TESTBIN" --no-check exp111.sdwa.i24_both_signed | tee /tmp/exp111-sdwa-proof.txt
grep -q 'v_mul_i32_i24' /tmp/exp111-sdwa-proof.txt
grep -Eq 'src0_sel:sbyte1.*src1_sel:sbyte2|src1_sel:sbyte2.*src0_sel:sbyte1' /tmp/exp111-sdwa-proof.txt
if grep -q 'p_extract' /tmp/exp111-sdwa-proof.txt; then
  echo 'EXP111_SDWA_PROOF_FAIL: explicit p_extract survived' >&2
  cat /tmp/exp111-sdwa-proof.txt >&2
  exit 6
fi
echo 'EXP111_SDWA_DUAL_SIGNED_PROOF=PASS'

ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
mkdir -p "$(dirname "$OUT")"; cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "EXP111_CI_READY mode=$MODE output=$OUT"
