#!/bin/bash
set -e
WS="${WORKSPACE:-/workspace}"
BD="${BUILD_DIR:-/build}"
TUNE="${TUNE:--march=x86-64-v3 -mtune=znver2}"
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

meson setup "$BD" "$PWD" \
      -Dvulkan-drivers=amd \
      -Dgallium-drivers= \
      -Dbuildtype=release \
      -Dllvm=enabled \
      -Dprefix=/usr \
      -Dc_args="$TUNE" \
      -Dc_link_args="$TUNE" \
      -Dcpp_args="$TUNE" \
      -Dcpp_link_args="$TUNE"

meson compile -C "$BD"

cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
echo "Built [$VARIANT]: $OUT"
