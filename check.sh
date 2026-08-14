#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/libvulkan_radeon.so"
ICD="$DIR/radv-bc250-fsr4.json"
status=0

if [[ ! -f "$LIB" ]]; then
  echo "FAIL: missing $LIB"
  echo "      Use a release package or copy a matching Mesa build here."
  exit 1
fi

if command -v readelf >/dev/null; then
  mapfile -t deps < <(readelf -d "$LIB" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  if ((${#deps[@]} == 0)); then
    echo "WARN: no shared-library dependencies found in $LIB"
  elif command -v ldconfig >/dev/null && cache="$(ldconfig -p 2>/dev/null)"; then
    for dep in "${deps[@]}"; do
      if ! grep -Fq "$dep" <<< "$cache"; then
        echo "FAIL: dependency not found by ldconfig: $dep"
        status=1
      fi
    done
  else
    echo "WARN: cannot query ldconfig cache; dependencies required by $LIB:"
    printf '      %s\n' "${deps[@]}"
  fi
else
  echo "WARN: readelf not found; skipping dependency scan"
fi

if "$DIR/setup.sh" >/dev/null; then
  echo "OK: ICD generated at $ICD"
else
  status=1
fi

if command -v python3 >/dev/null && [[ -f "$ICD" ]]; then
  python3 -m json.tool "$ICD" >/dev/null || status=1
fi

cat <<EOF

To verify the selected driver on the BC-250 machine:
  VK_DRIVER_FILES="$ICD" vulkaninfo --summary

Expected: driverName=radv, driverInfo contains Mesa 26.1.6, and the device is GFX1013/BC-250.
EOF

exit "$status"
