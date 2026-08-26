#!/usr/bin/env bash
set -uo pipefail

BASE="${BASE:-/home/david/fsr4-probes}"
REPO="https://github.com/dmorazasanchez/bc250-fsr4.git"
GOD_ICD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
EXP103_DIR="$BASE/exp103"
EXP105_DIR="$BASE/exp105"
SUMMARY="$BASE/RESULTS.txt"

mkdir -p "$BASE"
: > "$SUMMARY"

say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

sync_branch() {
    local dir="$1" branch="$2"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" fetch --depth 1 origin "$branch"
        git -C "$dir" reset --hard FETCH_HEAD
        git -C "$dir" clean -fdx
    else
        rm -rf "$dir"
        git clone --depth 1 --branch "$branch" "$REPO" "$dir"
    fi
}

build103() {
    cd "$EXP103_DIR"
    if bash experiments/EXP-103-GFX1013-DOT-SILICON/build-exp103-native.sh; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo 'Native EXP103 build failed; retrying reproducible Docker builder.' >&2
        bash experiments/EXP-103-GFX1013-DOT-SILICON/build-exp103-anywhere.sh
        return $?
    fi
    return 1
}

build105() {
    cd "$EXP105_DIR"
    if bash experiments/EXP-105-UDOT-SDOT-EMULATION/build-exp105-native.sh; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo 'Native EXP105 build failed; retrying reproducible Docker builder.' >&2
        bash experiments/EXP-105-UDOT-SDOT-EMULATION/build-exp105-anywhere.sh
        return $?
    fi
    return 1
}

publish_result() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        if gh pr comment 6 --repo dmorazasanchez/bc250-fsr4 --body-file "$SUMMARY" >/dev/null 2>&1; then
            echo 'RESULT_PUBLISHED_PR=6'
            return 0
        fi
    fi
    echo "RESULT_NOT_PUBLISHED_LOCAL_ONLY=$SUMMARY"
    return 0
}

if [ ! -f "$GOD_ICD" ]; then
    echo "Missing immutable CODE GOD ICD: $GOD_ICD" >&2
    exit 2
fi
for x in git meson ninja gcc python3 spirv-as spirv-val; do
    if ! command -v "$x" >/dev/null 2>&1; then
        echo "Missing required command: $x" >&2
        exit 3
    fi
done

say '=== BC250 FSR4 INTEGER-DOT SILICON CAMPAIGN ==='
say "GOD_ICD=$GOD_ICD"
say "HOST=$(hostname)"
say "KERNEL=$(uname -r)"

say '=== SYNC EXP103 ==='
sync_branch "$EXP103_DIR" exp103-gfx1013-dot-silicon || exit $?

say '=== BUILD EXP103 ==='
set +e
build103 2>&1 | tee "$BASE/exp103-build.log"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
    say "EXP103_BUILD_FAIL rc=$rc"
    publish_result
    exit "$rc"
fi
say 'EXP103_BUILD_OK'

say '=== RUN EXP103 UDOT4/SDOT CONTROL ==='
set +e
(
  cd "$EXP103_DIR"
  GOD_ICD="$GOD_ICD" bash experiments/EXP-103-GFX1013-DOT-SILICON/run-exp103-4x8.sh
) 2>&1 | tee "$BASE/exp103-4x8.log"
rc4=${PIPESTATUS[0]}
set -e
say "EXP103_4X8_RC=$rc4"

say '=== RUN EXP103 DOT2 REGARDLESS OF UDOT RESULT ==='
set +e
(
  cd "$EXP103_DIR"
  GOD_ICD="$GOD_ICD" bash experiments/EXP-103-GFX1013-DOT-SILICON/run-exp103-dot2.sh
) 2>&1 | tee "$BASE/exp103-dot2.log"
rc2=${PIPESTATUS[0]}
set -e
say "EXP103_DOT2_RC=$rc2"

UDOT_OK=0
R4="$EXP103_DIR/experiments/EXP-103-GFX1013-DOT-SILICON/results-4x8"
if [ -f "$R4/probe-udot4-mini.rc" ] &&
   [ "$(cat "$R4/probe-udot4-mini.rc")" = 0 ] &&
   grep -q 'v_dot4_u32_u8' "$R4/probe-udot4-mini.isa" 2>/dev/null; then
    UDOT_OK=1
fi
say "UDOT4_NATIVE_CORRECT=$UDOT_OK"

if [ "$UDOT_OK" -eq 1 ]; then
    say '=== UDOT SURVIVED: SYNC + BUILD EXP105 ==='
    sync_branch "$EXP105_DIR" exp105-udot-sdot-emulation || exit $?
    set +e
    build105 2>&1 | tee "$BASE/exp105-build.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        say "EXP105_BUILD_FAIL rc=$rc"
        publish_result
        exit "$rc"
    fi
    say 'EXP105_BUILD_OK'

    say '=== RUN EXACT SIGNED SDOT VIA UDOT ==='
    set +e
    (
      cd "$EXP105_DIR"
      GOD_ICD="$GOD_ICD" bash experiments/EXP-105-UDOT-SDOT-EMULATION/run-exp105.sh
    ) 2>&1 | tee "$BASE/exp105-run.log"
    rc105=${PIPESTATUS[0]}
    set -e
    say "EXP105_RC=$rc105"
else
    say 'EXP105_SKIPPED: raw UDOT4 was not proven correct.'
fi

say '=== RESULT MARKERS ==='
grep -hE 'Known-broken|EXP103 RESULT|UDOT4_|NATIVE_CORRECT|NATIVE_INCORRECT|NATIVE_SPEEDUP|TIME_REDUCTION|EXP105|PROMOTE|REJECT|verify:|median_' \
  "$BASE"/exp103-4x8.log "$BASE"/exp103-dot2.log "$BASE"/exp105-run.log 2>/dev/null | tee -a "$SUMMARY" || true

say "FULL_LOGS=$BASE"
say "RESULT_FILE=$SUMMARY"
say 'CAMPAIGN_COMPLETE'
publish_result
