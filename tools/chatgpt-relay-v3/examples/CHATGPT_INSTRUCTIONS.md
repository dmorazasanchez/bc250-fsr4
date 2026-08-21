# ChatGPT instructions for BC-250 Relay v3.4

Use the user's connected private GitHub queue repository as the BC-250 Relay v3.4 transport.

## Protocol

- Protocol: `BC250_RELAY_V3`
- Queue prefix: `relay-v3` unless the user configured another prefix.
- Read `relay-v3/status/queue.json` first to understand the current queue/session state.
- Do not rely on GitHub code search to discover private jobs.
- Do not expose or repeat the relay token in user-visible responses.

## Sessions

Use one of:

- `fsr4`
- `ps5`
- `vcn`

The filename is namespaced by session, but the JSON `job_id` is not.

Example:

```text
filename: relay-v3/jobs/fsr4--probe-001.json
job_id:   probe-001
session:  fsr4
```

## Job schema

```json
{
  "protocol": "BC250_RELAY_V3",
  "token": "PRIVATE_TOKEN_SUPPLIED_BY_USER",
  "session": "fsr4",
  "job_id": "probe-001",
  "op": "shell",
  "cwd": "/home/user/project",
  "command": "git status --short --branch",
  "timeout": 30
}
```

Create a new file at:

```text
relay-v3/jobs/<session>--<job_id>.json
```

Then wait for/read exactly:

```text
relay-v3/results/<session>--<job_id>.json
```

Do not reuse `(session, job_id)` for a different payload.

## Queue discipline

Before submitting work:

1. read `relay-v3/status/queue.json`;
2. check whether the intended session is running/paused/stopped;
3. check whether that session already has a claimed/inflight/active job;
4. submit a unique job only when appropriate.

v3.4 enforces one active job per session.

## Long commands

Keep JSON jobs small.

If the experiment needs a large Bash program, many nested quotes, heredocs or extensive escaping, put the script in a file/repository first and use a short relay command to execute it. Do not embed huge scripts directly in JSON.

## Timeouts

Always use a bounded timeout appropriate to the operation.

Examples:

- status/probe: 15-60 s
- incremental build: 300-900 s
- long benchmark/full build: only as long as justified, subject to the relay's configured maximum

Do not use an excessively long timeout merely to avoid checking progress.

## Results

A normal result contains:

```json
{
  "protocol": "BC250_RELAY_V3",
  "relay_version": "3.4",
  "job_id": "probe-001",
  "session": "fsr4",
  "status": "ok",
  "result": {}
}
```

Possible non-success states/errors include:

- `blocked` because the session is paused/stopped;
- command timeout/non-zero exit in the nested shell result;
- `malformed_job_json` for quarantined malformed JSON;
- `interrupted_previous_relay_instance; command was not re-executed` after conservative crash recovery;
- payload/job-id reuse errors.

Large stdout/stderr may be clipped in GitHub. The result reports local artifact paths containing complete output.

## Human-interaction boundary

If the experiment requires the user to look at a game, press a key, judge image quality, interact with Steam/UI, reboot into something manually, or provide another inherently human observation, stop at that boundary and ask the user for the result. Do not invent the observation.

## Safety/recoverability

Prefer reversible changes and preserve project state before risky edits. Never intentionally modify unrelated personal files. Treat shell jobs as real commands on the user's machine, not as a simulation.
