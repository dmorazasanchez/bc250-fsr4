#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOD_RELEASE="${GOD_RELEASE:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26}"
GOD_LIB="${GOD_LIB:-$GOD_RELEASE/libvulkan_radeon.so}"
GOD_ICD="${GOD_ICD:-$GOD_RELEASE/radv-code-god.json}"
SEARCH_ROOT="${SEARCH_ROOT:-/home/david/fsr4-custom/investigation}"
OUTROOT="${OUTROOT:-/home/david/fsr4-custom/investigation/experiments/EXP-112-SDOT-TOPOLOGY-PK16}"
JOBS="${JOBS:-$(nproc)}"

if [ "$#" -gt 0 ]; then
  MODES=("$@")
else
  # Do not start by compiling every aggressive mode blindly. Census and the
  # EXP111 control come first, followed by the two direct constant policies.
  MODES=(census sdwa-ref const-sdwa const-fused topology-auto family-auto)
fi

for mode in "${MODES[@]}"; do
  case "$mode" in
    census|sdwa-ref|const-sdwa|const-fused|topology-auto|family-auto) ;;
    *) echo "Unknown EXP112 mode: $mode" >&2; exit 2 ;;
  esac
done

for x in python3 rsync meson ninja sha256sum find; do
  command -v "$x" >/dev/null || { echo "Missing dependency: $x" >&2; exit 2; }
done
[ -f "$GOD_LIB" ] || { echo "Missing frozen GOD library: $GOD_LIB" >&2; exit 2; }
[ -f "$GOD_ICD" ] || { echo "Missing frozen GOD ICD: $GOD_ICD" >&2; exit 2; }
mkdir -p "$OUTROOT"

GOD_SHA="$(sha256sum "$GOD_LIB" | awk '{print $1}')"
echo "FROZEN_GOD_SHA256=$GOD_SHA"

find_source_root() {
  if [ -n "${GOD_SRC:-}" ]; then
    [ -f "$GOD_SRC/src/amd/vulkan/radv_shader.c" ] && \
    [ -f "$GOD_SRC/src/amd/compiler/aco_optimizer.cpp" ] || return 1
    printf '%s\n' "$GOD_SRC"
    return 0
  fi

  local so sha p
  while IFS= read -r -d '' so; do
    sha="$(sha256sum "$so" 2>/dev/null | awk '{print $1}')" || continue
    [ "$sha" = "$GOD_SHA" ] || continue
    p="$(dirname "$so")"
    while [ "$p" != / ]; do
      if [ -f "$p/src/amd/vulkan/radv_shader.c" ] && \
         [ -f "$p/src/amd/compiler/aco_optimizer.cpp" ]; then
        printf '%s\n' "$p"
        return 0
      fi
      p="$(dirname "$p")"
    done
  done < <(find "$SEARCH_ROOT" -type f -name libvulkan_radeon.so -print0 2>/dev/null)
  return 1
}

GOD_SRC_RESOLVED="$(find_source_root)" || {
  echo "EXP112_ABORT: exact frozen-GOD source tree not found" >&2
  echo "Set GOD_SRC=/path/to/the/source/tree-that-built-CODE-GOD if necessary." >&2
  exit 3
}

echo "GOD_SOURCE=$GOD_SRC_RESOLVED"
printf '%s\n' "$GOD_SRC_RESOLVED" > "$OUTROOT/GOD-SOURCE.txt"
printf '%s  %s\n' "$GOD_SHA" "$GOD_LIB" > "$OUTROOT/GOD-SHA256.txt"

copy_god_source() {
  local dst="$1"
  rsync -a \
    --exclude='/.git/' \
    --exclude='/build/' \
    --exclude='/build-*/' \
    --exclude='/cache/' \
    --exclude='/cache-*/' \
    "$GOD_SRC_RESOLVED/" "$dst/"

  for required in \
      src/util/build_id.c \
      src/amd/vulkan/radv_shader.c \
      src/amd/compiler/aco_optimizer.cpp; do
    [ -f "$dst/$required" ] || {
      echo "EXP112_ABORT: required GOD source missing after copy: $required" >&2
      exit 4
    }
  done
}

