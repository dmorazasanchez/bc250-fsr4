# BC-250 Relay v3.4 — reproducible setup

BC-250 Relay is a small Linux daemon that lets a trusted ChatGPT session (or another client with GitHub access) submit bounded jobs to a Linux machine through a private GitHub repository.

It was built for remote BC-250 development, where ChatGPT does the analysis and the BC-250 host performs builds, tests, log collection and file inspection.

```text
ChatGPT / trusted client
        |
        | writes JSON job
        v
private GitHub queue repo
  relay-v3/jobs/
        |
        | polls every ~3 s
        v
BC-250 Relay v3.4 on Linux
        |
        | executes locally
        v
workspace / build / benchmark
        |
        | writes canonical JSON result
        v
private GitHub queue repo
  relay-v3/results/
        |
        v
ChatGPT / trusted client
```

## What v3.4 adds

- Fixed-path queue manifest at `relay-v3/status/queue.json`, so a client does not need reliable private-repository directory listing/search to discover the queue.
- Durable local job ledger.
- Conservative at-most-once recovery after relay crashes/restarts.
- Result publish -> verify -> delete-job ordering.
- One active job per session.
- Process-group timeout and cancellation for shell jobs.
- Malformed JSON quarantine: a broken job cannot permanently block polling.
- Local health endpoint and dashboard.
- Watchdog that does not restart the relay while a real command is active.
- Full stdout/stderr saved locally when GitHub result output is clipped.
- Relay authentication token is **not** written into v3.4 status/hello files.

## Requirements

- Linux with `systemd --user`
- Python 3
- `curl`
- GitHub CLI (`gh`)
- a GitHub account authenticated with `gh auth login`
- a **private GitHub repository** dedicated to the queue (strongly recommended)

The queue repository can be empty. The installer creates the required queue directories.

## Fresh installation

Download the fresh installer:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/relay-v3.4-reproducible/tools/chatgpt-relay-v3/install-v3.4-fresh.sh \
  -o /tmp/install-relay.sh
chmod +x /tmp/install-relay.sh
```

Install it with your private queue repository and the workspaces that the relay is allowed to start operations from:

```bash
/tmp/install-relay.sh \
  --repo YOUR_GITHUB_USER/YOUR_PRIVATE_QUEUE_REPO \
  --root "$HOME/bc250-fsr4" \
  --root "$HOME/sharpemu"
```

The installer:

1. verifies `gh` authentication and repository access;
2. downloads the tested v3/v3.2/v3.3/v3.4 relay layers;
3. creates `~/.config/bc250-relay-v3/config.json` with mode `0600`;
4. generates a random relay token and dashboard key;
5. bootstraps `relay-v3/jobs/` and `relay-v3/control/`;
6. installs the `systemd --user` service and watchdog timer;
7. starts v3.4;
8. verifies `/health` and the fixed-path `queue.json` manifest;
9. prints the private token once for the trusted client.

For an always-on/headless host you may also want:

```bash
loginctl enable-linger "$USER"
```

## Verify the daemon

```bash
curl -fsS http://127.0.0.1:8765/health | python3 -m json.tool
systemctl --user status bc250-relay-v3.service
systemctl --user status bc250-relay-v3-watchdog.timer
```

A healthy v3.4 response contains:

```json
{
  "ok": true,
  "protocol": "BC250_RELAY_V3",
  "relay_version": "3.4"
}
```

The queue manifest should exist at:

```text
relay-v3/status/queue.json
```

## Sessions

The current BC-250 build provides three independent scheduler sessions:

| Session | Intended use |
|---|---|
| `fsr4` | Mesa / RADV / FSR4 work |
| `ps5` | SharpEmu / PS5-emulation work |
| `vcn` | VCN / SMU work |

Only one job runs at a time in each session, while different sessions can run independently.

## Canonical job format

Filename:

```text
relay-v3/jobs/<session>--<job_id>.json
```

The JSON `job_id` is **unprefixed**:

```json
{
  "protocol": "BC250_RELAY_V3",
  "token": "YOUR_PRIVATE_RELAY_TOKEN",
  "session": "fsr4",
  "job_id": "mesa-status-001",
  "op": "shell",
  "cwd": "/home/you/bc250-fsr4",
  "command": "git status --short --branch",
  "timeout": 30
}
```

Canonical result:

```text
relay-v3/results/fsr4--mesa-status-001.json
```

Do not submit a second payload with the same `(session, job_id)`. v3.3+ hashes payloads and rejects ID reuse with different content.

## Supported operations

The stack supports:

- `ping`
- `shell`
- `cancel`
- `read_file`
- `write_file`
- `git_status`
- `git_diff`
- `list_files`
- session/control operations added by v3.2+

Shell jobs have bounded timeouts. Timeout/cancel targets the process group, so child build processes are terminated too.

## Queue visibility rule

For ChatGPT, read this first:

```text
relay-v3/status/queue.json
```

Do **not** depend on GitHub code search or a recursive directory listing of a private `jobs/` directory. The fixed manifest exists specifically because those mechanisms can be unreliable for private queues.

`queue.json` reports pending jobs, malformed/quarantined jobs, inflight jobs, claimed sessions, active jobs and session modes.

## Large/complex jobs

Avoid embedding enormous quote-heavy Bash programs directly into JSON. That is how malformed `\\escape` jobs happen.

For a long experiment:

1. put the shell script in a repository/file;
2. submit a tiny relay job that downloads/executes that script;
3. let the relay return the result.

This keeps queue JSON small, auditable and difficult to corrupt.

## Durable/at-most-once behavior

The local ledger lives under:

```text
~/.local/share/bc250-relay-v3/job-state-v33/
```

v3.4 follows this sequence:

```text
mark running locally
    -> execute
    -> store result locally
    -> publish result to GitHub
    -> GET result back and verify
    -> delete job file
    -> mark published locally
```

If a completed result exists locally after a restart, it is republished without re-running the command. If the relay died while a job was recorded as `running`, it returns `interrupted_previous_relay_instance; command was not re-executed` rather than blindly running a potentially destructive command twice.

No shell relay can guarantee mathematical exactly-once execution across every possible machine crash. v3.4 intentionally prefers conservative **at-most-once** behavior.

## Controls

Control JSON files are placed under:

```text
relay-v3/control/
```

Actions include:

- `PAUSE`
- `RESUME`
- `STOP`
- `NOTE`
- `PRIORITY`
- `CLEAR_PRIORITY`

`STOP` also asks the runner to terminate a command currently executing in that session.

## Local API/dashboard

Health is unauthenticated but bound to loopback by default:

```bash
curl http://127.0.0.1:8765/health
```

Authenticated local jobs use `X-Relay-Token`.

The installer prints the dashboard URL containing its random dashboard key. Do not expose the API/dashboard publicly unless you understand the authentication and network implications.

## Security

Read `SECURITY.md` before using `shell` jobs.

The important point: this is intentionally a **remote command-execution bridge for a trusted owner**. `allowed_roots` constrains relay file operations and validates a shell job's initial working directory; it is **not a shell sandbox**. A shell command has the normal permissions of the Unix account running the service.

Keep the queue private. Keep the token private. Run the relay as an unprivileged user. Do not put unrelated secrets into the queue repository.

## ChatGPT setup

See:

```text
examples/CHATGPT_INSTRUCTIONS.md
```

Paste those instructions into the trusted ChatGPT conversation and provide the freshly generated relay token privately in that conversation.

## Self-test

After installation:

```bash
bash tools/chatgpt-relay-v3/relay-self-test.sh fsr4
```

It submits a real `ping` through GitHub, waits for the canonical result, verifies it and prints the JSON.
