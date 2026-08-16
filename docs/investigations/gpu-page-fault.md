# GPU page fault under sustained agent load

**Status: root cause identified 2026-08-15; fix overlay in soak.** The fault
is an **upstream vLLM bug**, not a serving-stack patch: the pinned nightly's
`_zero_kv_blocks_kernel` (`vllm/v1/worker/utils.py`) steps packed KV segments
by page size instead of block stride, so zeroing a top-of-pool block stores
past the end of the KV pool. Named live by the ROCm debug agent
(`MEMORY_VIOLATION` on `global_store_dword`); fixed upstream by `d6af803f43`
and `79f3183f86`, both merged after the pinned image was built. See
[2026-08-15 session](#2026-08-15-session--root-cause) below.

The 2026-08-14 sections are retained as the historical record of the earlier
refutations. The test harness now lives in this repo under `box/` and no
longer dies with a box.

## Symptom

Under sustained load the MI300X takes an unrecoverable GPU page fault. The
EngineCore process dies with no Python traceback — a hard kill, not an
exception. vLLM's API server reports `EngineDeadError`, Compose restarts the
container, and the model takes ~4 minutes to reload.

```
amdgpu 0000:83:00.0: [gfxhub0] no-retry page fault (src_id:0 ring:160 vmid:3 pasid:<n>)
amdgpu 0000:83:00.0:  Process VLLM::EngineCor pid <n> thread VLLM::EngineCor pid <n>
amdgpu 0000:83:00.0:   in page starting at address 0x0000<...> from IH client 0x1b (UTCL2)
amdgpu 0000:83:00.0:   cookie node_id <n> fault from die AID<n>.XCD<n>
```

Originally the fault was far worse: ROCm wrote a **198 GB GPU core dump** taking
~23 minutes, during which the engine was dead but `/health` still answered 200
and requests sat parked — a silent wedge. Unsetting `HSA_COREDUMP_PATTERN` is
the only lever ROCm offers, and it turns a 23-minute wedge into a ~100-second
fail-and-restart. That is a survivability workaround, not a fix.

## The signature, which never changed

Every fault across four different software configurations:

- `no-retry` — `HSA_XNACK` is unset, so any unmapped access is instantly fatal
- IH client `0x1b (UTCL2)` — a **compute shader**, not SDMA
- always `vmid:3`; `pasid` differs per fault because each restart is a new process
- the faulting base address is **always 2 MB-aligned**, and faults sweep upward
  through the first few 4 KB pages of that region

```
0x768434200000  +1000
0x7720e0200000  +1000 +6000
0x743b20000000  +1000 +2000 +e000 +10000 +12000
0x7a342c000000  +1000 +3000
0x702c88000000
0x70ac00200000  +1000 +2000
0x7532c0000000  +1000
```

That is the shape of a kernel reading **past the end of one buffer into the
base of the next 2 MB-aligned allocation**, which is unmapped. It is not random
corruption, and it has survived every configuration change we have made.

Note the address alone does not distinguish host memory from device memory —
ROCm maps VRAM into the process address space too, so a plain userspace-looking
VA does not imply a host buffer.

## Fault timeline

| time (UTC) | pasid | config | interval of *loaded* time |
|---|---|---|---|
| 13:33:18 | 134 | offload on, `block_h=64` | — |
| 14:22:12 | 158 | offload on, `block_h=64` | 49 min |
| 14:43:07 | 182 | offload on, `block_h=64` | 21 min |
| 15:06:03 | 250 | **offload off**, `block_h=64` | ~9 min (at half throughput) |
| 16:33:32 | 318 | offload on, **`block_h=16`** | 62 min |
| 16:48:00 | 342 | offload on, `block_h=16` | 14.5 min |
| 17:01:28 | 366 | offload on, `block_h=16` | 13.5 min |

## Refuted hypotheses

Each intervention was verified to be actually in effect before the result was
read. All three are genuine negatives, not inconclusive runs.

### H1 — host page migration invalidating a GPU-mapped page (refuted)

The box was running with `MemFree` at 1.5 GB, zero swap, 96 GB pinned in tmpfs
for the CPU KV tier, `pgmigrate_success` at 1.43M and **100% compaction
failure** (`compact_stall 45 / compact_fail 45`). Moving a page the GPU has
mapped, with XNACK off, produces exactly this fault.

Set `vm.compaction_proactiveness=0` and `vm.min_free_kbytes` 66 MB → 4 GB.
`MemFree` went to 9–11 GB and **`pgmigrate_success` froze at exactly
1,443,576 for the entire window** — zero migrations. It faulted twice anyway.

### H2 — the native KV offload backend racing (refuted)

The serving repo ships `patches/diffs/10-kv_offload_cpu_gpu_worker.load-war.patch`,
a work-around making the transfer stream wait on the compute stream in *both*
directions, with the comment "loads may overwrite blocks compute may still
read." Its README notes the upstream fix (**PR #47291**) is not merged. So this
hazard class is known and only partially papered over — a strong prior.

Ran with `BENCH_DISABLE_KV_OFFLOAD=1`: no offload args in the launch line, no
mmap in `/dev/shm`, `Shmem` 96 GB → 0. It faulted in **~9 minutes**, sooner than
with the tier enabled, despite running at half the generation throughput.

Cost of this test: prefix cache hit rate 95.9% → 88.3% and falling, generation
550–618 → 324 tok/s. Not a state to run in.

### H3 — `block_h = 64` in the sparse-attention prefill Triton kernel (refuted)

`patches/rocm_aiter_mla_sparse.prefill-bh64.py` raises `block_h` from 16 to 64
at line 1840, a 4× larger tile feeding
`triton.cdiv(num_heads, block_h)`. An unguarded tail would read past its buffer
into the next allocation — a clean mechanistic fit for the signature.

Tested by mounting a copy of that same patched file with **exactly one line
changed** (`block_h = 64` → `16`), rather than reverting to stock. The patch
also replaces the prefill topk HIP kernel with pure `torch.topk` and adds a
canonicalizing sort to the decode path; both are correctness work that a full
revert would have silently discarded.

Verified live inside the container (`sed -n 1840p` → `block_h = 16`). It ran 62
minutes clean — the longest interval observed — then settled into a steady ~14
minute fault cadence.

## Remaining hypotheses

1. **Get the actual faulting kernel.** Stop swapping patches one at a time.
   - `HSA_XNACK=1` makes faults retryable. If the access is to a valid-but-
     unmapped page it recovers; if it is a true out-of-bounds read it still
     dies, and either outcome is informative. Cheap and reversible — do this first.
   - Re-enable `HSA_COREDUMP_PATTERN` for **one** fault only, then unset it. The
     dump names the kernel and dispatch. Costs a 23-minute wedge per fault.
2. **The dspark speculative-decode patches** (`08-dspark-speculator`,
   `09-spec-decode-utils`) — 7 draft tokens. Disable speculative decoding.
3. **`aiter_pa_mqa_logits.i64.py`** — the other hand-patched kernel path.

Three refutations in a row suggest the hypothesis generation has been aimed at
software config when the evidence has consistently pointed at one specific
mechanism. Prefer instrumentation that identifies the kernel over another
swap-and-wait cycle.

## Methodology notes — read before resuming

- **`dmesg` wraps.** The fault-event count went *down* from 4 to 3 because the
  ring buffer evicted the older entries. Do not use a cumulative count as a
  baseline. Match on timestamps and persist them to a file.
- **A test only counts under load.** One H3 window was invalidated because the
  `CrashSweeper` crash took the World down and the engine sat idle. Always
  confirm `num_requests_running > 0` before starting the clock.
- **Throughput changes the exposure rate.** The ~9-minute fault under H2 came at
  half the generation rate, which makes it *more* damning, not less. Weigh
  intervals against throughput.
- **Container recreate resets `RestartCount` to 0.** `docker compose up -d`
  recreates rather than restarts, so that counter is not continuous across tests.

## Box state — the box was destroyed 2026-08-14, recreate this first

The box these tests ran on was shut down at ~17:20 UTC. Everything below lived
on it and is **gone**; none of it is in this repo. Recreate it on the next box
before resuming, or the first test will silently run against the pinned stack.

The files are untracked in the serving repo on purpose: provisioning does
`git reset --hard` (which preserves untracked files) and `sha256sum -c
SHA256SUMS` (which ignores them), so they survive *re-provisioning* — but not a
destroyed box. `SHA256SUMS` was verified clean throughout; no pinned file was
ever modified.

`/root/dev/deepseek-v4-flash-mi300x/compose.override.yaml`:

```yaml
services:
  inference:
    environment:
      # Turns a 23-minute coredump wedge into a ~100s fail-and-restart.
      HSA_COREDUMP_PATTERN: null
      BENCH_DISABLE_KV_OFFLOAD: "0"
    entrypoint: [/opt/bench-entrypoint.sh]
    volumes:
      - ./bench-entrypoint.sh:/opt/bench-entrypoint.sh:ro
      # H3 only. Compose merges `volumes:` by target path, so this replaces the
      # pinned mount without editing the checksum-audited compose.yaml. Omit it
      # to run the stack's own block_h=64.
      - ./bench-mla-sparse.bh16.py:/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/ops/rocm_aiter_mla_sparse.py:ro
```

`/root/dev/deepseek-v4-flash-mi300x/bench-entrypoint.sh` (chmod +x) — a faithful
superset of the stack's `vllm-entrypoint.sh`, so nothing the stack does is
skipped:

```sh
#!/bin/sh
set -eu

# A dead EngineCore cannot unlink its CPU-KV mmap. This host serves one vLLM instance.
find /dev/shm -maxdepth 1 -type f -name 'vllm_offload_*.mmap' -delete

if [ "${BENCH_DISABLE_KV_OFFLOAD:-0}" = "1" ]; then
  argument_count=$#; index=0; skip_value=0
  # Rotate the argument list rather than rebuilding a string, so arguments
  # containing spaces survive intact.
  while [ "$index" -lt "$argument_count" ]; do
    argument="$1"; shift; index=$((index + 1))
    if [ "$skip_value" = 1 ]; then skip_value=0; continue; fi
    case "$argument" in
      --kv-offloading-size|--kv-offloading-backend) skip_value=1; continue ;;
    esac
    set -- "$@" "$argument"
  done
fi

echo "bench-entrypoint: kv_offload_disabled=${BENCH_DISABLE_KV_OFFLOAD:-0} coredump=${HSA_COREDUMP_PATTERN:-<unset>}" >&2
exec vllm serve "$@"
```

`bench-mla-sparse.bh16.py` is reconstructed from the pinned patch with a
one-line change — only needed to re-run H3, which is already refuted:

```sh
cd /root/dev/deepseek-v4-flash-mi300x
sed '1840s/block_h = 64/block_h = 16/' \
  patches/rocm_aiter_mla_sparse.prefill-bh64.py > bench-mla-sparse.bh16.py
diff patches/rocm_aiter_mla_sparse.prefill-bh64.py bench-mla-sparse.bh16.py  # expect exactly 1 line
```

Verify after any restart, because a silently-dropped mount invalidates the test:

```sh
docker exec deepseek-v4-inference-1 sed -n 1840p \
  /usr/local/lib/python3.12/dist-packages/vllm/v1/attention/ops/rocm_aiter_mla_sparse.py
docker logs deepseek-v4-inference-1 2>&1 | grep 'bench-entrypoint: kv_offload' | tail -1
```

The baseline stamps (`/root/compaction-test-baseline.txt`,
`/root/offload-test-baseline.txt`, `/root/h3-test-baseline.txt`) and the staged
AITER shape lists in `/root/aiter-tune/` are gone too. The fault timeline table
above is the surviving record.

Sysctls, applied at runtime and **lost with the box**. Refuted as a cause but
worth re-applying because 4 GB of headroom is healthier than 66 MB:

```
vm.compaction_proactiveness  20    -> 0
vm.min_free_kbytes           67584 -> 4194304
```

Also applied earlier and not yet folded into `box/provision.sh`: a ufw rule
allowing SSH from the operator IP past the rate limiter, and disabled
`apt-daily*` timers.

## 2026-08-15 session — root cause

New box provisioned at 129.212.190.152. Six test windows, all under 16-lane
load; timeline stamped in `/root/bench-windows.log` on the box, per-window
fault logs preserved as `/root/gpu-faults.window*.log`.

| Window | Config | Result |
|---|---|---|
| 1 | baseline + `HSA_XNACK=1` | Fault at ~9 min. Truly unmapped page — retry cannot absorb it. New datum: multiple XCDs fault on the same address. |
| 2 | spec decode stripped | Fault at ~60 min at half throughput. **DSpark refuted.** |
| 3 | baseline + coredump | Dump truncated at 21 GB by a watcher bug (kept as `gpucore.358.partial`). |
| 3b | same, `fuser`-based watcher | Full 186 GB dump captured. Segment map: faulting VA is **0 bytes past the end of the 18.6 GiB KV pool segment**. rocgdb (pinned and current) finds no queues/dispatches — queues are torn down before the dump is written, so **a coredump cannot name the kernel**; the earlier assumption that it could was wrong. |
| 4 | + clamped `pa_mqa_logits` overlay | **Faulted at ~15 min — clamp hypothesis refuted.** The i64 overlay's `buffer_load`→`gl.load` conversion does drop the hardware bounds check (a real latent hazard, reported upstream as a courtesy), but it is not this crash: the fault is a **store**, and it survived the clamp. |
| 5 | + `HSA_TOOLS_LIB=librocm-debug-agent.so.2` | **Culprit named.** On fault, the debug agent printed the wavefronts: `_zero_kv_blocks_kernel`, `MEMORY_VIOLATION` on `global_store_dword`, source line `vllm/v1/worker/utils.py:90`. Wave scalar registers hold the store address matching the dmesg fault page exactly. |
| 6 | baseline + zeroer fix overlay | Soak in progress. |

### Root cause

`_zero_kv_blocks_kernel` in **upstream vLLM** (`vllm/v1/worker/utils.py`) — the
Triton kernel that zeroes newly-allocated KV blocks each step — computes block
offsets as `block_id * page_size_el`. For packed KV segments, where a
segment's page is smaller than the block stride (exactly DeepSeek V4's
MLA + DSA-indexer layout), stepping by page size instead of **block stride**
lands short of the true block start and clears a full stride's worth — so
zeroing a top-of-pool block **stores past the end of the KV pool allocation**.

