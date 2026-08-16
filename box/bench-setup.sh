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

# Memory headroom. Refuted as the fault cause, but 4 GB of headroom is
# healthier than 66 MB. Runtime-only; reapply after any reboot.
sysctl -w vm.compaction_proactiveness=0
sysctl -w vm.min_free_kbytes=4194304

# Keep operator SSH ahead of ufw's rate limiter, and stop apt timers from
# competing with the engine's two saturated cores.
if command -v ufw >/dev/null 2>&1; then
  ufw insert 1 allow from "$OPERATOR_IP" to any port 22 proto tcp
fi
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

# Recreate the engine under the override. Window 1 config: XNACK on,
# spec decode on, KV offload on, coredump off.
(cd "$SERVING_DIR" && docker compose config -q && docker compose up -d inference)

echo "bench-setup: done. Confirm the 'bench-entrypoint:' line in docker logs."
