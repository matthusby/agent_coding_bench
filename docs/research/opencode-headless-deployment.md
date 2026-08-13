# Research: headless opencode deployment against a local vLLM endpoint

Resolves issue #4 (part of #1). Researched 2026-08-12 against the official docs
(https://opencode.ai/docs/) and the opencode GitHub repo. Note: the repo moved
from `sst/opencode` to **`anomalyco/opencode`**; the npm package is still
`opencode-ai`. Anything not directly verifiable from a primary source is flagged
**[unverified]**.

## TL;DR

Install with the curl script or `npm i -g opencode-ai`, run one
`opencode serve --port 4096 --hostname 0.0.0.0` process with
`OPENCODE_SERVER_PASSWORD` set for HTTP basic auth, point it at vLLM via a
custom `@ai-sdk/openai-compatible` provider in `opencode.json`
(`baseURL: http://127.0.0.1:8000/v1`), set `"permission": "allow"` for
unattended runs, and drive it over the HTTP API (sessions accept a per-session
working directory). One server handles many sessions; opencode has **no
built-in sandbox** — the disposable box *is* the sandbox.

## 1. Non-interactive Linux install

Source: https://opencode.ai/docs/ (intro/install).

```bash
# official install script (no prompts)
curl -fsSL https://opencode.ai/install | bash
# or, if node is already on the box:
npm install -g opencode-ai
```

Also available: bun/pnpm/yarn, Homebrew (`anomalyco/tap/opencode`), Arch
`pacman -S opencode`, and a Docker image `ghcr.io/anomalyco/opencode`.

No interactive setup is required as long as config is provided via files/env
(below). Recommended headless hygiene in config: `"autoupdate": false`,
`"share": "disabled"` (both documented on https://opencode.ai/docs/config/).

## 2. `opencode serve` — headless server

Source: https://opencode.ai/docs/server/ and https://opencode.ai/docs/cli/.

```bash
OPENCODE_SERVER_PASSWORD="$SECRET" opencode serve --port 4096 --hostname 0.0.0.0
```

- `--port` (docs list default 4096 for `serve`; one secondary source says a
  random port when unset — pin it explicitly and don't rely on the default),
  `--hostname` (default `127.0.0.1`; use `0.0.0.0` for remote access),
  `--cors <origin>` (repeatable), `--mdns` / `--mdns-domain` (skip).
- **Auth:** unauthenticated by default. Setting `OPENCODE_SERVER_PASSWORD`
  enables HTTP **basic auth**; username defaults to `opencode`
  (`OPENCODE_SERVER_USERNAME` overrides). The Elixir client just sends a
  standard `Authorization: Basic ...` header. There is no token/OAuth story.
- The server exposes an **OpenAPI 3.1 spec at `GET /doc`** — generate or
  hand-roll the Elixir client from that; it is the authoritative
  endpoint/schema list for whatever version is installed.
- Useful global flags: `--print-logs` (logs to stderr, good under systemd),
  `--log-level DEBUG|INFO|WARN|ERROR`.

### Driving it over HTTP

Core endpoints (per docs; **verify exact paths/bodies against `/doc` on the
installed version** — opencode is moving to a v2 API where paths are prefixed
`/api/`, e.g. `POST /api/session`, and older docs show unprefixed `/session`):

- `POST /session` — create session (`title`, optional `parentID`; v2 adds
  `agent`, `model`, and `location: { directory, workspaceID? }`).
- `POST /session/:id/message` — send prompt, blocks until the turn completes.
- `POST /session/:id/prompt_async` — fire-and-forget variant.
- `GET /session/:id/message` — list messages.
- `GET /event` — SSE stream of all bus events (message parts, tool calls,
  permission requests). One stream covers all sessions.
- `POST /session/:id/permissions/:permissionID` — answer a permission `ask`
  programmatically (body ~ `{"response": true, "remember": true}`) — only
  needed if you don't blanket-allow.
- `POST /api/session/:id/shell` (v2) — run one shell command in the session's
  working directory.

Message body shape (from docs examples; confirm against `/doc`):

```json
{
  "model": { "providerID": "vllm", "modelID": "qwen3-coder" },
  "parts": [{ "type": "text", "text": "…prompt…" }]
}
```

**[unverified]** The exact `model`/`parts` field names differ between doc
versions (`"model": "name"` vs `{providerID, modelID}`; `content` vs `text`).
Treat `/doc` as truth.

## 3. `opencode.json` — custom vLLM provider

Source: https://opencode.ai/docs/providers/, https://opencode.ai/docs/config/,
https://opencode.ai/docs/models/.

Config merge order (later wins): global `~/.config/opencode/opencode.json` →
`OPENCODE_CONFIG` file → project `opencode.json` → `OPENCODE_CONFIG_CONTENT`
(inline JSON env var — handy for provisioning). JSONC is accepted.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "vllm/qwen3-coder",
  "autoupdate": false,
  "share": "disabled",
  "enabled_providers": ["vllm"],
  "provider": {
    "vllm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local vLLM",
      "options": {
        "baseURL": "http://127.0.0.1:8000/v1",
        "apiKey": "{env:VLLM_API_KEY}"
      },
      "models": {
        "qwen3-coder": {
          "name": "Qwen3 Coder (vLLM)",
          "limit": { "context": 131072, "output": 32768 }
        }
      }
    }
  },
  "permission": "allow"
}
```

- `npm: "@ai-sdk/openai-compatible"` targets `/v1/chat/completions` (what vLLM
  serves); `@ai-sdk/openai` targets `/v1/responses` — use the former.
- The model key (`qwen3-coder` above) must equal vLLM's `--served-model-name`.
- `limit.context` / `limit.output` tell opencode the real window so its context
  tracking/compaction works — match vLLM's `--max-model-len`.
- Default model: `"model": "provider_id/model_id"`.
- **Disabling everything else:** `"enabled_providers": ["vllm"]` (allowlist) or
  `"disabled_providers": [...]` (denylist; takes priority). This stops other
  providers loading and avoids any auth prompting. `opencode auth login` is
  never needed for a config-defined provider.
- **[unverified]** Whether `apiKey` may be omitted entirely for an
  unauthenticated vLLM: docs always show it set. Safe move: run vLLM with
  `--api-key dummy` and set `"apiKey": "dummy"` (or the `{env:...}` form).

## 4. Process model: one server, many sessions

- **One `opencode serve` process hosts many sessions.** Sessions are created
  and addressed over HTTP; the docs' whole design is "one server, multiple
  clients/sessions". No per-session process is spawned by you.
- **Working directory scoping:** the current (v2) API takes the directory at
  session creation (`location: { directory }` on `POST /api/session`), and the
  project spec (`specs/project.md` in anomalyco/opencode) describes one
  instance serving multiple projects/worktrees. So: one server on the box,
  one session per bench task, each pointed at its own checkout directory.
  - **Caveat:** older versions bound all tool execution to the directory the
    server was started in — anomalyco/opencode issue #6697 ("Session switching
    doesn't change working directory context"). If the installed version shows
    this, fall back to **one `opencode serve` per checkout dir** (cheap: pick
    distinct ports, systemd template unit `opencode@.service` with
    `WorkingDirectory=%I`). Verify by creating two sessions with different
    `location.directory` values and running `pwd` via the shell endpoint.
- **Resource footprint at 8+ concurrent sessions:** not documented anywhere
  **[unverified]**. Reasoning from architecture: the server is a single
  Bun/TypeScript process; a session is state + streamed HTTP calls to the
  model, so marginal cost per idle session is small (message history in
  memory/storage). Real load is (a) child processes from the bash tool and
  (b) LSP servers opencode may spawn per project (`lsp` config can disable
  them). Expect the opencode side to be trivial next to vLLM on an MI300X;
  budget order-of-magnitude ~0.5–1 GB RAM for the server + tool children at
  8 sessions, and note vLLM must be configured for 8+ concurrent request
  streams (it batches natively). Measure on the box before trusting this.

## 5. Unattended permissions and sandboxing

Source: https://opencode.ai/docs/permissions/.

Values per key: `"allow"` | `"ask"` | `"deny"`. Keys include `edit`, `bash`
(string or per-command-pattern map), `read`, `webfetch`, `websearch`, `task`,
`skill`, `external_directory`, `doom_loop`. Most default to `allow`;
`doom_loop` and `external_directory` default to `ask`, and `.env` reads are
denied by default.

Fully unattended (fine on a disposable box):

```json
{ "permission": "allow" }
```

Or keep a belt with per-key granularity:

```json
{
  "permission": {
    "edit": "allow",
    "bash": { "*": "allow", "git push *": "deny" },
    "webfetch": "allow",
    "external_directory": "deny",
    "doom_loop": "allow"
  }
}
```

- If anything is left at `"ask"` on a headless server, the request surfaces as
  a permission event on `GET /event` and blocks until answered via
  `POST /session/:id/permissions/:permissionID` — so either blanket-allow or
  have the Elixir driver auto-respond.
- `opencode run --auto` auto-approves non-denied permissions for the one-shot
  CLI path; not needed when config says `allow`.
- **Sandboxing: there is none.** opencode's security docs state the permission
  system is a UX awareness feature, *not* an isolation boundary, and recommend
  Docker/VM for real isolation. Running as root on the ephemeral dev-cloud box
  is acceptable exactly because the box is disposable; the isolation boundary
  is the machine. If any credentials live on the box (HF token, git deploy
  key), scope them minimally — a `bash: allow` agent can read anything root
  can. Optional hardening without ceremony: run under a non-root user via the
  systemd unit (`User=opencode`), and keep `--hostname` on `127.0.0.1` with an
  SSH tunnel/tailnet instead of exposing 0.0.0.0 publicly.

## 6. Suggested box recipe

```bash
curl -fsSL https://opencode.ai/install | bash
mkdir -p ~/.config/opencode && cp opencode.json ~/.config/opencode/   # config from §3
OPENCODE_SERVER_PASSWORD="$SECRET" opencode serve --port 4096 --hostname 0.0.0.0 --print-logs
# smoke test:
curl -u opencode:$SECRET http://BOX:4096/doc | head
```

Then from Elixir: `POST /session` (with per-task directory), stream `GET
/event`, `POST /session/:id/message` per turn.

## Open questions / to verify on the real box

1. v1 (`/session`) vs v2 (`/api/session`) paths and exact message body schema
   — read `GET /doc` from the installed version.
2. Per-session `location.directory` actually re-scopes tools (issue #6697
   regression) — if not, one server per checkout.
3. Whether `apiKey` can be omitted for an unauthenticated vLLM endpoint.
4. Real memory/CPU at 8 concurrent sessions — no published numbers.

## Sources

- Install / docs index: https://opencode.ai/docs/
- Server: https://opencode.ai/docs/server/
- CLI (`serve`, `run`, flags): https://opencode.ai/docs/cli/
- Config (merge order, disabled_providers, autoupdate, share): https://opencode.ai/docs/config/
- Providers (openai-compatible, limits): https://opencode.ai/docs/providers/
- Models: https://opencode.ai/docs/models/
- Permissions: https://opencode.ai/docs/permissions/
- v2 API (session create with `location.directory`, shell endpoint): https://opencode.ai/v2/docs/api/session/v2-session-create, https://opencode.ai/v2/docs/api/session/v2-session-shell
- Repo (now anomalyco): https://github.com/anomalyco/opencode — `specs/project.md`, issue #6697
