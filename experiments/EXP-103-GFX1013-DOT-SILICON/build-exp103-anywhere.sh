#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG="bc250-fsr4:exp103-dot-probe"
COMMIT="$(head -n1 "$ROOT/mesa-commit.txt")"
PLATFORM=""

if ! docker info >/dev/null 2>&1; then
    echo "Docker is not available/running." >&2
    exit 1
fi

if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    PLATFORM="--platform linux/amd64"
fi

echo "Building EXP103 from Mesa $COMMIT"
docker buildx build --tag "$IMG" --load $PLATFORM \
    --build-arg MESA_COMMIT="$COMMIT" "$ROOT"

mkdir -p "$ROOT/.build/exp103"
docker run --rm $PLATFORM \
    --entrypoint /bin/bash \
    -e WORKSPACE=/workspace \
    -e BUILD_DIR=/build/exp103-dot-probe \
    -e OUTPUT=/workspace/experiments/EXP-103-GFX1013-DOT-SILICON/libvulkan_radeon-exp103.so \
    -v "$ROOT:/workspace" \
    -v "$ROOT/.build:/build" \
    "$IMG" \
    /workspace/experiments/EXP-103-GFX1013-DOT-SILICON/build-exp103.sh

echo
printf 'Built: %s\n' "$ROOT/experiments/EXP-103-GFX1013-DOT-SILICON/libvulkan_radeon-exp103.so"
