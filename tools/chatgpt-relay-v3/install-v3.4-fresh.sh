#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/v2/tools/chatgpt-relay-v3"
APP="bc250-relay-v3"
BIN_DIR="$HOME/.local/bin"
CFG_DIR="$HOME/.config/$APP"
DATA_DIR="$HOME/.local/share/$APP"
UNIT_DIR="$HOME/.config/systemd/user"
CFG="$CFG_DIR/config.json"
SERVICE="$UNIT_DIR/$APP.service"
WATCHDOG="$BIN_DIR/$APP-watchdog"
WATCHDOG_SERVICE="$UNIT_DIR/$APP-watchdog.service"
WATCHDOG_TIMER="$UNIT_DIR/$APP-watchdog.timer"

usage() {
  cat <<'EOF'
Fresh install of BC-250 Relay v3.4.

Usage:
  install-v3.4-fresh.sh --repo OWNER/PRIVATE_QUEUE_REPO --root /workspace [--root /other/workspace]

Options:
  --repo OWNER/REPO       GitHub repository used as the relay queue. A private repo is strongly recommended.
  --root PATH             Workspace root the relay may operate from. Repeatable; at least one is required.
  --queue-prefix PREFIX   Queue directory in the repo (default: relay-v3).
  --http-port PORT        Local dashboard/API port (default: 8765).
  --max-timeout SECONDS   Maximum shell-job timeout (default: 1800).
  -h, --help              Show this help.

Prerequisites: Linux, Python 3, curl, GitHub CLI (gh), systemd --user, and an authenticated gh session.
EOF
}

REPO=""
QUEUE_PREFIX="relay-v3"
HTTP_PORT=8765
MAX_TIMEOUT=1800
ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --root) ROOTS+=("${2:-}"); shift 2 ;;
    --queue-prefix) QUEUE_PREFIX="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --max-timeout) MAX_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "--repo is required" >&2; exit 2; }
