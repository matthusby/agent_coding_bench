#!/usr/bin/env bash
set -Eeuo pipefail

# Post-provision harness for the GPU page-fault investigation
# (docs/investigations/gpu-page-fault.md). Run on the box after provision.sh.
#
# Usage: bench-setup.sh <operator-ip>
# Expects bench-entrypoint.sh and compose.override.yaml alongside this script.

readonly SERVING_DIR=/root/dev/deepseek-v4-flash-mi300x
readonly OPERATOR_IP="${1:?operator IP required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Harness files live untracked in the serving repo: provisioning's
# `git reset --hard` and `sha256sum -c` both leave them alone.
install -m 0755 "$SCRIPT_DIR/bench-entrypoint.sh" "$SERVING_DIR/bench-entrypoint.sh"
install -m 0644 "$SCRIPT_DIR/compose.override.yaml" "$SERVING_DIR/compose.override.yaml"
install -m 0644 "$SCRIPT_DIR/bench-worker-utils.zeroer-fix.py" "$SERVING_DIR/bench-worker-utils.zeroer-fix.py"
install -m 0644 "$SCRIPT_DIR/bench-gemm-op-a8w8.m-round-up.py" "$SERVING_DIR/bench-gemm-op-a8w8.m-round-up.py"
install -m 0644 "$SCRIPT_DIR/tuning/dsv4-a8w8-blockscale-tuned-gemm.mi300x.grid-tuned.csv" \
  "$SERVING_DIR/tuning/dsv4-a8w8-blockscale-tuned-gemm.mi300x.grid-tuned.csv"
install -m 0644 "$SCRIPT_DIR/tuning/dsv4-mi300x-a8w8-blockscale-bpreshuffle-ck.grid-tuned.csv" \
  "$SERVING_DIR/tuning/dsv4-mi300x-a8w8-blockscale-bpreshuffle-ck.grid-tuned.csv"

# Memory headroom. Refuted as the fault cause, but 4 GB of headroom is
# healthier than 66 MB. Runtime-only; reapply after any reboot.
sysctl -w vm.compaction_proactiveness=0
sysctl -w vm.min_free_kbytes=4194304

# Keep operator SSH ahead of ufw's rate limiter, and stop apt timers from
# competing with the engine's two saturated cores.
if command -v ufw >/dev/null 2>&1; then
  ufw insert 1 allow from "$OPERATOR_IP" to any port 22 proto tcp
fi

# Every lane's clone operation shares one multiplexed SSH connection; stock
# MaxSessions 10 refuses the mux herd when 32+ lanes scale up at once.
printf 'MaxSessions 128\nMaxStartups 64:30:256\n' > /etc/ssh/sshd_config.d/99-bench.conf
systemctl reload ssh
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# dmesg wraps under load, which already cost one miscounted baseline. Persist
# every amdgpu kernel line with wall-clock timestamps instead.
cat > /etc/systemd/system/gpu-fault-log.service <<'EOF'
[Unit]
Description=Persist amdgpu kernel messages to /root/gpu-faults.log
After=multi-user.target

[Service]
ExecStart=/bin/sh -c 'dmesg --follow-new --time-format iso | grep --line-buffered amdgpu >> /root/gpu-faults.log'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now gpu-fault-log.service

# The AITER shape census is harvested from engine stdout, which dies with a
# recreated container. Reattach replays every line; -t makes duplicates exact,
# so harvest with sort -u.
cat > /etc/systemd/system/engine-log.service <<'EOF'
[Unit]
Description=Persist inference container logs to /root/engine.log
After=docker.service

[Service]
ExecStart=/bin/sh -c 'docker logs -f -t deepseek-v4-inference-1 >> /root/engine.log 2>&1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now engine-log.service

# Recreate the engine under the override: pinned baseline (spec decode on,
# KV offload on, XNACK off, coredump off) + zeroer fix + debug agent +
# m2688 scheduler + AITER M round-up overlay + grid-tuned GEMM tables.
(cd "$SERVING_DIR" && docker compose config -q && docker compose up -d inference)

echo "bench-setup: done. Confirm the 'bench-entrypoint:' line in docker logs."
