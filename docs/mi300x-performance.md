# 32 coding agents on one MI300X

Most published LLM serving numbers come from synthetic load: fixed prompt
lengths, ShareGPT replays, evenly spaced arrivals. I wanted to know what a
single MI300X actually delivers when the clients are autonomous coding agents
doing real work, because that workload looks nothing like the benchmarks.
This page is the answer, measured over multiple 30-minute windows with every
number tied to a recorded serving-config fingerprint.

The short version: one MI300X comfortably serves 32 concurrent coding agents
on DeepSeek V4 Flash at ~580 to 627 generated tokens/sec and ~78,000 prompt
tokens/sec, with a median time-to-first-token around one second. Past 32
agents this configuration does not degrade gracefully, so I treat 32 as the
practical ceiling.

## The workload

The load generator is a bench harness I built for this: N "lanes", each lane
an [opencode](https://opencode.ai) agent session working on a clone of a real
open-source repo (req, oban, supabase/realtime, livebook, flask, pydantic,
hono, excalidraw). Each lane picks up a generated task, works it like a
contributor would (reads code, edits, runs the test suite, commits), and
either gets its change merged or times out. All inference goes through the
one vLLM instance. Everything is scraped into Postgres every 5 seconds.

What makes this workload different from synthetic load, measured during the
32-lane window:

- The average request carries **53,194 prompt tokens** and generates just
  **390**. Agents resend their whole growing conversation every turn.
- That only works because of prefix caching: the hit rate under steady load
  is **93 to 99%**. Cache hit rate is the load-bearing metric of the entire
  setup. When it drops, everything drops.
- Arrivals are bursty and phase-correlated. Agents block on their own test
  suites, then all come back at once.

The tasks are deliberately hard and most hit their timeout: a typical
30-minute window at 32 lanes completes ~2,600 agent turns, merges 3 or 4
tasks, and abandons ~25 at the timeout. This is a serving benchmark, not a
coding-ability one; the tasks exist to generate honest load.

## Hardware and stack

One AMD Developer Cloud box: 1x MI300X (192 GB HBM3), 20 vCPU, 236 GB RAM.
The agents and their test suites run on the same box as the engine, which is
realistic and occasionally consequential.

Serving is the pinned open-source
[deepseek-v4-flash-mi300x](https://github.com/ryanzhou/deepseek-v4-flash-mi300x)
stack: vLLM nightly `0.26.1rc1.dev229` (ROCm), DeepSeek V4 Flash at 262k
context, MLA + DSA sparse attention, speculative decoding (~49% draft
acceptance, stable across every window), and a 96 GB CPU KV offload tier.
Plus two sets of overlays from this repo: two upstream vLLM bugfixes for a
KV-zeroing kernel that was page-faulting the GPU under load (the full hunt is
[its own writeup](investigations/gpu-page-fault.md)), and AITER GEMM tuning
described below.

## Concurrency sweep

30-minute windows per lane count, engine warm, cache hit gated above 90%
before each window starts:

| lanes | gen tok/s | prompt tok/s | TTFT p50 | TTFT p99 | cache hit |
|------:|----------:|-------------:|---------:|---------:|----------:|
| 8     | 358       | 54,020       | ≤0.75s   | ≤5s      | 99%       |
| 16    | 448       | 75,517       | ≤1s      | ≤5s      | 98%       |
| 32    | 533       | 64,441       | ≤2.5s    | ≤20s     | 94%       |
| 32 (tuned) | 582  | 78,262       | ≤1s      | ≤5s      | 93%       |

The first three rows are the untuned stack; the last row is the same 32-lane
load after the AITER work, on a freshly provisioned box. The GPU runs at 97%
utilization drawing ~717 W during the 32-lane window, and the queue stays
near empty: the engine is keeping up with demand, not saturating. Scaling
from 8 to 32 lanes costs about half a second of median TTFT and buys 63%
more generation throughput.

## What tuning bought

The stack ships AITER GEMM tuning for prefill sizes this workload never
produces (the scheduler caps prefill chunks below every tuned shape), so
~70% of engine log lines were config-lookup misses falling back to default
kernels. Fixing that was worth 18%:

| config | gen tok/s | prompt tok/s |
|---|---:|---:|
| baseline | 533 | 64,409 |
| + m2688 scheduler config | 612 | 57,736 |
| + M round-up on lookup miss | 614 | 70,402 |
| + grid-tuned GEMM tables | 627 | 83,176 |

The round-up overlay resolves a lookup miss to the nearest tuned M for the
same (N, K), and the grid tuning session added 105 tuned shapes so the hop is
always short. Result: zero config misses over a full window, from ~70% of
all log lines. Details and reproduction in
[the tuning writeup](investigations/aiter-gemm-tuning.md).

## The ceiling is a cliff

At 48 lanes this configuration does not queue politely. The working set
spills out of GPU KV cache, the offload tier starts churning 12+ GB/min of
evictions, prefix cache hit rate falls from 93% to under 30%, and throughput
collapses to a small fraction of the 32-lane rate rather than plateauing.
Scaling agents past what the KV cache can hold is not a gradual trade-off on
this stack, so capacity-plan to the cache, not the queue.

## Reliability

Across the final sessions: hours of sustained 97%-utilization load, zero GPU
page faults, zero engine restarts. Getting there required finding and
overlaying two upstream vLLM fixes for a KV-block-zeroing kernel that wrote
past its buffer roughly every 14 minutes under load. That investigation,
including three refuted hypotheses and a 186 GB core dump that turned out to
be structurally useless, is written up
[separately](investigations/gpu-page-fault.md).

## Reproducing

The harness, overlays, tuned tables, and provisioning scripts are in this
repo under `box/`, with the session runbook in
`docs/investigations/mi300x-saturation-session-plan.md`. Every run's serving
config is fingerprinted (image digest, patched-file checksums, engine args,
model, versions) and stored with the metrics, so any number above can be
traced to the exact configuration that produced it.
