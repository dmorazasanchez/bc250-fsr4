#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICD="$DIR/radv-bc250-fsr4.json"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "Example: $0 vulkaninfo --summary" >&2
  exit 2
fi

"$DIR/setup.sh" >/dev/null

export VK_DRIVER_FILES="$ICD"
export VK_ICD_FILENAMES="$ICD"

echo "Using BC-250 FSR4 RADV: $DIR/libvulkan_radeon.so"
exec "$@"
