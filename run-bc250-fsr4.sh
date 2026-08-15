#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICD="$DIR/radv-bc250-fsr4.json"

printf "{\n  \"file_format_version\": \"1.0.0\",\n  \"ICD\": {\n    \"library_path\": \"%s/libvulkan_radeon.so\",\n    \"api_version\": \"1.4.0\"\n  }\n}\n" "$DIR" > "$ICD"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <command> [args...]"
    echo "Example: $0 vulkaninfo --summary"
    exit 1
fi

export VK_DRIVER_FILES="$ICD"
echo "Using BC-250 FSR4 RADV: $DIR/libvulkan_radeon.so"
exec "$@"