[[ ${#ROOTS[@]} -gt 0 ]] || { echo "At least one --root is required" >&2; exit 2; }
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || { echo "--http-port must be numeric" >&2; exit 2; }
[[ "$MAX_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--max-timeout must be numeric" >&2; exit 2; }

for cmd in python3 curl gh systemctl; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "Authenticate GitHub first: gh auth login" >&2; exit 1; }
gh api "repos/$REPO" >/dev/null || { echo "Cannot access GitHub repo: $REPO" >&2; exit 1; }

mkdir -p "$BIN_DIR" "$CFG_DIR" "$DATA_DIR" "$UNIT_DIR"

TMPDIR_RELAY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RELAY"' EXIT
curl -fsSL "$SOURCE_BASE/bc250_relay_v3.py"   -o "$TMPDIR_RELAY/base.py"
curl -fsSL "$SOURCE_BASE/bc250_relay_v3_2.py" -o "$TMPDIR_RELAY/v32.py"
curl -fsSL "$SOURCE_BASE/bc250_relay_v3_3.py" -o "$TMPDIR_RELAY/v33.py"
curl -fsSL "$SOURCE_BASE/bc250_relay_v3_4.py" -o "$TMPDIR_RELAY/v34.py"
python3 -m py_compile "$TMPDIR_RELAY/base.py" "$TMPDIR_RELAY/v32.py" "$TMPDIR_RELAY/v33.py" "$TMPDIR_RELAY/v34.py"
install -m 0755 "$TMPDIR_RELAY/base.py" "$BIN_DIR/bc250-relay-v3"
install -m 0755 "$TMPDIR_RELAY/v32.py"  "$BIN_DIR/bc250-relay-v3.2"
install -m 0755 "$TMPDIR_RELAY/v33.py"  "$BIN_DIR/bc250-relay-v3.3-core"
install -m 0755 "$TMPDIR_RELAY/v34.py"  "$BIN_DIR/bc250-relay-v3.4"

python3 - "$CFG" "$REPO" "$QUEUE_PREFIX" "$HTTP_PORT" "$MAX_TIMEOUT" "${ROOTS[@]}" <<'PY'
import json, os, pathlib, secrets, sys
cfg_path = pathlib.Path(sys.argv[1])
repo, prefix = sys.argv[2], sys.argv[3]
port, max_timeout = int(sys.argv[4]), int(sys.argv[5])
roots = [str(pathlib.Path(p).expanduser().resolve()) for p in sys.argv[6:]]
for root in roots:
    if not pathlib.Path(root).exists():
        raise SystemExit(f"workspace root does not exist: {root}
")
old = {}
if cfg_path.exists():
    try:
        old = json.loads(cfg_path.read_text())
    except Exception:
        old = {}
cfg = {
    "protocol": "BC250_RELAY_V3",
    "repo": repo,
    "queue_prefix": prefix,
    "token": old.get("token") or secrets.token_urlsafe(32),
    "dashboard_key": old.get("dashboard_key") or secrets.token_urlsafe(18),
    "allowed_roots": roots,
    "poll_seconds": 3,
    "heartbeat_seconds": 300,
    "shell": "/bin/bash",
    "max_timeout": max_timeout,
    "http_host": "127.0.0.1",
    "http_port": port,
}
cfg_path.parent.mkdir(parents=True, exist_ok=True)
tmp = cfg_path.with_suffix(".tmp")
tmp.write_text(json.dumps(cfg, indent=2) + "\n")
os.chmod(tmp, 0o600)
tmp.replace(cfg_path)
PY

# The strict v3.3/v3.4 transport expects jobs/ and control/ to exist.
ensure_keep() {
  local rel="$1"
  local path="$QUEUE_PREFIX/$rel/.keep"
  if ! gh api "repos/$REPO/contents/$path" >/dev/null 2>&1; then
    local content
    content=$(python3 - <<'PY'
import base64
print(base64.b64encode(b'{}\n').decode())
PY
)
    gh api --method PUT "repos/$REPO/contents/$path" \
      -f message="relay v3.4 bootstrap $rel" \
      -f content="$content" >/dev/null
  fi
}
ensure_keep jobs
ensure_keep control

cat > "$SERVICE" <<'EOF'
[Unit]
Description=BC-250 Relay v3.4 indexed durable transport
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/bc250-relay-v3.4
Restart=always
RestartSec=3
KillMode=control-group
TimeoutStopSec=8

[Install]
WantedBy=default.target
EOF

cat > "$WATCHDOG" <<'EOF'
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
if [[ "$active" -gt 0 ]]; then exit 0; fi
n=0; [[ -f "$STATE" ]] && n=$(cat "$STATE" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$STATE"
if [[ "$n" -ge 3 ]]; then
  echo 0 > "$STATE"
  systemctl --user restart bc250-relay-v3.service
fi
EOF
chmod +x "$WATCHDOG"

# Patch the health port into the watchdog if a non-default port was requested.
if [[ "$HTTP_PORT" != 8765 ]]; then
  python3 - "$WATCHDOG" "$HTTP_PORT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); port=sys.argv[2]
p.write_text(p.read_text().replace('127.0.0.1:8765', f'127.0.0.1:{port}'))
PY
fi

cat > "$WATCHDOG_SERVICE" <<'EOF'
[Unit]
Description=BC-250 Relay health watchdog
After=bc250-relay-v3.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/bc250-relay-v3-watchdog
EOF

cat > "$WATCHDOG_TIMER" <<'EOF'
[Unit]
Description=Check BC-250 Relay every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now bc250-relay-v3.service >/dev/null
systemctl --user enable --now bc250-relay-v3-watchdog.timer >/dev/null

healthy=0
for _ in {1..30}; do
  if python3 - "$HTTP_PORT" <<'PY'
import json, sys, urllib.request
port=sys.argv[1]
try:
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=2) as r:
        d=json.load(r)
    raise SystemExit(0 if d.get('ok') and d.get('relay_version') == '3.4' else 1)
except Exception:
    raise SystemExit(1)
PY
  then healthy=1; break; fi
  sleep 1
done

if [[ "$healthy" != 1 ]]; then
  echo "Relay did not become healthy." >&2
  journalctl --user -u bc250-relay-v3.service -n 80 --no-pager >&2 || true
  exit 1
fi

manifest_ok=0
for _ in {1..20}; do
  if gh api "repos/$REPO/contents/$QUEUE_PREFIX/status/queue.json" -H 'Accept: application/vnd.github.raw' 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("relay_version")=="3.4" and isinstance(d.get("pending"),list) else 1)' \
      >/dev/null 2>&1; then
    manifest_ok=1; break
  fi
  sleep 1
done
[[ "$manifest_ok" == 1 ]] || { echo "Relay is healthy, but queue.json was not published." >&2; exit 1; }

TOKEN=$(python3 - "$CFG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['token'])
PY
)
DASHBOARD_KEY=$(python3 - "$CFG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['dashboard_key'])
PY
)

cat <<EOF

BC-250 Relay v3.4 is healthy.
Queue repo:     $REPO
Queue prefix:   $QUEUE_PREFIX
Health:         http://127.0.0.1:$HTTP_PORT/health
Dashboard:      http://127.0.0.1:$HTTP_PORT/?key=$DASHBOARD_KEY

Relay token (KEEP PRIVATE; give it only to the trusted client/ChatGPT session that will submit jobs):
$TOKEN

For an always-on headless host, consider enabling user lingering:
  loginctl enable-linger "$USER"

Next: read README.md and examples/CHATGPT_INSTRUCTIONS.md.
EOF
