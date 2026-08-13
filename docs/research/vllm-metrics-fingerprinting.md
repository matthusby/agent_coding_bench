# vLLM metrics surface and serving-config fingerprinting

Research for issue #3. Question: what can we observe from the vLLM server pinned in
`~/dev/deepseek-v4-flash-mi300x` (ROCm nightly `0.26.1rc1.dev229+g124154a88.rocm723`, AITER 0.1.19)
to power Run metrics, and how do we fingerprint a box's serving config at run start?

**Sources.**
- vLLM source at upstream tag `v0.26.1rc0` (commit `53f6dd5`, 2026-07-27) — the closest verifiable
  upstream to the pinned nightly. There is no upstream `v0.26.1rc1`; that label is the ROCm nightly's
  own stamp on a build just after `v0.26.1rc0`. File:line citations below are against that tag.
- vLLM docs markdown at the same tag (`docs/design/metrics.md`, `docs/usage/metrics.md`) — what
  docs.vllm.ai renders as `design/metrics.html` and `usage/metrics.html` (the site itself was
  rate-limiting during research).
- The local serving-stack repo `/Users/matthusby/dev/deepseek-v4-flash-mi300x` — `compose.yaml`,
  `vllm-entrypoint.sh`, `Caddyfile.example`, `SHA256SUMS`, `patches/README.md`, `benchmarks/`.
  Crucially, `benchmarks/logs/ctx384k-container.log` is a boot + serve log from the **exact pinned
  image**, so route lists and several metric names below are confirmed against the real build, not
  just the upstream tag.

Everything is V1 engine (V0 was removed long before 0.26). The exact-build log confirms:
`Initializing a V1 LLM engine (v0.26.1rc1.dev229+g124154a88)`.

---

## 1. Prometheus `/metrics` surface

Primary source: `vllm/v1/metrics/loggers.py` (`PrometheusStatLogger`) at v0.26.1rc0.

**Labels:** essentially every `vllm:` metric carries `model_name` (the `--served-model-name`, here
`deepseek-ai/DeepSeek-V4-Flash-0731`) and `engine` (engine index as a string; `"0"` here —
single engine). Extra labels noted per metric.

**Counter naming:** counters are registered without `_total`, but `prometheus_client` appends
`_total` at exposition — so on the wire you scrape `vllm:prompt_tokens_total`, etc.
(documented in `docs/design/metrics.md`).

### Per ticket bullet

| Ticket item | Metric(s) on this version | Type / granularity |
| --- | --- | --- |
| TTFT | `vllm:time_to_first_token_seconds` | Histogram, buckets 0.001–2560 s. One observation per request's first token. Aggregate only — no per-request series. |
| Inter-token latency | `vllm:inter_token_latency_seconds` (per decode-step interval) and `vllm:request_time_per_output_token_seconds` (per-request mean TPOT, one observation per finished request) | Both Histograms, buckets 0.01–80 s. The old name `vllm:time_per_output_token_seconds` does **not** exist at this tag. |
| Throughput | `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` (Counters). Also 0.26-era `vllm:prompt_tokens_by_source_total` (label `source` ∈ `local_compute` / `local_cache_hit` / `external_kv_transfer`) and `vllm:prompt_tokens_cached_total`. | **No tokens/s gauge exists** — derive with `rate(vllm:generation_tokens_total[1m])`. The "Avg generation throughput" figures are log-line only. Bonus: `vllm:iteration_tokens_total` is a Histogram of tokens per engine step (despite the `_total` name). |
| Running / waiting | `vllm:num_requests_running`, `vllm:num_requests_waiting` (Gauges). 0.26-era extra: `vllm:num_requests_waiting_by_reason` (label `reason` ∈ `capacity`/`deferred`). | Gauges, sampled per scrape. V0's `num_requests_swapped` is gone. |
| KV cache, GPU | `vllm:kv_cache_usage_perc` — Gauge, 0–1 fraction | V0's `vllm:gpu_cache_usage_perc` does not exist anywhere at this tag. |
| KV cache, CPU tier | `vllm:kv_offload_cpu_cache_usage_perc`, `..._write_usage_perc`, `..._read_usage_perc` (Gauges); `vllm:kv_offload_cpu_allocation_size` (Histogram-ish sum/count), `vllm:kv_offload_store_bytes` / `load_bytes` / `store_time` / `load_time` / `store_size` / `load_size`, `vllm:kv_offload_lookup_sync_delay_seconds` | From `vllm/v1/kv_offload/cpu/` — present only with the OffloadingConnector (`--kv-offloading-backend native`, which this stack sets). **Confirmed on the exact pinned build**: `ctx384k-container.log:454` logs this whole family verbatim. V0's `cpu_cache_usage_perc` was removed in V1. |
| Prefix-cache hits | `vllm:prefix_cache_queries_total`, `vllm:prefix_cache_hits_total` (Counters, in **tokens**). CPU-tier / connector restores show up separately as `vllm:external_prefix_cache_queries_total` / `..._hits_total`. | Hit rate is derived: `rate(hits)/rate(queries)` — there is deliberately no hit-rate gauge. The `gpu_`-prefixed V0 names are gone. Exact-build log line confirms both "Prefix cache hit rate" and "External prefix cache hit rate" are tracked. |
| Spec-decode acceptance | `vllm:spec_decode_num_drafts_total`, `vllm:spec_decode_num_draft_tokens_total`, `vllm:spec_decode_num_accepted_tokens_total`, `vllm:spec_decode_num_accepted_tokens_per_pos` (extra label `position`, 0..6 for DSpark-7) | Counters (`vllm/v1/spec_decode/metrics.py`, registered only when `speculative_config` is set — it is here). Acceptance rate = `rate(accepted)/rate(draft_tokens)`; mean acceptance length = `1 + accepted/drafts`. Confirmed live on the exact build: the log prints per-position acceptance for 7 positions, and `vllm bench serve` result JSONs in `benchmarks/results/` carry `spec_decode_acceptance_rate`, `spec_decode_per_position_acceptance_rates`, etc. collected from these counters. |

