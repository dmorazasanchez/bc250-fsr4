#!/usr/bin/env bash
set -euo pipefail

WS="${WORKSPACE:-/workspace}"
BD="${BUILD_DIR:-/build/exp103-dot-probe}"
OUT="${OUTPUT:-$WS/experiments/EXP-103-GFX1013-DOT-SILICON/libvulkan_radeon-exp103.so}"

cd /opt/mesa

git reset --hard HEAD >/dev/null
git clean -fdx >/dev/null

git apply "$WS/bc250-fsr4-v3.patch"
git apply "$WS/experiments/EXP-103-GFX1013-DOT-SILICON/exp103-gfx1013-dot-probe.patch"

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

# EXP103 needs only the private RADV ICD. Avoid compiling all Mesa/Gallium.
ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
mkdir -p "$(dirname "$OUT")"
cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
sha256sum "$OUT" > "$OUT.sha256"

echo "EXP103 probe driver: $OUT"
sha256sum "$OUT"
