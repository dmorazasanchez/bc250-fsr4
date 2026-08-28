#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILER="${PROFILER:-/home/david/fsr4-custom/investigation/control/profile_fsr4.py}"
SHADER_DIR="${SHADER_DIR:-/home/david/fsr4-spv}"
OUTROOT="${OUTROOT:-/home/david/fsr4-custom/investigation/experiments/EXP-112-SDOT-TOPOLOGY-PK16}"
PROFILE_ROOT="${PROFILE_ROOT:-$OUTROOT/profiles}"
GOD_ICD="${GOD_ICD:-/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json}"
PROFILE_ACO_DEBUG="${PROFILE_ACO_DEBUG:-}"

AUDIT="$HERE/../EXP-111-SDWA-MUL-TREE/audit_isa.py"
ANALYZE="$HERE/analyze_census.py"

for f in "$PROFILER" "$GOD_ICD" "$AUDIT" "$ANALYZE"; do
  [ -f "$f" ] || { echo "EXP112_CORPUS_ABORT: missing $f" >&2; exit 2; }
done
[ -d "$SHADER_DIR" ] || { echo "EXP112_CORPUS_ABORT: missing shader corpus $SHADER_DIR" >&2; exit 2; }

icd_for() {
  local mode="$1"
  printf '%s/%s/radv-exp112-%s.json\n' "$OUTROOT" "$mode" "$mode"
}

for mode in census sdwa-ref const-sdwa const-fused; do
  icd="$(icd_for "$mode")"
  [ -f "$icd" ] || {
    echo "EXP112_CORPUS_ABORT: missing built mode $mode ($icd)" >&2
    echo "Build it first with: bash $HERE/build-exp112-all.sh $mode" >&2
    exit 3
  }
done

mkdir -p "$PROFILE_ROOT"

echo "EXP112_CORPUS_PROFILER=$PROFILER"
echo "EXP112_CORPUS_SHADER_DIR=$SHADER_DIR"
echo "EXP112_CORPUS_PROFILE_ROOT=$PROFILE_ROOT"
if [ -n "$PROFILE_ACO_DEBUG" ]; then
  echo "EXP112_CORPUS_ACO_DEBUG=$PROFILE_ACO_DEBUG"
else
  echo "EXP112_CORPUS_ACO_DEBUG=<empty>"
fi

run_profile() {
  local label="$1" icd="$2" census="$3"
  local out="$PROFILE_ROOT/$label" log="$PROFILE_ROOT/$label.log"
  rm -rf "$out" "$log"

  local cmd=(python3 "$PROFILER" run --icd "$icd" --output "$out" --shader-dir "$SHADER_DIR")
  if [ -n "$PROFILE_ACO_DEBUG" ]; then
    cmd+=(--aco-debug "$PROFILE_ACO_DEBUG")
  fi

  echo
  echo "================ PROFILE $label ================"
  if [ "$census" = 1 ]; then
    BC250_EXP112_CENSUS=1 "${cmd[@]}" 2>&1 | tee "$log"
  else
    "${cmd[@]}" 2>&1 | tee "$log"
  fi

  [ -f "$out/profile.tsv" ] || {
    echo "EXP112_CORPUS_ABORT: profiler did not create $out/profile.tsv" >&2
    exit 4
  }
  echo "EXP112_PROFILE_READY label=$label profile=$out/profile.tsv"
}

# Topology is measured through the normal offline corpus compiler path, not by
# launching a game. The census mode keeps frozen GOD arithmetic and only adds
# instrumentation before the dense SDOT lowering gate.
run_profile census "$(icd_for census)" 1

echo
echo "================ TOPOLOGY CENSUS ================"
python3 "$ANALYZE" "$PROFILE_ROOT/census" "$PROFILE_ROOT/census.log" | tee "$PROFILE_ROOT/census-summary.txt"

# Fresh same-corpus baseline and the three already-built EXP112 candidates.
run_profile god "$GOD_ICD" 0
run_profile sdwa-ref "$(icd_for sdwa-ref)" 0
run_profile const-sdwa "$(icd_for const-sdwa)" 0
run_profile const-fused "$(icd_for const-fused)" 0

for mode in sdwa-ref const-sdwa const-fused; do
  cmp="$PROFILE_ROOT/compare-god-vs-$mode"
  rm -rf "$cmp"
  echo
  echo "================ COMPARE GOD vs $mode ================"
  python3 "$PROFILER" compare \
    "$PROFILE_ROOT/god/profile.tsv" \
    "$PROFILE_ROOT/$mode/profile.tsv" \
    --output "$cmp"
done

echo
echo "================ EXP112 ISA AUDIT ================"
python3 "$AUDIT" \
  --god "$PROFILE_ROOT/god" \
  --candidate "sdwa-ref=$PROFILE_ROOT/sdwa-ref" \
  --candidate "const-sdwa=$PROFILE_ROOT/const-sdwa" \
  --candidate "const-fused=$PROFILE_ROOT/const-fused" \
  --csv "$PROFILE_ROOT/exp112-audit.csv" | tee "$PROFILE_ROOT/exp112-audit.txt"

echo
echo "EXP112_CORPUS_DONE"
echo "CENSUS_SUMMARY=$PROFILE_ROOT/census-summary.txt"
echo "ISA_AUDIT=$PROFILE_ROOT/exp112-audit.txt"
echo "ISA_CSV=$PROFILE_ROOT/exp112-audit.csv"
echo "PROFILES=$PROFILE_ROOT"