### Also available (useful for the Run schema)

- Request lifecycle histograms: `vllm:e2e_request_latency_seconds`,
  `vllm:request_queue_time_seconds`, `vllm:request_inference_time_seconds`,
  `vllm:request_prefill_time_seconds`, `vllm:request_decode_time_seconds`.
- Size/shape histograms: `vllm:request_prompt_tokens`, `vllm:request_generation_tokens`,
  `vllm:request_max_num_generation_tokens`, `vllm:request_params_n`,
  `vllm:request_params_max_tokens`, `vllm:request_prefill_kv_computed_tokens`.
- `vllm:request_success_total` — Counter with label `finished_reason` ∈ `stop`/`length`/`abort`.
- `vllm:num_preemptions_total`.
- Generic HTTP metrics (`http_requests_total{handler=...}` etc.) via
  prometheus-fastapi-instrumentator.
- Optional, off by default on this stack: `vllm:kv_block_*` residency histograms
  (`--kv-cache-metrics`), MFU counters (`--enable-mfu-metrics`) — the exact-build config log shows
  `kv_cache_metrics=False`, `enable_mfu_metrics=False`.

**Granularity summary:** everything on `/metrics` is aggregate (counters, gauges, histograms with
`model_name`/`engine` labels). There is no per-request series; per-request numbers come from the
client side or from the API response (below). For run-scoped metrics, snapshot `/metrics` at run
start and end and diff the counters/histogram buckets.

## 2. Per-request timing from the OpenAI-compatible API

- **`usage` block** (`prompt_tokens`, `completion_tokens`, `total_tokens`) on every non-streaming
  response. This stack sets `--enable-prompt-tokens-details`, so
  `usage.prompt_tokens_details.cached_tokens` is populated — per-request prefix-cache hit counts
  over plain HTTP. (0.26-era also adds `created_cache_tokens`, `multimodal_tokens`.)
- **Streaming:** `stream_options: {"include_usage": true}` → final SSE chunk carries `usage`;
  `continuous_usage_stats` puts it on every chunk.
- **Per-request TTFT in the response body — exists in the 0.26 family** (absent ≤0.25): with server
  flag `--enable-per-request-metrics`, responses carry `metrics: {time_to_first_token_ms,
  generation_time_ms, queue_time_ms, mean_itl_ms, tokens_per_second}`
  (`vllm/entrypoints/openai/engine/protocol.py:122–128`; TTFT = scheduled→first token; suppressed
  when `n>1`; rides the final usage chunk when streaming). **The compose stack does not set this
  flag**, so today per-request TTFT/ITL must be measured client-side (which is exactly what
  `vllm bench serve --percentile-metrics ttft,tpot,itl,e2el` does in `benchmarks/sweep.sh`).
  FLAG: this feature is new in the 0.26 family — verify it exists in the ROCm nightly before
  relying on it.