It faults only when the allocator hands out a top block — a once-per-N-blocks
lottery — producing the ~14-minute cadence and immunity to every config
change. All three of the 2026-08-14 refutations, and window 4's, were
bystanders: the writer was in the engine itself, not the stack's patches.

None of the hand-patched kernels were the cause. The serving stack is
exonerated; the pinned **nightly** (`0.26.1rc1.dev229`, built ~Aug 4) simply
predates the upstream fixes:

- `d6af803f43` (2026-08-06) "[Bugfix] Fix packed KV block zeroing stride"
  (#50276) — separates per-segment block stride from page size; regression
  test zeroes the last block of a packed segment.
- `79f3183f86` (2026-08-13) "[Bugfix] Bound KV block zeroing launch geometry"
  (#52058) — its test is literally `test_large_dsv4_launch_geometry` with the
  MLA/indexer page-size pair (9344/292).

The KVBlockZeroer had five bugfixes in six weeks upstream; DSV4 on a nightly
from that window was maximally exposed.

### The fix

`box/bench-worker-utils.zeroer-fix.py` — the pinned image's
`vllm/v1/worker/utils.py` with both upstream diffs applied (they apply
cleanly). Mounted over the stock file via `box/compose.override.yaml`. The
window-4 clamp overlay was removed to keep divergence minimal. The debug
agent stays loaded (free until a fault; names any future one instantly).

### Diagnosis lessons

- The GPU coredump path was a dead end here: ROCr tears queues down before
  dumping, so neither the pinned nor a current rocgdb can recover dispatches.
  The **ROCm debug agent** (`HSA_TOOLS_LIB=librocm-debug-agent.so.2`) is the
  right tool: wavefront registers, PC, kernel name, and source line, printed
  to the engine's stderr at the moment of death, for free.
- The dump was still decisive for *victim* geometry (fault VA vs segment map)
  — but victim geometry alone misidentified the culprit: both windows 4 and
  the real bug overrun the same buffer. Reader-vs-writer (`global_store` vs
  load at the faulting PC) was the discriminating fact.
- The dmesg fault lines do not distinguish read from write; do not assume.

### Follow-ups once the soak confirms

- Report to `ryanzhou/deepseek-v4-flash-mi300x`: the pinned nightly needs the
  two zeroer fixes as an overlay (or an image bump past 2026-08-13); include
  the debug-agent wavefront capture.
- Courtesy report on the i64 overlay's dropped hardware bounds check (real
  hazard, not this crash).
- Consider an image upgrade to a nightly ≥ 2026-08-13 as the durable fix;
  requires re-porting all ten stack overlays, so a project in itself.
- Commit the `box/` harness files and this doc.

## Unrelated findings surfaced along the way

- **AITER tuned-config misses.** ~70% of engine log lines are
  `not found tuned config ... will use default config!`. The shipped tuning
  files are named `prefill-m2688` and their tuned M values for our GPU are
  `{8,16,32,64,128,256,512,1664,2688,7808}` — but **observed M never exceeds
  1592**, because `--long-prefill-token-threshold 1024` caps prefill tokens per
  batch. The shipped tuning is structurally unreachable for prefill. AITER does
  exact-M lookup and we generate 639 distinct M values, so full coverage would
  need 3,834 tuned shapes. Staged shape lists are at `/root/aiter-tune/`.
  Tuning requires exclusive GPU access — it cannot run alongside a benchmark.
  Raising `--long-prefill-token-threshold` to make M recur at a fixed value is
  likely a bigger win than brute-force tuning, and is untested.
- **Coders launch Docker containers.** Test suites for `supabase/realtime` and
  `oban-bg/oban` spin up their own containers on the box. Realistic, but
  unbudgeted load contending with the engine's two saturated cores, and nothing
  reaps them.
- **The engine is CPU-bound on two cores by design.** EngineCore is one Python
  process; its scheduler loop is GIL-bound to ~1 core, with a second
  GIL-releasing helper thread. The API server sits at ~11%. More cores are not
  available without data parallelism, which needs VRAM we do not have (96%
  used). This is *not* the bottleneck — the GPU samples at 100%.
