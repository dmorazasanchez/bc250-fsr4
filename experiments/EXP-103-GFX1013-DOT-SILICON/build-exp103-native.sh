#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${BASE:-/home/david/fsr4-probes/native-exp103}"
SRC="$BASE/mesa"
BD="$BASE/build"
OUT="$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON/libvulkan_radeon-exp103.so"
COMMIT="$(head -n1 "$ROOT/mesa-commit.txt")"

for x in git meson ninja gcc; do
    command -v "$x" >/dev/null 2>&1 || { echo "Missing required command: $x" >&2; exit 2; }
done

mkdir -p "$BASE"
if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git init "$SRC"
    git -C "$SRC" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
fi

echo "Fetching exact Mesa base: $COMMIT"
git -C "$SRC" fetch --depth 1 origin "$COMMIT"
git -C "$SRC" reset --hard FETCH_HEAD
git -C "$SRC" clean -fdx

git -C "$SRC" apply "$ROOT/bc250-fsr4-v3.patch"
git -C "$SRC" apply "$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON/exp103-gfx1013-dot-probe.patch"

ARGS=(
  -Dbuildtype=release
  -Dwrap_mode=nodownload
  -Dvulkan-drivers=amd
  -Dgallium-drivers=radeonsi
  -Dllvm=enabled
)

if [ -f "$BD/meson-private/coredata.dat" ]; then
    meson setup --reconfigure "$BD" "$SRC" "${ARGS[@]}"
else
    rm -rf "$BD"
    meson setup "$BD" "$SRC" "${ARGS[@]}"
fi

ninja -C "$BD" src/amd/vulkan/libvulkan_radeon.so
cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT"
(
  cd "$(dirname "$OUT")"
  sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)

echo "EXP103_NATIVE_READY=$OUT"
sha256sum "$OUT"
