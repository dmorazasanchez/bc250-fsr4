#!/usr/bin/env bash
set -euo pipefail

BIN="$HOME/.local/bin/bc250-relay-v3"
BIN31="$HOME/.local/bin/bc250-relay-v3.1"
CFG="$HOME/.config/bc250-relay-v3/config.json"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/bc250-relay-v3.service"
WATCHDOG_BIN="$HOME/.local/bin/bc250-relay-v3-watchdog"
WATCHDOG_SERVICE="$UNIT_DIR/bc250-relay-v3-watchdog.service"
WATCHDOG_TIMER="$UNIT_DIR/bc250-relay-v3-watchdog.timer"
URL31="https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/v2/tools/chatgpt-relay-v3/bc250_relay_v3_1.py"

[[ -f "$CFG" ]] || { echo "Relay v3 config not found: $CFG"; exit 1; }
command -v gh >/dev/null || { echo 'github-cli (gh) is required'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Authenticate GitHub first with: gh auth login'; exit 1; }

mkdir -p "$HOME/.local/bin" "$UNIT_DIR"
cp -a "$CFG" "$CFG.bak-v3.1-$(date +%Y%m%d-%H%M%S)"
[[ -x "$BIN" ]] || { echo "Base Relay v3 binary missing: $BIN"; exit 1; }
curl -fsSL "$URL31" -o "$BIN31.new"
python3 -m py_compile "$BIN31.new"
mv "$BIN31.new" "$BIN31"
chmod +x "$BIN31"

python3 - "$CFG" <<'PY'
import json,secrets,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d.setdefault('protocol','BC250_RELAY_V3')
d.setdefault('queue_prefix','relay-v3')
d.setdefault('dashboard_key',secrets.token_urlsafe(18))
d['poll_seconds']=min(int(d.get('poll_seconds',5)),5)
d.setdefault('max_timeout',1800)
d.setdefault('http_host','127.0.0.1')
d.setdefault('http_port',8765)
p.write_text(json.dumps(d,indent=2)+'\n')
PY

cat > "$SERVICE" <<'EOF'
[Unit]
Description=BC-250 Relay v3.1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/bc250-relay-v3.1
Restart=always
RestartSec=3
KillMode=control-group
TimeoutStopSec=8

[Install]
WantedBy=default.target
EOF

cat > "$WATCHDOG_BIN" <<'EOF'
#!/usr/bin/env bash
set -u
if python3 - <<'PY'
import json,sys,urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:8765/health',timeout=5) as r:
        d=json.load(r)
    age=(d.get('transport') or {}).get('last_ok_age_s')
    ok=bool(d.get('ok')) and (age is None or age < 180)
except Exception:
    ok=False
sys.exit(0 if ok else 1)
PY
then
  exit 0
fi
systemctl --user restart bc250-relay-v3.service
EOF
chmod +x "$WATCHDOG_BIN"

cat > "$WATCHDOG_SERVICE" <<'EOF'
[Unit]
Description=BC-250 Relay v3.1 health watchdog
After=bc250-relay-v3.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/bc250-relay-v3-watchdog
EOF

cat > "$WATCHDOG_TIMER" <<'EOF'
[Unit]
Description=Check BC-250 Relay v3.1 every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now bc250-relay-v3.service
systemctl --user enable --now bc250-relay-v3-watchdog.timer
systemctl --user restart bc250-relay-v3.service

sleep 2
KEY="$(python3 - "$CFG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['dashboard_key'])
PY
)"

echo
echo 'BC-250 Relay upgraded to v3.1.'
echo 'Health:    curl http://127.0.0.1:8765/health'
echo "Dashboard: http://127.0.0.1:8765/?key=$KEY"
echo 'Watchdog: systemctl --user status bc250-relay-v3-watchdog.timer --no-pager'
echo 'Logs:      journalctl --user -u bc250-relay-v3 -f'
