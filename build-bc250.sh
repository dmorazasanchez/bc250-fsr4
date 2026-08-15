#!/bin/bash
set -e
WS="${WORKSPACE:-/workspace}"
BD="${BUILD_DIR:-/build}"
TUNE="${TUNE:--march=x86-64-v3 -mtune=znver2}"

cd /opt/mesa
git apply "$WS/bc250-fsr4-i24.patch"

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

cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$WS/libvulkan_radeon.so"
echo "Built: $WS/libvulkan_radeon.so"
