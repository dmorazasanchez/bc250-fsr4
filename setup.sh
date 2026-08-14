#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICD="$DIR/radv-bc250-fsr4.json"

printf "{\n  \"file_format_version\": \"1.0.0\",\n  \"ICD\": {\n    \"library_path\": \"%s/libvulkan_radeon.so\",\n    \"api_version\": \"1.4.0\"\n  }\n}\n" "$DIR" > "$ICD"

echo "Created: $ICD"
echo "Steam launch option:"
echo "VK_DRIVER_FILES=$ICD %command%"