- **Headers:** `X-Request-Id` is echoed/generated only with `--enable-request-id-headers` (not set
  here). Clients may still *send* `X-Request-Id` and it is used as the request id server-side —
  useful for correlating with server logs. No timing headers exist.
- **`system_fingerprint`** in every chat/completion response: default format
  `vllm-<version>[-tpN-ppN-dpN-ep]-<hash8>`, where `hash8` is the first 8 chars of
  `VllmConfig.compute_hash()` (`vllm/entrypoints/serve/utils/fingerprint.py`). This is a free,
  remote, per-response **config fingerprint**: any change to engine config changes the hash. FLAG:
  present since ~0.25; confirm the nightly populates it (older builds return `null`).

## 3. What the compose stack exposes today vs needs opening

Route list confirmed from the exact-build log (`ctx384k-container.log:404–436`): `/health`,
`/metrics`, `/version`, `/load`, `/ping`, `/tokenize`, `/detokenize`, `/v1/models`,
`/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/messages`, render/derender
routes, `/inference/v1/generate`, plus FastAPI `/docs`, `/redoc`, `/openapi.json`.

- **No host port on `inference`.** `compose.yaml` publishes nothing for the vLLM container; only
  Caddy binds `443`. On-box access is via the compose network (`inference:8000`, or the container
  IP — `benchmarks/lib.sh:server_ip()` shows the pattern) or `docker exec ... curl 127.0.0.1:8000`.
- **`/metrics` is already reachable remotely.** `Caddyfile.example` allowlists paths
  `/v1/chat/completions /v1/completions /v1/models /health /metrics /generate` for the configured
  `remote_ip` CIDR — so a scraper inside the allowlist can hit `https://<host>/metrics` with no
  stack changes. (Note `/generate` in the allowlist doesn't match any route on this build — the
  actual route is `/inference/v1/generate`.)
- **`/version` and `/load` are NOT in the Caddy allowlist** — add them to the operator's local
  `Caddyfile` if wanted over HTTPS. That file is a copy of `Caddyfile.example`; SHA256SUMS pins
  only the `.example`, so editing the live Caddyfile does not break the `sha256sum -c` audit.
  Alternatively collect them over ssh. `/load` returns a meaningful value only with
  `--enable-server-load-tracking` (not set).
- **Flags this stack sets that matter for observability:** `--enable-prompt-tokens-details` (per-
  request cached-token counts: on), speculative config (spec-decode counters: on),
  `--kv-offloading-backend native` (kv_offload metrics: on), stats logging on by default (the
  10-second `loggers.py:310` / `metrics.py:120` INFO lines in the container log).
- **Not set / would need opening:** `--enable-per-request-metrics` (per-request timing in
  responses), `--enable-request-id-headers`, `--enable-server-load-tracking`,
  `--kv-cache-metrics`, `--enable-mfu-metrics`, `VLLM_SERVER_DEV_MODE=1` (enables `/server_info`
  dumping the entire VllmConfig + env — powerful but explicitly a dev/security-warned surface; do
  not enable on an internet-reachable box). Any of these requires editing `compose.yaml`, which
  **breaks the SHA256SUMS audit** — the benchmark runbook is explicit that `compose.yaml` must stay
  byte-identical. Treat flag additions as a new pinned stack revision, not a tweak.

## 4. Fingerprinting recipe (collected at run start)

Goal: a Run record that pins *exactly* what served the traffic. Two channels: ssh (authoritative)
and HTTP (cheap, remote). Collect all of these before admitting traffic; store raw values plus one
rollup hash.

Over **ssh** (authoritative):

