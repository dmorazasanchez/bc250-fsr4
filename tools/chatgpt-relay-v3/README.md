# BC-250 Relay

The current tested relay is **v3.4**.

Relay turns a private GitHub repository into a durable job queue between a trusted ChatGPT/client session and a Linux BC-250 development host.

For a clean installation on another machine, start here:

**[README-v3.4.md](README-v3.4.md)**

Fresh install:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/relay-v3.4-reproducible/tools/chatgpt-relay-v3/install-v3.4-fresh.sh \
  -o /tmp/install-relay.sh
chmod +x /tmp/install-relay.sh

/tmp/install-relay.sh \
  --repo YOUR_GITHUB_USER/YOUR_PRIVATE_QUEUE_REPO \
  --root "$HOME/YOUR_PROJECT"
```

Then verify the full GitHub round trip with:

```bash
bash tools/chatgpt-relay-v3/relay-self-test.sh fsr4
```

Important files:

- `README-v3.4.md` — architecture, install, protocol, recovery semantics and operations.
- `install-v3.4-fresh.sh` — clean-machine installer pinned to the production-tested v3.4 source snapshot.
- `relay-self-test.sh` — real GitHub queue -> relay -> result round-trip test.
- `examples/CHATGPT_INSTRUCTIONS.md` — client instructions for a ChatGPT session.
- `SECURITY.md` — security model and deployment warnings.

## Security warning

This relay intentionally provides trusted remote command execution. A `shell` job executes with the normal permissions of the Unix account running the service. `allowed_roots` is not a shell sandbox.

Use a private queue repository, keep the relay token secret, run the daemon as an unprivileged user, and read `SECURITY.md` before use.
