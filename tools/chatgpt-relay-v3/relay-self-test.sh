#!/usr/bin/env bash
set -euo pipefail

SESSION="${1:-fsr4}"
case "$SESSION" in
  fsr4|ps5|vcn) ;;
  *) echo "Session must be one of: fsr4 ps5 vcn" >&2; exit 2 ;;
esac

CFG="$HOME/.config/bc250-relay-v3/config.json"
[[ -f "$CFG" ]] || { echo "Missing config: $CFG" >&2; exit 1; }
command -v gh >/dev/null || { echo "Missing gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated" >&2; exit 1; }

readarray -t META < <(python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
print(c['repo'])
print(c.get('queue_prefix','relay-v3'))
print(c['token'])
PY
)
REPO="${META[0]}"
PREFIX="${META[1]}"
TOKEN="${META[2]}"
JOB_ID="selftest-$(date +%s)-$RANDOM"
JOB_PATH="$PREFIX/jobs/$SESSION--$JOB_ID.json"
RESULT_PATH="$PREFIX/results/$SESSION--$JOB_ID.json"

PAYLOAD=$(python3 - "$TOKEN" "$SESSION" "$JOB_ID" <<'PY'
import json,sys
print(json.dumps({
  'protocol':'BC250_RELAY_V3',
  'token':sys.argv[1],
  'session':sys.argv[2],
  'job_id':sys.argv[3],
  'op':'ping'
}, indent=2))
PY
)
CONTENT=$(printf '%s\n' "$PAYLOAD" | python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())')

echo "Submitting $SESSION/$JOB_ID ..."
gh api --method PUT "repos/$REPO/contents/$JOB_PATH" \
  -f message="relay self-test $SESSION $JOB_ID" \
  -f content="$CONTENT" >/dev/null

RESULT=""
for _ in {1..30}; do
  if RESULT=$(gh api "repos/$REPO/contents/$RESULT_PATH" -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
    break
  fi
  sleep 1
done

[[ -n "$RESULT" ]] || { echo "Timed out waiting for $RESULT_PATH" >&2; exit 1; }
printf '%s\n' "$RESULT" | python3 -m json.tool

printf '%s\n' "$RESULT" | python3 - "$JOB_ID" "$SESSION" <<'PY'
import json,sys
jid,session=sys.argv[1],sys.argv[2]
d=json.load(sys.stdin)
assert d.get('relay_version') == '3.4', d
assert d.get('job_id') == jid, d
assert d.get('session') == session, d
assert d.get('status') == 'ok', d
assert (d.get('result') or {}).get('pong') is True, d
PY

echo "PASS: Relay v3.4 GitHub round trip succeeded."
