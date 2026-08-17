#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/libvulkan_radeon.so"
ICD="$DIR/radv-bc250-fsr4.json"
status=0

if [[ ! -f "$LIB" ]]; then
  echo "FAIL: missing $LIB"
  echo "      Build v2 first with ./build-anywhere.sh."
  exit 1
fi

if command -v readelf >/dev/null 2>&1; then
  mapfile -t deps < <(readelf -d "$LIB" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  if command -v ldconfig >/dev/null 2>&1; then
    cache="$(ldconfig -p 2>/dev/null || true)"
    for dep in "${deps[@]}"; do
      if ! grep -Fq "$dep" <<< "$cache"; then
        echo "FAIL: dependency not found by ldconfig: $dep"
        status=1
      fi
    done
  else
    echo "WARN: ldconfig unavailable; dependency presence was not verified"
  fi
else
  echo "WARN: readelf unavailable; dependency scan skipped"
fi

if "$DIR/setup.sh" >/dev/null; then
  echo "OK: ICD generated at $ICD"
else
  status=1
fi

if command -v python3 >/dev/null 2>&1 && [[ -f "$ICD" ]]; then
  if python3 -m json.tool "$ICD" >/dev/null; then
    echo "OK: ICD JSON is valid"
  else
    echo "FAIL: ICD JSON is invalid"
    status=1
  fi
fi

cat <<EOF

Runtime verification:
  VK_DRIVER_FILES="$ICD" vulkaninfo --summary

Expected driver: RADV / Mesa 26.2.0 on AMD BC-250 (GFX1013).
EOF

exit "$status"
