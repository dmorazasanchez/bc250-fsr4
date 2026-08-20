#!/usr/bin/env bash
set -euo pipefail
BASE='https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/v2/tools/chatgpt-relay-v3'
BIN="$HOME/.local/bin"
CFG="$HOME/.config/bc250-relay-v3/config.json"
UNIT="$HOME/.config/systemd/user/bc250-relay-v3.service"
CORE="$BIN/bc250-relay-v3.3-core"
ENTRY="$BIN/bc250-relay-v3.3"
TMP1=$(mktemp); TMP2=$(mktemp)
trap 'rm -f "$TMP1" "$TMP2"' EXIT

curl -fsSL "$BASE/bc250_relay_v3_3.py" -o "$TMP1"
curl -fsSL "$BASE/bc250_relay_v3_3_entry.py" -o "$TMP2"
python3 -m py_compile "$TMP1" "$TMP2"
install -m 0755 "$TMP1" "$CORE"
install -m 0755 "$TMP2" "$ENTRY"

TOKEN=$(python3 - "$CFG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['token'])
PY
)
REPO=$(python3 - "$CFG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['repo'])
PY
)
for d in jobs control; do
  path="relay-v33-test/$d/.keep"
  if ! gh api "repos/$REPO/contents/$path" >/dev/null 2>&1; then
    content=$(printf '{}\n' | base64 -w0)
    gh api --method PUT "repos/$REPO/contents/$path" -f message='relay v3.3 sidecar queue' -f content="$content" >/dev/null
  fi
done

BC250_RELAY_HTTP_PORT=8766 BC250_RELAY_QUEUE_PREFIX=relay-v33-test "$ENTRY" >"$HOME/.local/share/bc250-relay-v3/v33-sidecar.log" 2>&1 &
SPID=$!
cleanup_sidecar(){ kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap 'cleanup_sidecar; rm -f "$TMP1" "$TMP2"' EXIT
healthy=0
for _ in {1..20}; do
  if python3 - <<'PY'
import json,sys,urllib.request
try:
  with urllib.request.urlopen('http://127.0.0.1:8766/health',timeout=2) as r:d=json.load(r)
  sys.exit(0 if d.get('ok') and d.get('relay_version')=='3.3' else 1)
except Exception:sys.exit(1)
PY
  then healthy=1; break; fi
  sleep 1
done
if [[ "$healthy" != 1 ]]; then
  echo 'v3.3 sidecar failed; production left untouched.' >&2
  tail -80 "$HOME/.local/share/bc250-relay-v3/v33-sidecar.log" >&2 || true
  exit 1
fi
cleanup_sidecar
trap 'rm -f "$TMP1" "$TMP2"' EXIT

cp -a "$UNIT" "$UNIT.pre-v33" 2>/dev/null || true
cat > "$UNIT" <<'EOF'
[Unit]
Description=BC-250 Relay v3.3 durable transport
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/bc250-relay-v3.3
Restart=always
RestartSec=3
KillMode=control-group
TimeoutStopSec=8

[Install]
WantedBy=default.target
EOF

cat > "$BIN/bc250-relay-v3-watchdog" <<'EOF'
#!/usr/bin/env bash
set -u
STATE="$HOME/.local/share/bc250-relay-v3/watchdog-failures"
body=$(curl -sS --max-time 5 http://127.0.0.1:8765/health 2>/dev/null || true)
read_status=$(printf '%s' "$body" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print(("1" if d.get("ok") else "0")+" "+str(len(d.get("active") or [])))
except Exception: print("0 0")')
set -- $read_status
ok=${1:-0}; active=${2:-0}
if [[ "$ok" == 1 ]]; then echo 0 > "$STATE"; exit 0; fi
# Never restart while a real command is running, even if /health is 503.
if [[ "$active" -gt 0 ]]; then exit 0; fi
n=0; [[ -f "$STATE" ]] && n=$(cat "$STATE" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$STATE"
if [[ "$n" -ge 3 ]]; then
  echo 0 > "$STATE"
  systemctl --user restart bc250-relay-v3.service
fi
EOF
chmod +x "$BIN/bc250-relay-v3-watchdog"

# Do not interrupt a real job just to load the new relay binary.
if systemctl --user is-active --quiet bc250-relay-v3.service; then
  echo 'Waiting for active relay jobs to finish before restart...'
  idle=0
  for _ in {1..900}; do
    body=$(curl -sS --max-time 3 http://127.0.0.1:8765/health 2>/dev/null || true)
    active=$(printf '%s' "$body" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("active") or []))
except Exception: print(0)')
    if [[ "$active" -eq 0 ]]; then idle=1; break; fi
    sleep 1
  done
  if [[ "$idle" != 1 ]]; then
    echo 'Relay still has active jobs; refusing to interrupt them. Re-run upgrade when idle.' >&2
    exit 1
  fi
fi

systemctl --user daemon-reload
systemctl --user restart bc250-relay-v3.service

prod=0
for _ in {1..20}; do
  if python3 - <<'PY'
import json,sys,urllib.request
try:
  with urllib.request.urlopen('http://127.0.0.1:8765/health',timeout=2) as r:d=json.load(r)
  sys.exit(0 if d.get('ok') and d.get('relay_version')=='3.3' else 1)
except Exception:sys.exit(1)
PY
  then prod=1; break; fi
  sleep 1
done
if [[ "$prod" != 1 ]]; then
  echo 'v3.3 production failed health; rolling back service.' >&2
  if [[ -f "$UNIT.pre-v33" ]]; then cp -a "$UNIT.pre-v33" "$UNIT"; systemctl --user daemon-reload; systemctl --user restart bc250-relay-v3.service; fi
  exit 1
fi

echo 'BC-250 Relay v3.3 healthy.'
curl -fsS http://127.0.0.1:8765/health; echo
