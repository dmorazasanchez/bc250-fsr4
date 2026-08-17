#!/bin/bash
set -e
WS="${WORKSPACE:-/workspace}"
BD="${BUILD_DIR:-/build}"
VARIANT="${VARIANT:-patch}"

if [ "$VARIANT" = "patch" ]; then
    OUT="$BD/libvulkan_radeon.so"
else
    OUT="$BD/stock/libvulkan_radeon-stock.so"
    BD="$BD/stock"
fi

cd /opt/mesa
if [ "$VARIANT" = "patch" ]; then
    git apply "$WS/v2-patches/0001-gfx1013-compute-queue-fix.patch"
    git apply "$WS/bc250-fsr4-v2-selective-sdot.patch"
    git apply "$WS/v2-patches/0003-radv-gfx103.patch"
fi

# Match the known-good EXP-028 build configuration used for runtime and
# shader-corpus validation. Do not add host-specific -march/-mtune flags here:
# keeping the compiler inputs equivalent matters more than CPU-side tuning.
meson setup "$BD" "$PWD" \
      -Dbuildtype=release \
      -Dwrap_mode=nodownload \
      -Dvulkan-drivers=amd \
      -Dgallium-drivers=radeonsi \
      -Dllvm=enabled

meson compile -C "$BD"

cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
echo "Built [$VARIANT]: $OUT"
