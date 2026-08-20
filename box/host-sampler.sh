#!/bin/sh
set -u

OUT=/root/host-samples.csv
[ -s "$OUT" ] || echo 'ts,load1,memfree_kb,containers,engine_cpu_pct,gpu_busy_pct,gpu_power_w' >> "$OUT"

gpu_power_w() {
  for f in /sys/class/hwmon/hwmon*/power1_average /sys/class/hwmon/hwmon*/power1_input; do
    [ -r "$f" ] || continue
    awk '{ printf "%.0f", $1 / 1000000 }' "$f"
    return
  done
}

while :; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%S)
  load1=$(awk '{ print $1 }' /proc/loadavg)
  memfree=$(awk '/^MemFree:/ { print $2 }' /proc/meminfo)
  containers=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  engine_cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' deepseek-v4-inference-1 2>/dev/null | tr -d '%')
  busy=$(cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1)
  echo "$ts,$load1,$memfree,$containers,${engine_cpu:-},${busy:-},$(gpu_power_w)" >> "$OUT"
  sleep 10
done
