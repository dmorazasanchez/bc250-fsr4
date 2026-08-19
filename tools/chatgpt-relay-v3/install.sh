#!/usr/bin/env bash
set -euo pipefail

BIN="$HOME/.local/bin/bc250-relay-v3"
CFG="$HOME/.config/bc250-relay-v3/config.json"
UNIT="$HOME/.config/systemd/user/bc250-relay-v3.service"
URL="https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/v2/tools/chatgpt-relay-v3/bc250_relay_v3.py"

command -v gh >/dev/null || { echo 'github-cli (gh) is required'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Authenticate GitHub first with: gh auth login'; exit 1; }

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
curl -fsSL "$URL" -o "$BIN"
chmod +x "$BIN"

if [[ ! -f "$CFG" ]]; then
  roots=()
  for d in \
    "$HOME/bc250-fsr4-v2-test" \
    "$HOME/fsr4-custom" \
    "$HOME/sharpemu" \
    "$HOME/bc250-smu-unlock" \
    "$HOME/mesa-26.2" \
    "$HOME/mesa" \
    "$HOME/Downloads/PPSA01342-app"; do
    [[ -e "$d" ]] && roots+=(--root "$d")
  done
  if [[ ${#roots[@]} -eq 0 ]]; then
    echo 'No known workspaces found; create/configure one before installing.'
    exit 1
  fi
  "$BIN" init --repo dmorazasanchez/hola "${roots[@]}"
else
  echo "Keeping existing config: $CFG"
fi

cat > "$UNIT" <<'EOF'
[Unit]
Description=BC-250 Relay v3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/bc250-relay-v3 run
Restart=always
RestartSec=3
KillMode=control-group
TimeoutStopSec=8

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now bc250-relay-v3.service

echo
echo 'BC-250 Relay v3 installed.'
echo 'Status: systemctl --user status bc250-relay-v3'
echo 'Logs:   journalctl --user -u bc250-relay-v3 -f'
echo 'Health: curl http://127.0.0.1:8765/health'
echo
echo 'Optional free public HTTPS endpoint (requires Tailscale already configured):'
echo '  tailscale funnel --bg 8765'
