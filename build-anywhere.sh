#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="bc250-fsr4:builder"

CLEAN=0
VARIANTS=()
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        stock|patch) VARIANTS+=("$arg") ;;
        *) echo "Unknown arg: $arg (expected: stock, patch, or --clean)" >&2; exit 1 ;;
    esac
done
[ "${#VARIANTS[@]}" -eq 0 ] && VARIANTS=(patch)

if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running. Start Docker Desktop, then rerun this script."
    exit 1
fi

PLATFORM=""
if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    echo "Building x86_64 libvulkan_radeon.so under QEMU emulation (slow on ARM)."
    PLATFORM="--platform linux/amd64"
fi

COMMIT="$(head -n1 "$DIR/mesa-commit.txt")"
echo "Using Mesa commit: $COMMIT"
docker buildx build --tag "$IMG" --load $PLATFORM \
    --build-arg MESA_COMMIT="$COMMIT" "$DIR"

mkdir -p "$DIR/.build"
for v in "${VARIANTS[@]}"; do
    echo "=== Building $v variant ==="
    docker run --rm $PLATFORM \
        -e VARIANT="$v" \
        -v "$DIR:/workspace" \
        -v "$DIR/.build:/build" \
        "$IMG"
done

# Copy host-owned .so files into the repo root (build-bc250.sh writes to
# .build so the container doesn't leave root-owned files in the workspace).
for v in "${VARIANTS[@]}"; do
    case "$v" in
        patch) cp "$DIR/.build/libvulkan_radeon.so" "$DIR/libvulkan_radeon.so" ;;
        stock) cp "$DIR/.build/stock/libvulkan_radeon-stock.so" "$DIR/libvulkan_radeon-stock.so" ;;
    esac
done

if [ "$CLEAN" = "1" ]; then
    docker rmi "$IMG" >/dev/null 2>&1 || true
    echo "Removed builder image: $IMG"
fi
