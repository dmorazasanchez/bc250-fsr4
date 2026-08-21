# Security model

BC-250 Relay is a remote execution bridge for a trusted owner. Treat possession of its relay token as equivalent to interactive access to the Unix account running the service.

## What `allowed_roots` does

`allowed_roots` is enforced for relay file operations and for the initial `cwd` of shell jobs. It prevents a client from directly asking relay file APIs to open arbitrary paths outside the configured workspaces.

It is **not a shell sandbox**.

A shell job such as:

```json
{
  "op": "shell",
  "cwd": "/home/you/project",
  "command": "..."
}
```

runs `/bin/bash -lc ...` with the normal permissions of the relay's Unix user. The shell itself can invoke programs, follow symlinks, use the network, change directories, or access anything that Unix account can access.

## Recommended deployment

- Use a dedicated **private** GitHub repository for the queue.
- Limit repository access to the people/clients that are allowed to control the machine.
- Keep the relay token private.
- Run the service as an ordinary, unprivileged Unix user.
- Do not run the daemon itself as root.
- Do not configure passwordless privilege escalation merely for the relay.
- Keep `http_host` at `127.0.0.1` unless you intentionally secure a remote transport.
- Use narrow workspace roots rather than `/` or `$HOME` when practical.
- Review commands before enabling a new automated client.
- Rotate the relay token if it is exposed.

## GitHub history

Do not store the token in queue status files or commit it to the repository. Git commits are durable history even after a file is later deleted.

v3.4 deliberately omits the relay token from `status/hello.json` and other status documents.

The fresh installer prints the token locally. Give it only to the trusted client/session that will submit authenticated jobs.

## Queue contents

Job commands and compact results are committed to the private queue repository during normal operation. Full stdout/stderr artifacts are retained locally under:

```text
~/.local/share/bc250-relay-v3/artifacts/
```

Do not send secrets in commands or output unless you are comfortable with them being present in the queue repository or local artifact history.

## Recovery semantics

v3.4 is deliberately conservative after a crash. If local durable state says a job was executing under a previous relay instance and there is no confirmed completed result, the relay reports an interruption rather than automatically executing the command again.

This reduces the chance that destructive or expensive jobs execute twice, but it does not make arbitrary shell execution transactionally exactly-once.

## Malformed jobs

Malformed JSON is quarantined by v3.4: the daemon writes an error result when possible, verifies it, removes the malformed job and continues polling. This prevents one bad queue file from becoming a denial of service for the entire queue.

## Reporting

If you find a security problem in the relay, do not publish live tokens, private queue URLs, credentials, or other users' command/output data in a public issue.