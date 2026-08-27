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
python3 "$WS/experiments/EXP-111-SDWA-MUL-TREE/materialize_exp111.py" /opt/mesa "$MODE"
grep -q 'EXP111: preserve four VOP2 i24 multiplies' src/amd/vulkan/radv_shader.c
grep -q 'bc250_dense_i24' src/amd/compiler/aco_optimizer.cpp
MESON_ARGS=(-Dbuildtype=release -Dwrap_mode=nodownload -Dvulkan-drivers=amd -Dgallium-drivers=radeonsi -Dllvm=enabled)
if [ -f "$BD/meson-private/coredata.dat" ]; then meson setup --reconfigure "$BD" "$PWD" "${MESON_ARGS[@]}"; else meson setup "$BD" "$PWD" "${MESON_ARGS[@]}"; fi
ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
mkdir -p "$(dirname "$OUT")"; cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "EXP111_CI_READY mode=$MODE output=$OUT"