make_icd() {
  python3 - "$GOD_ICD" "$1" "$2" <<'PY'
import json, sys
src, so, dst = sys.argv[1:]
d = json.load(open(src))
d.setdefault('ICD', {})['library_path'] = so
with open(dst, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
PY
}

for mode in "${MODES[@]}"; do
  echo "================ EXP112 $mode ================"
  D="$OUTROOT/$mode"
  SRC="$D/mesa"
  BD="$D/build"
  CACHE="$D/cache"
  SO="$D/libvulkan_radeon-exp112-$mode.so"
  JSON="$D/radv-exp112-$mode.json"

  rm -rf "$SRC" "$BD"
  mkdir -p "$SRC" "$CACHE"
  copy_god_source "$SRC"

  python3 "$HERE/materialize_exp112.py" "$SRC" "$mode"

  echo "EXP112_STRUCTURE mode=$mode"
  grep -n 'EXP112_CENSUS' "$SRC/src/amd/vulkan/radv_shader.c" | head || true
  if [ "$mode" != census ]; then
    grep -n -A4 -B2 '^bc250_lower_dense_sdot4x8_one(' \
      "$SRC/src/amd/vulkan/radv_shader.c" | head -40 || true
  fi

  meson setup "$BD" "$SRC" \
    -Dbuildtype=release \
    -Dwrap_mode=nodownload \
    -Dvulkan-drivers=amd \
    -Dgallium-drivers=radeonsi \
    -Dllvm=enabled

  ninja -C "$BD" -j"$JOBS" src/amd/vulkan/libvulkan_radeon.so
  cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$SO"
  make_icd "$SO" "$JSON"
  sha256sum "$SO" | tee "$D/SHA256SUMS"

  if command -v vulkaninfo >/dev/null 2>&1; then
    ACO_DEBUG= \
    VK_DRIVER_FILES="$JSON" \
    VK_ICD_FILENAMES="$JSON" \
      vulkaninfo --summary > "$D/vulkaninfo-summary.txt" 2>&1
    grep -q 'AMD BC-250 (RADV GFX1013)' "$D/vulkaninfo-summary.txt" || {
      cat "$D/vulkaninfo-summary.txt"
      echo "EXP112_ABORT: Vulkan device creation failed for $mode" >&2
      exit 5
    }
  fi

  cat > "$D/STEAM-LAUNCH-OPTIONS.txt" <<EOF
ACO_DEBUG= MESA_SHADER_CACHE_DIR=$CACHE VK_DRIVER_FILES=$JSON VK_ICD_FILENAMES=$JSON PROTON_FSR4_UPGRADE=4.1.1 FSR4_UPGRADE=1 MANGOHUD=1 %command% --launcher-skip
EOF

  cat > "$D/CENSUS-LAUNCH-OPTIONS.txt" <<EOF
ACO_DEBUG= BC250_EXP112_CENSUS=1 MESA_SHADER_CACHE_DISABLE=true MESA_SHADER_CACHE_DIR=$CACHE VK_DRIVER_FILES=$JSON VK_ICD_FILENAMES=$JSON PROTON_FSR4_UPGRADE=4.1.1 FSR4_UPGRADE=1 MANGOHUD=1 %command% --launcher-skip
EOF

  echo "EXP112_READY mode=$mode"
  echo "NORMAL_LAUNCH=$(cat "$D/STEAM-LAUNCH-OPTIONS.txt")"
  echo "CENSUS_LAUNCH=$(cat "$D/CENSUS-LAUNCH-OPTIONS.txt")"
done

echo "EXP112_BUILT_MODES=${MODES[*]}"
