#!/bin/sh
set -eu

# A dead EngineCore cannot unlink its CPU-KV mmap. This host serves one vLLM instance.
find /dev/shm -maxdepth 1 -type f -name 'vllm_offload_*.mmap' -delete

# Rotate the argument list rather than rebuilding a string, so arguments
# containing spaces survive intact. Toggles:
#   BENCH_DISABLE_KV_OFFLOAD=1   strips --kv-offloading-size/--kv-offloading-backend
#   BENCH_DISABLE_SPEC_DECODE=1  strips every --speculative-config.* arg
#   BENCH_MAX_NUM_BATCHED_TOKENS=<n>      overrides the scheduler token budget
#   BENCH_LONG_PREFILL_TOKEN_THRESHOLD=<n> overrides the long-prefill cap
argument_count=$#; index=0; skip_value=0; replace_value=""
while [ "$index" -lt "$argument_count" ]; do
  argument="$1"; shift; index=$((index + 1))
  if [ -n "$replace_value" ]; then
    set -- "$@" "$replace_value"; replace_value=""; continue
  fi
  if [ "$skip_value" = 1 ]; then skip_value=0; continue; fi
  if [ "${BENCH_DISABLE_KV_OFFLOAD:-0}" = 1 ]; then
    case "$argument" in
      --kv-offloading-size|--kv-offloading-backend) skip_value=1; continue ;;
    esac
  fi
  if [ "${BENCH_DISABLE_SPEC_DECODE:-0}" = 1 ]; then
    case "$argument" in
      --speculative-config.*) continue ;;
    esac
  fi
  case "$argument" in
    --max-num-batched-tokens)
      [ -n "${BENCH_MAX_NUM_BATCHED_TOKENS:-}" ] && replace_value="$BENCH_MAX_NUM_BATCHED_TOKENS" ;;
    --long-prefill-token-threshold)
      [ -n "${BENCH_LONG_PREFILL_TOKEN_THRESHOLD:-}" ] && replace_value="$BENCH_LONG_PREFILL_TOKEN_THRESHOLD" ;;
  esac
  set -- "$@" "$argument"
done

echo "bench-entrypoint: kv_offload_disabled=${BENCH_DISABLE_KV_OFFLOAD:-0} spec_decode_disabled=${BENCH_DISABLE_SPEC_DECODE:-0} batched_tokens=${BENCH_MAX_NUM_BATCHED_TOKENS:-pinned} long_prefill=${BENCH_LONG_PREFILL_TOKEN_THRESHOLD:-pinned} xnack=${HSA_XNACK:-<unset>} coredump=${HSA_COREDUMP_PATTERN:-<unset>}" >&2
exec vllm serve "$@"
