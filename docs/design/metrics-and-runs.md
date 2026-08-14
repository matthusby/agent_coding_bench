# Metrics, Runs, and the config fingerprint

Decided in [#6](https://github.com/matthusby/agent_coding_bench/issues/6).
Builds on the vLLM metrics research
([#3](https://github.com/matthusby/agent_coding_bench/issues/3),
`docs/research/vllm-metrics-fingerprinting.md` on
`research/vllm-metrics-fingerprinting`).

## Collection

The **Collector** scrapes the vLLM `/metrics` endpoint (published on box
loopback by the socat sidecar and reached through the SSH forward) every **5
seconds**, continuously, whenever the world is up. Runs never touch it —
starting or ending a Run changes nothing about collection. Data flows straight
into Postgres on Matt's Mac, the durable home; the box stays ephemeral.

## Samples

One row per scraped metric value, stored generically:

```
samples(scraped_at, metric, labels jsonb, value)
```

- **Everything** under the `vllm:` prefix is kept — histogram buckets, spec
  decode, prefix cache, CPU offload tier, all of it. Curation happens at
  query/dashboard time, never at ingest.
- Counters are stored raw; rates and counter resets (box restarts) are
  handled at query time, standard Prometheus-style.
- No retention policy — sessions are hours, not months.

## Calls

One row per **Call** — the client-observed unit of LLM work:

- **PM / Reviewer / Person**: one row per chat completion we make directly
  via Req. Tokens from `usage` (incl. `cached_tokens`), TTFT and duration
  measured client-side.
- **Coder**: one row per opencode **assistant message** (a whole tool-loop
  turn, bundling its underlying completion requests), taken from
  `message.updated` / `session_messages`. Tokens from the message's
  `tokens` field (input / output / reasoning / cache.read — populated from
  vLLM's `usage` by opencode's OpenAI-compatible protocol; cache.write is
  always 0 there). Duration from `time.created → time.completed`;
  **`ttft_ms` is NULL** — serving-side TTFT histograms are the only TTFT
  source for Coder traffic.

```
calls(at, lane, role, task_id, prompt_tokens, completion_tokens,
      reasoning_tokens, cached_tokens, ttft_ms, duration_ms)
```

Mixed granularity is accepted by design: the table answers "what did each
lane/role experience and consume", not "every HTTP request".

Workload counters (tasks/hour, tool-calls/task) are **derived queries**
over `calls` + task rows — no dedicated collection machinery. This closes
the map's fog item on workload counters.

## Runs

A Run is a tagged window over the sample stream:

```
runs(id, name, notes, started_at, ended_at, lane_count,
     fingerprint jsonb, fingerprint_digest, fingerprint_mismatch, tags text[])
```

- `lane_count` is the sole first-class knob, captured at start; anything
  else lives in the fingerprint or free-form tags.
- `ended_at` is nullable — a Run stays open until closed explicitly.
- Overlaying Run A vs Run B = slicing `samples` by each window and aligning
  on offset-from-`started_at`.

## Fingerprint

Captured at Run **start and end**; the Run is flagged if the digest changed
mid-window (a silently restarted server poisons comparisons). The tuple,
per the research:

- over ssh: docker image digest, container `Config.Cmd`/`Config.Env`,
  `sha256sum -c SHA256SUMS`, engine-init log version line, aiter version
- over HTTP: `/version`, `/v1/models` (HF revision, max_model_len),
  `system_fingerprint` from a completion, t0 `/metrics` snapshot

Stored as the raw jsonb tuple plus a SHA256 digest of the canonicalized
tuple for cheap "same config?" comparison across Runs.
