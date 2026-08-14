# Box provisioning

Decided in [#10](https://github.com/matthusby/agent_coding_bench/issues/10).
How a fresh AMD dev-cloud MI300X box becomes a ready world.

## Shape

The operator creates a bare AMD Dev Cloud box and passes its IPv4 address to
`bin/provision-box <ip>` on the Mac. The local helper updates a managed `Host
box` block in `~/.ssh/config`, copies this repo's idempotent
`box/provision.sh`, runs it as root, and opens the tunnels. Cloud creation and
destruction stay manual; everything after the box has an IP is automated.

The remote script checks the MI300X host capacity, then clones the public
serving repo at commit `7c06e57ee4c9cd6c4ba4d70e8a6422aa6d5562f0` into
`/root/dev/deepseek-v4-flash-mi300x`. It downloads the digest-pinned image and
model revision, verifies `SHA256SUMS`, and starts only the `inference` Compose
service. It never edits the serving repo's checksum-audited files. Caddy is not
needed because the bench uses SSH-only networking.

## What the script installs

- **Toolchains** — checksum-verified `mise`, with pinned versions of
  Erlang/Elixir, Python, and Node, plus the package managers required by the
  current slate (Bun, uv, and Yarn). Versions live in the script so a
  re-provisioned box is the same box.
- **opencode** — pinned via `npm i -g opencode-ai@<version>`; the exact
  version is chosen at build time for compatibility with the
  `opencode_sdk` pin (0.1.88).
- **opencode systemd unit** — `opencode serve --hostname 127.0.0.1 --port
  4096`, `Restart=always`. Loopback-only, **no auth**: ssh is the only way
  onto the box, so the rig carries zero secrets end to end. The EventRelay's
  reconnect logic pairs with systemd's restart. The unit carries
  `InaccessiblePaths=/sys/kernel/debug` and `PrivateDevices=yes`; agents
  inherit its mount namespace, so both apply to every command they spawn.
- **debugfs disabled** — `sys-kernel-debug.mount` is masked and unmounted.
  Reading `/sys/kernel/debug/dri/*/amdgpu_evict_vram` evicts every VRAM buffer
  object; against a live vLLM the eviction never converges, so the GPU drops to
  roughly 1% of its throughput and the reading process wedges unkillably inside
  the syscall. Agents run as root, so one `grep -r` from `/` reaches it.
  Nothing in the stack needs debugfs — `rocm-smi` reads `/sys/class/drm`, and
  the serving container has no debugfs mount. Read-only hardening such as
  `ProtectKernelTunables` does not help, because the trigger is a read.
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

The bench publishes no public services; the helper leaves unrelated
pre-existing host services, including Caddy, unmanaged. Its own vLLM and
opencode listeners bind box loopback. The managed `~/.ssh/config` entry carries
ControlMaster plus two `LocalForward`s: `8000 → 127.0.0.1:8000` (vLLM via the
sidecar) and `4096 → 127.0.0.1:4096` (opencode). All `runtime.exs` URLs are
`localhost`. `bin/provision-box` opens the tunnel after remote verification; it
is not kept alive by autossh.

Provisioning itself runs over a second, forward-free multiplexed connection on
its own control socket, closed before the tunnel opens. Fresh box images
rate-limit inbound SSH — ufw's default `limit` rule on :22 rejects the 6th new
connection in 30s, and fail2ban sits behind it — so a connection-per-step run
locks itself out partway through, and the readiness probe backs off
exponentially for the same reason. Two connections per provision, not one per
step. Tunnel down means the world crash-loops until
stopped, which is the accepted no-preflight behavior.

## Verification

The remote script ends with a verify step:

- vLLM `/metrics` answers on `127.0.0.1:8000` (sidecar + serving stack up)
- opencode `GET /doc` answers on `127.0.0.1:4096` (unit running)
- every mirror present and readable
- each toolchain resolves via `mise exec`

The local helper then verifies both endpoints through the SSH forwards. There
is still no app-side preflight and no separate Mix verification task: discovery
is `runtime.exs` config, and a world started against a dead box crash-loops.
