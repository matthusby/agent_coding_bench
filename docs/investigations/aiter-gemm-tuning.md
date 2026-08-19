# AITER GEMM tuning for DeepSeek V4 Flash on MI300X

Closing out the AITER follow-up from the GPU page-fault investigation: the
serving stack's a8w8 blockscale GEMMs were falling back to default kernel
configs for almost every prefill shape. This records what was wrong, what we
shipped, and how to reproduce it on a fresh box.

## Problem

AITER resolves each GEMM `(gfx, cu_num, M, N, K)` against tuned CSVs by exact
match. The pinned tables had almost nothing for this silicon (gfx942, 304 CUs):

- blockscale table (`dsv4_a8w8_blockscale_tuned_gemm.csv`): 8 rows —
  M=1664/2688 for 4 (N,K) families. The other 204 rows are gfx950.
- bpreshuffle table (`dsv4-mi300x-a8w8-blockscale-bpreshuffle.csv`): a
  hand-built ladder (M 8–512 by powers, then 1664/2688/7808) for 3 families.

A census of miss logs (`box/tuning/aiter-miss-census.txt.gz`, 8,017 unique
shapes distilled from 68k lines) showed M is effectively continuous in
[1, 2048] across ~6 (N,K) families — chunked prefill and prefix-cache suffixes
produce arbitrary M. Exact-match tuning of every observed shape is infeasible.

## Fix, in two parts

1. **M round-up overlay** (`box/bench-gemm-op-a8w8.m-round-up.py`, mounted over
   `aiter/ops/gemm_op_a8w8.py`): on a lookup miss, round M up to the nearest
   tuned row for the same (N, K), capped at `max(4*M, M+256)` so a decode-sized
   M can never borrow a huge-M config. Kernels already run below their tuned M
   via AITER's own `get_padded_m` path; this rides the same contract.
2. **Grid tuning session**: tune a bucketed M grid per family so the round-up
   always lands within a short hop. 87 blockscale shapes (M 4–1536, 5 families)
   + 18 bpreshuffle shapes (M 640–1536, 3 families), all tuned with AITER's own
   tuner on the box's GPU. Winners merged into the pinned tables →
   `box/tuning/*.grid-tuned.csv`, mounted via `compose.override.yaml`.

All 105 shapes tuned successfully (CK backend, errRatio 0.0 across the board).
Raw tuner outputs and grid inputs are in `box/tuning/grid-*.csv`.

## Running the tuner

The aiter wheel ships everything: framework in `aiter/utility/{base_tuner,mp_tuner}.py`,
driver in `aiter_meta/csrc/ck_gemm_a8w8_blockscale/gemm_a8w8_blockscale_tune.py`.
Stop the world and the engine (the tuner needs the GPU to itself), then:

```sh
cd /root/dev/deepseek-v4-flash-mi300x
docker compose run --rm --entrypoint bash inference -c "
  python3 /usr/local/lib/python3.12/dist-packages/aiter_meta/csrc/ck_gemm_a8w8_blockscale/gemm_a8w8_blockscale_tune.py \
    -i /root/.aiter/tune/grid_bs.csv -o /root/.aiter/tune/grid_bs_tuned.csv \
    --libtype ck -k --batch 8"
# bpreshuffle: same driver plus --preshuffle
```

Input CSV is bare `M,N,K` rows. `/root/.aiter` in the container is
`./aiter-cache` on the host. ~50s per 8-shape batch on one MI300X after a
~215s one-time JIT build per container invocation.

Pitfalls that cost us runs:

- `--libtype all` crashes: a CKTile candidate (`ck_tile::QuantGemmMultiDKernel`,
  128x128x128 tile) memory-faults on some shapes, killing the worker; mp_tuner
  then waits forever. CK won every pilot shape anyway — use `--libtype ck`.
- `--timeout` counts the JIT build, so any value under ~250s kills workers
  mid-compile in an endless lock-break loop. Leave it unset.
- `--batch 8` checkpoints results between batches so a crash keeps prior work.

## Results (32 lanes, Runs ledger)

| window | gen tok/s | prompt tok/s | mean TTFT |
|---|---|---|---|
| Run 3 baseline | 533 | 64,409 | — |
| m2688 scheduler | 612 | 57,736 | 1.086s |
| + round-up overlay | 614 | 70,402 | 1.017s |
| Run 8 + grid-tuned | 627 | 83,176 | 1.043s |

Config-lookup misses over Run 8's 30 minutes: **0** (5,718 short-hop
round-ups, the rest exact hits). The engine stays demand-limited at 32 lanes
(queue near empty), so kernel gains land mostly as latency/headroom;
window-to-window workload variance dominates deltas under ~5%.

## Rebuild

`bin/provision-box` then `box/bench-setup.sh` installs the overlay, both
grid-tuned tables, and the compose override; nothing else on the box is
load-bearing for this config. The Runs table (local Postgres) holds the
serving-config fingerprint for every cited window.
