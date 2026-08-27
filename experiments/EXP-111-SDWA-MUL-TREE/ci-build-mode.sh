#!/usr/bin/env bash
set -euo pipefail
MODE="${1:?usage: ci-build-mode.sh MODE}"
case "$MODE" in god-gate|history-wide|wide) ;; *) echo "bad mode" >&2; exit 2;; esac
WS="${WORKSPACE:-/workspace}"; BD="${BUILD_DIR:-/build/exp111-$MODE}"
OUT="${OUTPUT:-$WS/experiments/EXP-111-SDWA-MUL-TREE/libvulkan_radeon-exp111-$MODE.so}"
cd /opt/mesa
git reset --hard HEAD >/dev/null
git clean -fdx >/dev/null
git apply "$WS/bc250-fsr4-v3.patch"
python3 "$WS/experiments/EXP-111-SDWA-MUL-TREE/materialize_exp111.py" /opt/mesa "$MODE" --dense-threshold 1024

# Structural validation: assert the transformation, not comments/docstrings.
python3 - <<'PY'
from pathlib import Path
radv = Path('src/amd/vulkan/radv_shader.c').read_text()
aco = Path('src/amd/compiler/aco_optimizer.cpp').read_text()
helper_start = radv.index('bc250_lower_dense_sdot4x8_one')
helper_end = radv.index('static bool', helper_start + 32)
helper = radv[helper_start:helper_end]
assert helper.count('nir_op_imul24_relaxed') == 4, helper.count('nir_op_imul24_relaxed')
assert 'nir_imad24_ir3' not in helper
assert 'bool bc250_dense_i24 = false;' in aco
assert 'ctx.bc250_dense_i24 = bc250_i24_mul_count >= 1024;' in aco
needle = 'if (!ctx.bc250_dense_i24)'
assert needle in aco
idx = aco.index(needle)
assert 'add_opt(v_mul_i32_i24, v_mad_i32_i24' in aco[idx:idx+256]
print('EXP111_STRUCTURE_OK')
PY

MESON_ARGS=(-Dbuildtype=release -Dwrap_mode=nodownload -Dvulkan-drivers=amd -Dgallium-drivers=radeonsi -Dllvm=enabled)
if [ -f "$BD/meson-private/coredata.dat" ]; then meson setup --reconfigure "$BD" "$PWD" "${MESON_ARGS[@]}"; else meson setup "$BD" "$PWD" "${MESON_ARGS[@]}"; fi
ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
mkdir -p "$(dirname "$OUT")"; cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "EXP111_CI_READY mode=$MODE output=$OUT"
