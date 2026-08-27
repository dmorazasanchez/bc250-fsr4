#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GOD_RELEASE="${GOD_RELEASE:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26}"
GOD_LIB="${GOD_LIB:-$GOD_RELEASE/libvulkan_radeon.so}"
GOD_ICD="${GOD_ICD:-$GOD_RELEASE/radv-code-god.json}"
SEARCH_ROOT="${SEARCH_ROOT:-/home/david/fsr4-custom/investigation}"
OUTROOT="${OUTROOT:-/home/david/fsr4-custom/investigation/experiments/EXP-110-WIDE-FUSED-SDOT}"
JOBS="${JOBS:-$(nproc)}"
MODES=(god-gate-fused serial-wide dual-wide hybrid-wide)

for x in python3 rsync meson ninja sha256sum find; do
    command -v "$x" >/dev/null 2>&1 || { echo "Missing required command: $x" >&2; exit 2; }
done
[ -f "$GOD_LIB" ] || { echo "Missing frozen GOD library: $GOD_LIB" >&2; exit 2; }
[ -f "$GOD_ICD" ] || { echo "Missing frozen GOD ICD: $GOD_ICD" >&2; exit 2; }

mkdir -p "$OUTROOT"
GOD_SHA="$(sha256sum "$GOD_LIB" | awk '{print $1}')"
echo "FROZEN_GOD_SHA256=$GOD_SHA"

find_source_root() {
    if [ -n "${GOD_SRC:-}" ]; then
        [ -f "$GOD_SRC/src/amd/vulkan/radv_shader.c" ] || {
            echo "GOD_SRC does not look like a Mesa source tree: $GOD_SRC" >&2
            return 1
        }
        printf '%s\n' "$GOD_SRC"
        return 0
    fi

    local so sha p
    while IFS= read -r -d '' so; do
        sha="$(sha256sum "$so" 2>/dev/null | awk '{print $1}')" || continue
        [ "$sha" = "$GOD_SHA" ] || continue
        p="$(dirname "$so")"
        while [ "$p" != "/" ]; do
            if [ -f "$p/src/amd/vulkan/radv_shader.c" ]; then
                printf '%s\n' "$p"
                return 0
            fi
            p="$(dirname "$p")"
        done
    done < <(find "$SEARCH_ROOT" -type f -name libvulkan_radeon.so -print0 2>/dev/null)
    return 1
}

if ! GOD_SRC_RESOLVED="$(find_source_root)"; then
    echo "EXP110_ABORT: could not locate the source tree that produced frozen CODE GOD." >&2
    echo "No source was modified. Re-run with GOD_SRC=/path/to/the/exact/GOD/mesa/source." >&2
    exit 3
fi

echo "GOD_SOURCE=$GOD_SRC_RESOLVED"
[ -f "$GOD_SRC_RESOLVED/src/amd/vulkan/radv_shader.c" ]

grep -q 'bc250_lower_dense_sdot4x8_one' "$GOD_SRC_RESOLVED/src/amd/vulkan/radv_shader.c" || {
    echo "EXP110_ABORT: exact GOD source lacks expected dense-SDOT lowering." >&2
    exit 4
}
grep -q 'nir_imad24_ir3' "$GOD_SRC_RESOLVED/src/amd/vulkan/radv_shader.c" || {
    echo "EXP110_ABORT: exact GOD source lacks MAD24 path." >&2
    exit 4
}

printf '%s\n' "$GOD_SRC_RESOLVED" > "$OUTROOT/GOD-SOURCE.txt"
printf '%s  %s\n' "$GOD_SHA" "$GOD_LIB" > "$OUTROOT/GOD-SHA256.txt"

make_icd() {
    local out_so="$1" out_json="$2"
    python3 - "$GOD_ICD" "$out_so" "$out_json" <<'PY'
import json, sys
src, so, dst = sys.argv[1:]
with open(src) as f:
    d = json.load(f)
d.setdefault("ICD", {})["library_path"] = so
with open(dst, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
}

for mode in "${MODES[@]}"; do
    echo
    echo "================ EXP110 $mode ================"
    D="$OUTROOT/$mode"
    SRC="$D/mesa"
    BD="$D/build"
    OUT_SO="$D/libvulkan_radeon-exp110-$mode.so"
    OUT_JSON="$D/radv-exp110-$mode.json"
    CACHE="$D/cache"

    rm -rf "$SRC"
    mkdir -p "$SRC" "$CACHE"
    # Immutable clone-by-copy of the exact GOD source. Never touch GOD itself.
    rsync -a \
      --exclude='.git' \
      --exclude='build' --exclude='build-*' --exclude='cache' --exclude='cache-*' \
      "$GOD_SRC_RESOLVED/" "$SRC/"

    python3 "$HERE/materialize_exp110.py" "$SRC" "$mode"

    ARGS=(
      -Dbuildtype=release
      -Dwrap_mode=nodownload
      -Dvulkan-drivers=amd
      -Dgallium-drivers=radeonsi
      -Dllvm=enabled
    )

    rm -rf "$BD"
    meson setup "$BD" "$SRC" "${ARGS[@]}"
    ninja -C "$BD" -j"$JOBS" src/amd/vulkan/libvulkan_radeon.so
    cp "$BD/src/amd/vulkan/libvulkan_radeon.so" "$OUT_SO"
    make_icd "$OUT_SO" "$OUT_JSON"
    sha256sum "$OUT_SO" | tee "$D/SHA256SUMS"

    if command -v vulkaninfo >/dev/null 2>&1; then
        echo "Smoke-testing $mode on Vulkan loader"
        set +e
        ACO_DEBUG= \
        VK_DRIVER_FILES="$OUT_JSON" \
        VK_ICD_FILENAMES="$OUT_JSON" \
        vulkaninfo --summary >"$D/vulkaninfo-summary.txt" 2>&1
        vkrc=$?
        set -e
        cat "$D/vulkaninfo-summary.txt"
        if [ "$vkrc" -ne 0 ]; then
            echo "EXP110_ABORT: vulkaninfo failed for $mode rc=$vkrc" >&2
            exit "$vkrc"
        fi
        grep -q 'AMD BC-250 (RADV GFX1013)' "$D/vulkaninfo-summary.txt" || {
            echo "EXP110_ABORT: $mode did not enumerate the expected BC-250 device" >&2
            exit 5
        }
        echo "EXP110_VULKAN_OK mode=$mode"
    fi

    cat > "$D/STEAM-LAUNCH-OPTIONS.txt" <<EOF
ACO_DEBUG= MESA_SHADER_CACHE_DIR=$CACHE VK_DRIVER_FILES=$OUT_JSON VK_ICD_FILENAMES=$OUT_JSON PROTON_FSR4_UPGRADE=4.1.1 FSR4_UPGRADE=1 MANGOHUD=1 %command% --launcher-skip
EOF

    echo "EXP110_READY mode=$mode"
    echo "ICD=$OUT_JSON"
    echo "LAUNCH=$(cat "$D/STEAM-LAUNCH-OPTIONS.txt")"
done

echo
echo "EXP110_ALL_BUILT=$OUTROOT"
echo "IMPORTANT: builds are candidates only. No performance claim until full-corpus audit + Cyberpunk A/B."
