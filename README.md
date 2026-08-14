# Agent Coding Bench

A living ecosystem of PM, Coder, Reviewer, and Person agents doing realistic
coding work against DeepSeek V4 Flash on one AMD MI300X. Phoenix runs locally;
vLLM, opencode, Mirrors, and Lane-local Clones run on an ephemeral AMD Dev Cloud
box.

## Provision a fresh box

Create a one-MI300X box in AMD Dev Cloud with your SSH key, then run:

```bash
bin/provision-box <box-ip>
```

The helper:

- writes a managed `Host box` block to `~/.ssh/config` without disturbing other
  hosts;
- provisions the box through SSH using [`box/provision.sh`](box/provision.sh);
- installs the pinned serving stack, model, toolchains, and opencode;
- creates all eight World Repo Mirrors and warms their dependency caches; and
- opens SSH forwards for vLLM (`localhost:8000`) and opencode
  (`localhost:4096`).

Ports 8000 and 4096 must be free locally. The helper removes stale host keys for
the supplied ephemeral IP and accepts the new key on first connection.

Caddy is intentionally not started or managed; any pre-existing Caddy service
stays untouched. vLLM is published only on box loopback by a socat sidecar and
reaches the Mac through SSH, so public HTTPS, DNS, and certificates add no
capability to the bench.

Provisioning is idempotent. Re-running the helper against the same box verifies
and repairs the setup without updating existing Mirrors from upstream.

## Run the app

With PostgreSQL running locally:

```bash
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000), start a one-Lane World, and watch
the PM → Coder → Reviewer → Person loop. A successful full-loop acceptance run
ends with a merged Task in Task History.

The World and its Collector are stopped from the dashboard. Stop the SSH tunnel
separately with:

```bash
ssh -O exit box
```

## Development checks

```bash
mix precommit
```

Architecture and operational decisions live in [`docs/design/`](docs/design/).
