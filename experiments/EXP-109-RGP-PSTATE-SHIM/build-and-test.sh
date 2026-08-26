#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/libbc250-rgp-pstate-shim.so"
GOD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
LOG="${LOG:-/tmp/bc250-rgp-shim-vulkaninfo.log}"
TRIGGER="${TRIGGER:-/tmp/fsr4-trigger}"

command -v gcc >/dev/null
command -v vulkaninfo >/dev/null
[ -f "$GOD" ] || { echo "Missing CODE GOD ICD: $GOD" >&2; exit 2; }

printf 'Building %s\n' "$OUT"
gcc -O2 -fPIC -shared -Wall -Wextra -Werror \
    -o "$OUT" "$HERE/bc250-rgp-pstate-shim.c" -ldl

printf 'Exported symbol:\n'
nm -D "$OUT" | grep ' amdgpu_cs_ctx_stable_pstate$'

rm -f "$TRIGGER" "$LOG"
set +e
BC250_RGP_PSTATE_SHIM_VERBOSE=1 \
LD_PRELOAD="$OUT${LD_PRELOAD:+:$LD_PRELOAD}" \
MESA_VK_TRACE=rgp \
MESA_VK_TRACE_TRIGGER="$TRIGGER" \
RADV_DEBUG=startup \
VK_DRIVER_FILES="$GOD" \
VK_ICD_FILENAMES="$GOD" \
vulkaninfo --summary >"$LOG" 2>&1
rc=$?
set -e

cat "$LOG"
echo "VULKANINFO_RC=$rc"

if [ "$rc" -ne 0 ]; then
    echo 'EXP109_FAIL: pstate bypass was insufficient; inspect the next SQTT/RGP initialization failure above.' >&2
    exit "$rc"
fi

if grep -q 'failed to set new pstate' "$LOG"; then
    echo 'EXP109_FAIL: real stable-pstate SET escaped interposition.' >&2
    exit 20
fi

if ! grep -q 'bc250-rgp-shim: bypass' "$LOG"; then
    echo 'EXP109_FAIL: shim did not intercept libdrm stable-pstate ABI.' >&2
    exit 21
fi

echo 'EXP109_VKCREATEDEVICE_OK'
echo "SHIM=$OUT"
echo "LOG=$LOG"
