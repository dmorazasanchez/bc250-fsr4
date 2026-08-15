#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="bc250-fsr4:builder"

CLEAN=0
[ "$1" = "--clean" ] && CLEAN=1

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
docker run --rm $PLATFORM \
    -v "$DIR:/workspace" \
    -v "$DIR/.build:/build" \
    "$IMG"

if [ "$CLEAN" = "1" ]; then
    docker rmi "$IMG" >/dev/null 2>&1 || true
    echo "Removed builder image: $IMG"
fi
