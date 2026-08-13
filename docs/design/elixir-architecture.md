# Elixir architecture and build plan

Decided in [#8](https://github.com/matthusby/agent_coding_bench/issues/8).
The map's handoff artifact: everything here is buildable in ordinary
sessions with no open decisions.

## Contexts

Three contexts under the existing `AgentCodingBench` namespace:

- **`World`** — lanes, cast prompts, tasks, the lifecycle. Owns `tasks` and
  `task_events`.
- **`Stats`** — the Collector, samples, calls, Runs, fingerprint storage.
- **`Box`** — ssh exec, opencode client wiring, vLLM endpoints. The only
  code that knows the box's address; World and Stats call Box, nobody else
  touches ssh or base URLs.

## Supervision tree

```
AgentCodingBench.Supervisor (app root)
├── Repo, PubSub, Endpoint            (Phoenix standard)
├── Registry (lane sessions)          (always up)
└── World.Supervisor                  (started/stopped from the dashboard)
    ├── Stats.Collector               (5s scrape loop)
    ├── World.EventRelay              (SSE consumer)
    └── World.LaneSupervisor          (DynamicSupervisor)
        └── World.Lane × N            (GenServer, restart: :permanent)
```

- **Lane = GenServer**, one per lane, holding the four-state loop with
  `Process.send_after` timers for inactivity and the per-task hard cap.
- **Crash semantics**: a crashed Lane restarts fresh — its `init` sweeps any
  `running` task row for its lane number to `abandoned` (reason
  `lane_crash`, a fifth mechanical trigger beyond the lifecycle doc's four)
  and resets the clone. World start runs the same sweep globally, catching
  app-level crashes.
- **Collector lives under the world supervisor**: "world up" = scraping. A
  world started with 0 lanes gives idle-baseline scraping for free.
- **No preflight**: starting the world with the box unreachable just
  crash-loops the children until you stop it.
- World up/down is never persisted — app boot means world down.

## Event routing

One `EventRelay` process consumes the opencode server's single `/event`
SSE stream and routes events point-to-point: lanes register their opencode
`sessionID` in the Registry, the relay does a direct send. On stream
failure it re-subscribes and re-lists pending questions/permissions (the
SDK stream has no reconnect — see the opencode SDK research).

## Talking to the box

- **ssh**: shell out to the `ssh` binary via one `Box.exec/2` wrapper
  (`System.cmd`). Leans on `~/.ssh/config`; OpenSSH ControlMaster gives
  connection reuse. Used for clone git ops and fingerprint facts. No
  daemon or helper script on the box.
- **opencode**: `opencode_sdk` pinned exact (0.1.88) behind a bench-owned
  Coder wrapper — per-clone client (the `x-opencode-directory` header
  selects the workspace), `session_prompt_async`, reply endpoints. The
  wrapper keeps a Req-direct fallback a day's work.
- **vLLM**: Collector scrapes `/metrics` via Req; cast completions hit
  `/v1/chat/completions` via Req directly.

## Schema

Five tables. `runs` and `samples` exactly as decided in
[metrics-and-runs](metrics-and-runs.md), plus:

- `tasks`: `lane` (int), `world_repo` (string slug), `title`,
  `description`, `persona_card` (jsonb), `status`
  (`running` | `merged` | `abandoned`), `abandon_reason` (nullable),
  `started_at`, `finished_at`. Created at invention (`running`), finalized
  at merge/abandon — so the dashboard sees in-flight tasks and crash sweeps
  have a row to close.
- `calls`: as decided in metrics-and-runs, with `task_id` a **nullable**
  FK — a PM invention call has no task yet; null means "pre-task call".
- `task_events`: `task_id`, `kind`
  (`question` | `answer` | `review` | `ruling` | `feedback`), `content`
  (text), `at`. Append-only; both the Person's prompt-assembly source and
  the debugging record.

Not tables: lanes (ephemeral integers on `tasks`/`calls`), World Repos
(the slate is config: slug, upstream URL, box clone path per entry), and
Coder message content (opencode's storage holds it; `calls` keeps only
tokens/timing).

## Config

`config/runtime.exs` for knobs (timeouts, diff char cap, box host, URLs,
the World Repo slate) and `priv/prompts/` files for prompt fragments (PM
size guidance etc.). No DB-backed settings.

## Dashboard

- **World page (v1)**: start/stop + lane-count control, Run start/stop
  with name + notes, a lane grid (state, current task title, World Repo,
  time-in-state, last-event age), and a live tail of recent `task_events`.
  Driven by PubSub broadcasts the lanes already make.
- **Task history**: a plain second page — filter by lane/repo/outcome.
- **Run overlay/charts**: deliberately not designed here — that's the
  prototype ticket
  ([#11](https://github.com/matthusby/agent_coding_bench/issues/11)).

## Testing seams

Behaviours at the three seams the modules already imply — `Box` (exec),
`Cast` (complete), `Coder` (opencode ops) — with in-memory fakes so the
Lane loop is unit-testable: state transitions, timers, abandon triggers,
the rework cycle. Plus pure-function tests (digest/prompt assembly,
fingerprint canonicalization). No HTTP-level mocking, no LiveView snapshot
tests; everything else stays untested until it earns a regression.

## Build plan

Metrics-first: the rig's point is observation, so every later step lands
under observation. Ordered milestones:

1. **Box** — config (box host, URLs), `Box.exec/2`, fingerprint capture.
2. **Stats** — migrations (`samples`, `runs`, `calls`), Collector, Run
   start/stop with fingerprint at both ends + mismatch flag.
3. **Dashboard skeleton** — world page shell with Run controls. _The rig
   is already useful against manual load from here._
4. **Coder plumbing** — `opencode_sdk` pin, Coder wrapper, EventRelay with
   reconnect + pending re-list.
5. **Cast** — PM digest assembly + invention, Persona Card generation,
   Reviewer, Person (Q&A + deciding); `calls` rows throughout.
6. **World** — `tasks`/`task_events` migrations, Lane GenServer,
   World.Supervisor + LaneSupervisor, scale up/down, crash sweeps.
7. **World page** — lane grid, `task_events` tail, task history page.
8. **Live integration** — the full loop against the provisioned box.

Ticket dependencies: the slate
([#9](https://github.com/matthusby/agent_coding_bench/issues/9)) is needed
for real runs at milestone 6; provisioning
([#10](https://github.com/matthusby/agent_coding_bench/issues/10)) gates
milestone 8; the overlay prototype
([#11](https://github.com/matthusby/agent_coding_bench/issues/11)) slots
in anytime after milestone 2.
