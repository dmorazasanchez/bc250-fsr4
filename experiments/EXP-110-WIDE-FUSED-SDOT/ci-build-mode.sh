#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?usage: ci-build-mode.sh MODE}"
case "$MODE" in
  god-gate-fused|serial-wide|dual-wide|hybrid-wide) ;;
  *) echo "Unknown EXP110 mode: $MODE" >&2; exit 2 ;;
esac

WS="${WORKSPACE:-/workspace}"
BD="${BUILD_DIR:-/build/exp110-$MODE}"
OUT="${OUTPUT:-$WS/experiments/EXP-110-WIDE-FUSED-SDOT/libvulkan_radeon-exp110-$MODE.so}"

cd /opt/mesa
git reset --hard HEAD >/dev/null
git clean -fdx >/dev/null
git apply "$WS/bc250-fsr4-v3.patch"
python3 "$WS/experiments/EXP-110-WIDE-FUSED-SDOT/materialize_exp110.py" /opt/mesa "$MODE"

grep -q 'EXP110: fuse the original SDot accumulator' src/amd/vulkan/radv_shader.c

MESON_ARGS=(
  -Dbuildtype=release
  -Dwrap_mode=nodownload
  -Dvulkan-drivers=amd
  -Dgallium-drivers=radeonsi
  -Dllvm=enabled
)

if [ -f "$BD/meson-private/coredata.dat" ]; then
  meson setup --reconfigure "$BD" "$PWD" "${MESON_ARGS[@]}"
else
  meson setup "$BD" "$PWD" "${MESON_ARGS[@]}"
fi

ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
mkdir -p "$(dirname "$OUT")"
cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
(
  cd "$(dirname "$OUT")"
  sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)

echo "EXP110_CI_READY mode=$MODE output=$OUT"
sha256sum "$OUT"
