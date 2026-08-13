# Box provisioning

Decided in [#10](https://github.com/matthusby/agent_coding_bench/issues/10).
How a fresh AMD dev-cloud MI300X box becomes a ready world.

## Shape

One idempotent bash script, `box/provision.sh`, living in this repo. Run it
by scp'ing to the box and executing as root. Every step checks before it
acts, so re-running is safe — though the normal move on a broken box is a
fresh box.

**Layered on the serving stack.** The script assumes vLLM is already up per
the serving repo's runbook (`~/dev/deepseek-v4-flash-mi300x`); it verifies
that precondition and never manages, edits, or restarts anything the
serving stack owns. In particular `compose.yaml` there is checksum-audited
— the bench touches nothing checksummed.

## What the script installs

- **Toolchains** — `mise`, with pinned versions of Erlang/Elixir, Python,
  and Node (the slate needs exactly these three). Versions live in the
  script so a re-provisioned box is the same box.
- **opencode** — pinned via `npm i -g opencode-ai@<version>`; the exact
  version is chosen at build time for compatibility with the
  `opencode_sdk` pin (0.1.88).
- **opencode systemd unit** — `opencode serve --hostname 127.0.0.1 --port
  4096`, `Restart=always`. Loopback-only, **no auth**: ssh is the only way
  onto the box, so the rig carries zero secrets end to end. The EventRelay's
  reconnect logic pairs with systemd's restart.
- **`opencode.json`** — written by the script: the vLLM provider
  (`@ai-sdk/openai-compatible`, `baseURL: http://127.0.0.1:8000/v1`, model
  id = the served model name, `limit.context` matching `--max-model-len`),
  `"permission": "allow"`, `enabled_providers: ["vllm"]`,
  `autoupdate: false`, `share: "disabled"`.
- **socat sidecar** — vLLM's port 8000 is unpublished (compose-network
  only), so the script runs a small proxy container joined to the compose
  network, publishing `127.0.0.1:8000` → `inference:8000` with
  `--restart unless-stopped`. Docker DNS re-resolves `inference` per
  connection, so it survives inference restarts. This one loopback endpoint
  serves both opencode on the box and the Mac's tunnel.
- **Git identity** — a fixed bench identity (`git config --global`) so
  Coder commits on clones are attributable and non-interactive.

## World repo layout

- **Mirrors**: `/root/world/mirrors/<slug>.git` — one bare clone per World
  Repo, fetched from upstream once at provisioning, never updated after.
  Upstream is hit exactly once per repo, ever.
- **Lane clones**: `/root/world/lanes/<n>/<slug>` — created **on demand by
  the app** (via `Box.exec`) from the local mirror when lanes scale up;
  near-instant. Provisioning pre-creates none, so the lane knob moves
  freely without re-provisioning. Normal abandon-reset stays
  `git reset --hard` on the clone's own drifted main; nuke-and-reclone
  from the mirror is the escape hatch for a wrecked clone.

## Cache warming

Last install step: one throwaway dep-install per World Repo (`mix
deps.get`, `npm install`, pip — per toolchain) in a scratch clone, deleted
afterward. Clones stay pristine; the box's global hex/npm/pip caches end
up warm, so a lane clone's first dep resolution is local and the world's
opening minutes measure vLLM, not package CDNs.

## Networking: ssh only

Nothing public but sshd. The Mac's `~/.ssh/config` entry for the box (the
same one `Box.exec` leans on) carries ControlMaster plus two
`LocalForward`s: `8000 → 127.0.0.1:8000` (vLLM via the sidecar) and
`4096 → 127.0.0.1:4096` (opencode). All `runtime.exs` URLs are
`localhost`. Opening the tunnel is manual — `ssh -fN box` before starting
the world; no autossh. Tunnel down means the world crash-loops until
stopped, which is exactly the no-preflight behavior the architecture
already accepts.

## Verification

The script ends with a verify step — the only verification anywhere:

- vLLM `/metrics` answers on `127.0.0.1:8000` (sidecar + serving stack up)
- opencode `GET /doc` answers on `127.0.0.1:4096` (unit running)
- every mirror present and readable
- each toolchain resolves via `mise exec`

No app-side preflight and no separate mix task, per the architecture
decision: discovery is `runtime.exs` config, and a world started against a
dead box just crash-loops.
