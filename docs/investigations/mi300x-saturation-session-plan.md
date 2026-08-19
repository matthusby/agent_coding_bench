# MI300X saturation sweep — box session plan

Goal: a defensible concurrency-vs-throughput curve for one MI300X under real
agent coding load, for the public performance page. The existing sweep is
solid at 8/16/32 lanes but has nothing valid above 32: Run 4 (sweep-64) and
Run 5 (no-offload A/B) were both poisoned by simultaneous cold restarts of
every lane — prefix cache hit rate fell from ~95% to 28%/21%, queue times hit
100s+, and the engine spent the window admission-starved, not saturated.

Everything below runs against the grid-tuned config (Run 8's fingerprint).
`Stats.start_run` captures the fingerprint automatically; comparability is
checked by digest, not by memory.

## Rules learned from Runs 4 and 5

1. Never start all lanes at once. Scale in steps and let sessions mature.
2. A window's clock starts only after the gate passes (below).
3. Record host CPU and container count alongside the vLLM scrape, or
   engine-starvation vs box-starvation cannot be told apart afterwards.
4. Reap leftover coder containers between windows so each window starts from
   the same host load.

## Window gate (check before starting every run)

From the local app, with the collector scraping:

```sql
-- instantaneous cache hit over the last 5 min, expect >= 90
WITH d AS (
  SELECT metric, GREATEST(value - lag(value) OVER (PARTITION BY metric, labels ORDER BY scraped_at), 0) AS d
  FROM samples
  WHERE scraped_at > now() - interval '5 minutes'
    AND metric IN ('vllm:prefix_cache_hits_total','vllm:prefix_cache_queries_total')
)
SELECT round(100 * sum(d) FILTER (WHERE metric like '%hits%')
           / NULLIF(sum(d) FILTER (WHERE metric like '%queries%'), 0)) AS hit_pct
FROM d;
```

Plus, on the box / in the live view:

- `num_requests_running` roughly equals engaged lanes; `num_requests_waiting`
  near zero (a backlog at window start means the ramp has not settled).
- `docker logs deepseek-v4-inference-1 | grep bench-entrypoint:` shows the
  expected offload/coredump state.
- `tail /root/host-samples.csv` is fresh and container count is stable.
- Record `docker ps -q | wc -l` in the run notes at start and end.

## Session runbook

Provision (~existing flow): `bin/provision-box`, then
`box/bench-setup.sh <operator-ip>` — now also installs the host sampler.
Verify the gate checklist once before any window.

| # | Window | Lanes | Duration | Purpose |
|---|--------|-------|----------|---------|
| 0 | warmup | 32 | ~30 min | Sessions mature, cache warms. No run recorded. |
| 1 | `sweep-32-v2` | 32 | 30 min | Re-baseline on the fresh box. Expect ~627 gen tok/s (Run 8). If off by >10%, stop and investigate before ramping. |
| 2 | `sweep-48` | 48 | 30 min | Scale 32→48, warm ≥15 min, gate, then run. |
| 3 | `sweep-64-v2` | 64 | 30 min | Scale 48→64, warm ≥15 min, gate, then run. |
| 4 | `sweep-96` | 96 | 30 min | Only if window 3 is still demand-limited (queue near empty) AND host CPU has headroom. Skip if either is false — the knee is the finding. |
| 5 | synthetic ceiling | 0 | ~15 min | `World.stop`, then a saturating fixed-shape load (`vllm bench serve`, random 1k/1k prompts, high concurrency) for the "synthetic benchmark says X, agents get Y" contrast number. |
| 6 | `sweep-32-no-offload-v2` | 32 | 30 min | Optional, time permitting. Redo the KV-offload A/B warm: set `BENCH_DISABLE_KV_OFFLOAD=1`, recreate engine, re-warm to gate, then run. Quantifies what the CPU KV tier buys. |

Run bookkeeping from IEx:

```elixir
AgentCodingBench.World.start(32)          # then scale_lanes(48) etc.
AgentCodingBench.Stats.start_run(%{name: "sweep-48", lane_count: 48,
  tags: ["concurrency-sweep", "grid-tuned"], notes: "..."})
AgentCodingBench.Stats.stop_run(AgentCodingBench.Stats.active_run())
```

Between windows: `docker ps` on the box and remove leftover coder test
containers (`supabase/realtime`, `oban` postgres containers) so the next
window starts clean.

## Watch during high-lane windows

- Host CPU and container count (`/root/host-samples.csv`). If load climbs
  while engine step rate falls, the box is starving the engine — that is a
  result, not a failed window. Let it run and label it.
- Prefix cache hit rate. If it degrades mid-window at 64+ (cache churn from
  genuinely more concurrent context), that is also a result — distinguish it
  from a cold start by the gate having passed.
- `/root/gpu-faults.log` stays empty (zeroer fix soak evidence accumulates
  for free all session).

## Harvest before teardown (the box is disposable, the data is not)

- `/root/host-samples.csv` → `docs/investigations/data/`
- `/root/gpu-faults.log` → `docs/investigations/data/` (the "N hours, zero
  faults" statement for the writeup)
- `grep -c 'not found tuned config' /root/engine.log` (expect ~0; cite it)
- Anything new in `/root/aiter-tune/` or the serving dir that a future
  session would need — untracked files die with the box.

The Runs ledger, samples, and task/call history are local Postgres and
survive regardless. Task throughput (tasks completed per hour per window)
comes from the `tasks` table and belongs on the performance page next to
tok/s — it is the number agent people actually care about.

## Rough timeline

Provision + model load + warmup ~1h, windows 1–3 with ramps ~2.5h, ceiling +
optional windows ~1h. Around 4.5–5.5 hours of box time for the core plan.