```bash
# 1. Image digest actually running (not just what compose says)
docker inspect deepseek-v4-inference-1 --format '{{.Image}} {{index .RepoDigests 0}}'
#    expect vllm/vllm-openai-rocm@sha256:e68d18b2ba50298661bfc49baf01158fbf036645c2362cccf3e8a7a79fe6c69a

# 2. Full vLLM flags + env as launched
docker inspect deepseek-v4-inference-1 --format '{{json .Config.Cmd}}'   # model path + all serve flags
docker inspect deepseek-v4-inference-1 --format '{{json .Config.Env}}'   # VLLM_ROCM_USE_AITER, AITER_CONFIG_*, ...

# 3. Overlay/tuning-table integrity (25 pinned artifacts) + one-line rollup
cd ~/deepseek-v4-flash-mi300x && sha256sum -c SHA256SUMS && sha256sum SHA256SUMS
#    rollup: hashing SHA256SUMS itself gives a single value that changes if any pin changes

# 4. Engine-resolved config (catches things flags don't say: quantization=deepseek_v4_fp8,
#    cudagraph_mode, kernel_config, max_seq_len, spec config) — one log line:
docker compose logs inference | grep 'Initializing a V1 LLM engine'
#    also yields the true version: (v0.26.1rc1.dev229+g124154a88)

# 5. AITER version (not visible over HTTP)
docker exec deepseek-v4-inference-1 python3 -c 'import aiter; print(aiter.__version__)'   # expect 0.1.19
```

Over **HTTP** (works through Caddy from the allowlisted CIDR, or via the compose network on-box):

```bash
# 6. vLLM build string — {"version": "0.26.1rc1.dev229+g124154a88.rocm723"}
curl -fsS http://inference:8000/version        # add /version to Caddyfile for remote use

# 7. Model identity — id = served name, root = HF snapshot path (leaks revision 7872f01b1d1f...),
#    max_model_len = 262144, owned_by = "vllm"
curl -fsS https://<host>/v1/models

# 8. Config-hash fingerprint — system_fingerprint "vllm-<version>-<hash8>" from a 1-token request;
#    hash8 = VllmConfig.compute_hash()[:8], changes whenever engine config changes
curl -sS https://<host>/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-ai/DeepSeek-V4-Flash-0731","prompt":"x","max_tokens":1}' \
  | jq -r .system_fingerprint

# 9. Baseline /metrics snapshot (also the run-start counter baseline for run-scoped deltas)
curl -fsS https://<host>/metrics
```

Fingerprint tuple to store per Run: `{image_digest, vllm_version, cmd[], env{}, sha256sums_ok,
sha256(SHA256SUMS), engine_config_line, aiter_version, model_id, model_root/revision,
max_model_len, system_fingerprint, metrics_snapshot_t0}`. Items 1–3 + 7 are sufficient to detect
any drift from the pinned repo state; item 8 is the cheapest continuous check (per-response).

**Note on model checkpoint:** the strongest checkpoint pin is the HF revision in the snapshot path
(`7872f01b1d1fe23eabc4c98b48bffcef5a386062`), visible in `root` from `/v1/models` and in the
container Cmd. Hashing 156 GB of weights at run start is not worth it; the revision + read-only
HF-cache mount is the pin.

## 5. Version-uncertainty flags

1. **Reference gap:** citations are from upstream `v0.26.1rc0`; the pinned image is a ROCm nightly
   `0.26.1rc1.dev229` built ~229 commits later plus unknown ROCm patches. The exact-build container
   log confirms the route list, the kv_offload metric family, spec-decode per-position stats, and
   the periodic stats logging — but individual metric names not seen in that log are v0.26.1rc0
   claims.
2. **New in the 0.26 family** (do not assume on other boxes): `--enable-per-request-metrics` +
   response `metrics` field, `prompt_tokens_by_source`, `num_requests_waiting_by_reason`,
   `kv_offload_cpu_*`, `kv_block_*` histograms.
3. **Long-stable across V1** (safe for the schema): `time_to_first_token_seconds`,
   `inter_token_latency_seconds`, `request_time_per_output_token_seconds`,
   `prompt/generation_tokens_total`, `num_requests_running/waiting`, `kv_cache_usage_perc`,
   `prefix_cache_queries/hits`, `e2e_request_latency_seconds`, queue/prefill/decode/inference time
   histograms, `request_success_total`, spec-decode counters.
4. **Dead names** (V0/early-V1; will match nothing on this stack): `gpu_cache_usage_perc`,
   `cpu_cache_usage_perc`, `gpu_prefix_cache_*`, `num_requests_swapped`,
   `time_per_output_token_seconds`.
5. vLLM's deprecation policy (docs/usage/metrics.md): deprecated in `X.Y` → hidden in `X.Y+1`
   (revivable via `--show-hidden-metrics-for-version=X.Y`) → removed in `X.Y+2`. Pin dashboards to
   the names above, not to older write-ups.
