#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVING_REPO_URL="https://github.com/ryanzhou/deepseek-v4-flash-mi300x.git"
readonly SERVING_REPO_COMMIT="7c06e57ee4c9cd6c4ba4d70e8a6422aa6d5562f0"
readonly SERVING_REPO_DIR="/root/dev/deepseek-v4-flash-mi300x"
readonly VLLM_IMAGE="vllm/vllm-openai-rocm@sha256:e68d18b2ba50298661bfc49baf01158fbf036645c2362cccf3e8a7a79fe6c69a"
readonly MODEL="deepseek-ai/DeepSeek-V4-Flash-0731"
readonly MODEL_REVISION="7872f01b1d1fe23eabc4c98b48bffcef5a386062"
readonly MODEL_SNAPSHOT="/root/.cache/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731/snapshots/${MODEL_REVISION}"

readonly MISE_VERSION="2026.8.5"
readonly MISE_ARCHIVE_SHA256="f0de92940835ce6af5d0e1496daead7c4464c478046967341fab7d671d0a316b"
readonly ERLANG_VERSION="28.5.0.4"
readonly ELIXIR_VERSION="1.19.5-otp-28"
readonly PYTHON_VERSION="3.14.7"
readonly NODE_VERSION="24.7.0"
readonly BUN_VERSION="1.2.20"
readonly UV_VERSION="0.12.4"
readonly YARN_VERSION="1.22.22"
readonly OPENCODE_VERSION="1.18.18"

readonly VLLM_PROXY_IMAGE="alpine/socat@sha256:beb4a68d9e4fe6b0f21ea774a0fde6c31f580dde6368939ed70100c5385b015e"
readonly VLLM_PROXY_CONTAINER="agent-coding-bench-vllm-proxy"
readonly VLLM_CONTAINER="deepseek-v4-inference-1"
readonly WORLD_ROOT="/root/world"
readonly MIRROR_ROOT="${WORLD_ROOT}/mirrors"
readonly CACHE_WARM_ROOT="${WORLD_ROOT}/cache-warm"
readonly MISE_BIN="/usr/local/bin/mise"
readonly MISE_SHIMS="/root/.local/share/mise/shims"

step() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this provisioner as root"
}

install_host_packages() {
  step "Installing host packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y \
    autoconf \
    build-essential \
    ca-certificates \
    curl \
    git \
    jq \
    libncurses-dev \
    libssh-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    m4 \
    tar \
    unzip \
    xz-utils \
    zlib1g-dev

  if ! command -v docker >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 install -y docker.io
  fi

  if ! docker compose version >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 install -y docker-compose-v2
  fi

  systemctl enable --now docker
  docker compose version >/dev/null
}

verify_host_capacity() {
  step "Verifying MI300X host capacity"
  local memory_kib
  local disk_bytes
  local shared_memory_bytes

  [[ -e /dev/kfd ]] || die "AMD /dev/kfd device is unavailable"
  memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  disk_bytes="$(df --output=avail -B1 / | tail -n 1 | tr -d ' ')"
  shared_memory_bytes="$(df --output=size -B1 /dev/shm | tail -n 1 | tr -d ' ')"

  ((memory_kib >= 220 * 1024 * 1024)) || die "At least 220 GiB of host RAM is required"
  ((disk_bytes >= 350 * 1024 * 1024 * 1024)) || die "At least 350 GiB of free disk is required"
  ((shared_memory_bytes >= 110 * 1024 * 1024 * 1024)) || die "/dev/shm must be at least 110 GiB"
  docker info >/dev/null
}

disable_debugfs() {
  step "Disabling debugfs"
  # Reading /sys/kernel/debug/dri/*/amdgpu_evict_vram evicts every VRAM buffer
  # object. Against a live vLLM the eviction never converges, so the GPU stalls
  # and the reading process wedges unkillably inside the syscall. Bench agents
  # run as root, so one `grep -r` from / is enough to trigger it. Nothing here
  # needs debugfs: rocm-smi reads /sys/class/drm, and the serving container has
  # no debugfs mount at all.
  #
  # Stop before masking: systemd unmounts the nested tracing mount in order,
  # which a bare `umount -R` races and loses.
  systemctl stop sys-kernel-debug-tracing.mount sys-kernel-debug.mount 2>/dev/null || true
  systemctl mask sys-kernel-debug-tracing.mount sys-kernel-debug.mount
  umount -R /sys/kernel/debug 2>/dev/null || true
  ! mountpoint -q /sys/kernel/debug
}

install_mise() {
  if [[ -x "$MISE_BIN" ]] && [[ "$($MISE_BIN --version)" == *"$MISE_VERSION"* ]]; then
    return
  fi

  step "Installing mise ${MISE_VERSION}"
  local archive
  local extract_directory

  archive="$(mktemp)"
  extract_directory="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64.tar.gz" \
    -o "$archive"
  printf '%s  %s\n' "$MISE_ARCHIVE_SHA256" "$archive" | sha256sum -c -
  tar -xzf "$archive" -C "$extract_directory"
  install -m 0755 "$extract_directory/mise/bin/mise" "$MISE_BIN"
  rm -f "$archive"
  rm -rf "$extract_directory"
}

install_toolchains() {
  step "Installing pinned World Repo toolchains"
  export KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-odbc"

  "$MISE_BIN" use --global \
    "erlang@${ERLANG_VERSION}" \
    "elixir@${ELIXIR_VERSION}" \
    "python@${PYTHON_VERSION}" \
    "node@${NODE_VERSION}" \
    "bun@${BUN_VERSION}" \
    "uv@${UV_VERSION}"
  "$MISE_BIN" settings set trusted_config_paths /root/world

  "$MISE_BIN" exec -- mix local.hex --force
  "$MISE_BIN" exec -- mix local.rebar --force
  "$MISE_BIN" exec -- npm install --global \
    "opencode-ai@${OPENCODE_VERSION}" \
    "yarn@${YARN_VERSION}"
  "$MISE_BIN" reshim

  if ! grep -Fq 'mise activate bash' /root/.bashrc 2>/dev/null; then
    printf '\neval "$(/usr/local/bin/mise activate bash)"\n' >> /root/.bashrc
  fi
}

configure_git() {
  step "Configuring the bench Git identity"
  git config --global user.name "Agent Coding Bench"
  git config --global user.email "agent-coding-bench@localhost"
  git config --global init.defaultBranch main
}

checkout_serving_stack() {
  step "Checking out the pinned serving stack"
  mkdir -p "$(dirname "$SERVING_REPO_DIR")"

  if [[ ! -d "${SERVING_REPO_DIR}/.git" ]]; then
    git clone "$SERVING_REPO_URL" "$SERVING_REPO_DIR"
  fi

  git -C "$SERVING_REPO_DIR" remote set-url origin "$SERVING_REPO_URL"
  git -C "$SERVING_REPO_DIR" fetch --depth 1 origin "$SERVING_REPO_COMMIT"
  git -C "$SERVING_REPO_DIR" checkout --detach "$SERVING_REPO_COMMIT"
  git -C "$SERVING_REPO_DIR" reset --hard "$SERVING_REPO_COMMIT"

  mkdir -p \
    "${SERVING_REPO_DIR}/aiter-cache" \
    "${SERVING_REPO_DIR}/crash-dumps"
  chmod +x "${SERVING_REPO_DIR}/vllm-entrypoint.sh"
  (cd "$SERVING_REPO_DIR" && sha256sum -c SHA256SUMS)
}

download_serving_artifacts() {
  step "Downloading the pinned vLLM image and model"
  docker pull "$VLLM_IMAGE"

  if [[ ! -d "$MODEL_SNAPSHOT" ]]; then
    docker run --rm \
      --entrypoint hf \
      -v /root/.cache/huggingface:/root/.cache/huggingface \
      "$VLLM_IMAGE" \
      download "$MODEL" --revision "$MODEL_REVISION"
  fi
}

start_vllm() {
  step "Starting vLLM"
  (cd "$SERVING_REPO_DIR" && docker compose up -d inference)

  local attempts=0
  local health

  until [[ $attempts -ge 90 ]]; do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$VLLM_CONTAINER" 2>/dev/null || true)"

    case "$health" in
      healthy)
        return
        ;;
      unhealthy|exited|dead)
        docker logs --tail 200 "$VLLM_CONTAINER" >&2 || true
        die "vLLM entered state: $health"
        ;;
    esac

    attempts=$((attempts + 1))
    sleep 10
  done

  docker logs --tail 200 "$VLLM_CONTAINER" >&2 || true
  die "vLLM did not become healthy within 15 minutes"
}

start_vllm_proxy() {
  step "Publishing vLLM on box loopback"
  docker pull "$VLLM_PROXY_IMAGE"
  docker rm -f "$VLLM_PROXY_CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$VLLM_PROXY_CONTAINER" \
    --restart unless-stopped \
    --network deepseek-v4_default \
    -p 127.0.0.1:8000:8000 \
    "$VLLM_PROXY_IMAGE" \
    -dd \
    TCP-LISTEN:8000,fork,reuseaddr \
    TCP:inference:8000
}

configure_opencode() {
  step "Configuring opencode ${OPENCODE_VERSION}"
  mkdir -p /root/.config/opencode "$WORLD_ROOT"

  cat > /root/.config/opencode/opencode.json <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "vllm/${MODEL}",
  "autoupdate": false,
  "share": "disabled",
  "enabled_providers": ["vllm"],
  "provider": {
    "vllm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local vLLM",
      "options": {
        "baseURL": "http://127.0.0.1:8000/v1"
      },
      "models": {
        "${MODEL}": {
          "name": "DeepSeek V4 Flash",
          "limit": {
            "context": 262144,
            "output": 32768
          }
        }
      }
    }
  },
  "permission": "allow"
}
EOF

  cat > /etc/systemd/system/opencode.service <<EOF
[Unit]
Description=Agent Coding Bench opencode server
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORLD_ROOT}
Environment=HOME=/root
Environment=PATH=${MISE_SHIMS}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=MISE_TRUSTED_CONFIG_PATHS=${WORLD_ROOT}
ExecStart=${MISE_SHIMS}/opencode serve --hostname 127.0.0.1 --port 4096 --print-logs
Restart=always
RestartSec=2

# Agents inherit this unit's mount namespace, so these cover every command they
# spawn. debugfs is already unmounted host-wide; this keeps it unreachable even
# if something remounts it. Agents never need the GPU devices directly - they
# reach the model over HTTP on 127.0.0.1:8000 - so PrivateDevices takes away
# /dev/kfd and /dev/dri. Note that read-only protections such as
# ProtectKernelTunables would not help: the eviction is triggered by a read.
InaccessiblePaths=/sys/kernel/debug
PrivateDevices=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now opencode.service
  systemctl restart opencode.service
}

ensure_mirror() {
  local slug="$1"
  local clone_directory="$2"
  local upstream_url="$3"
  local mirror_path="${MIRROR_ROOT}/${clone_directory}.git"

  if [[ ! -d "$mirror_path" ]]; then
    git clone --mirror "$upstream_url" "$mirror_path"
  fi

  git --git-dir="$mirror_path" rev-parse --is-bare-repository | grep -qx true
  git --git-dir="$mirror_path" rev-parse HEAD >/dev/null
  printf '  ready: %s\n' "$slug"
}

create_mirrors() {
  step "Creating World Repo Mirrors"
  mkdir -p "$MIRROR_ROOT"

  ensure_mirror "wojtekmach/req" "req" "https://github.com/wojtekmach/req.git"
  ensure_mirror "oban-bg/oban" "oban" "https://github.com/oban-bg/oban.git"
  ensure_mirror "supabase/realtime" "realtime" "https://github.com/supabase/realtime.git"
  ensure_mirror "livebook-dev/livebook" "livebook" "https://github.com/livebook-dev/livebook.git"
  ensure_mirror "pallets/flask" "flask" "https://github.com/pallets/flask.git"
  ensure_mirror "pydantic/pydantic" "pydantic" "https://github.com/pydantic/pydantic.git"
  ensure_mirror "honojs/hono" "hono" "https://github.com/honojs/hono.git"
  ensure_mirror "excalidraw/excalidraw" "excalidraw" "https://github.com/excalidraw/excalidraw.git"
}

warm_repo() {
  local clone_directory="$1"
  shift
  local scratch_path="${CACHE_WARM_ROOT}/${clone_directory}"

  rm -rf "$scratch_path"
  git clone "${MIRROR_ROOT}/${clone_directory}.git" "$scratch_path"
  (cd "$scratch_path" && "$@")
  rm -rf "$scratch_path"
  printf '  warmed: %s\n' "$clone_directory"
}

warm_dependency_caches() {
  step "Warming dependency caches"
  mkdir -p "$CACHE_WARM_ROOT"

  warm_repo "req" "$MISE_BIN" exec -- mix deps.get
  warm_repo "oban" "$MISE_BIN" exec -- mix deps.get
  warm_repo "realtime" "$MISE_BIN" exec -- mix deps.get
  warm_repo "livebook" "$MISE_BIN" exec -- mix deps.get
  warm_repo "flask" "$MISE_BIN" exec -- uv sync --locked --no-install-project
  warm_repo "pydantic" "$MISE_BIN" exec -- uv sync --locked --no-install-workspace
  warm_repo "hono" "$MISE_BIN" exec -- bun install --frozen-lockfile
  warm_repo "excalidraw" "$MISE_BIN" exec -- yarn install --frozen-lockfile

  rmdir "$CACHE_WARM_ROOT" 2>/dev/null || true
}

verify() {
  step "Verifying the provisioned box"
  curl -fsS http://127.0.0.1:8000/metrics >/dev/null
  ! mountpoint -q /sys/kernel/debug
  # Assert on the nodes themselves, not on a listing: InaccessiblePaths leaves
  # an empty mode-000 directory, and root reads that happily.
  systemd-run --quiet --pipe --wait --property=InaccessiblePaths=/sys/kernel/debug \
    --property=PrivateDevices=yes \
    /bin/sh -c '! test -e /sys/kernel/debug/dri && ! test -e /dev/kfd'

  local attempts=0
  until curl -fsS http://127.0.0.1:4096/doc >/dev/null; do
    attempts=$((attempts + 1))
    ((attempts < 30)) || {
      journalctl -u opencode.service --no-pager -n 100 >&2 || true
      die "opencode did not become ready"
    }
    sleep 2
  done

  [[ "$("$MISE_BIN" exec -- erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)" == "28" ]]
  "$MISE_BIN" exec -- elixir --version
  "$MISE_BIN" exec -- python --version
  "$MISE_BIN" exec -- node --version
  "$MISE_BIN" exec -- bun --version
  "$MISE_BIN" exec -- uv --version
  [[ "$("$MISE_BIN" exec -- opencode --version)" == "$OPENCODE_VERSION" ]]

  for mirror_path in "$MIRROR_ROOT"/*.git; do
    git --git-dir="$mirror_path" rev-parse HEAD >/dev/null
  done

  printf '\nProvisioning complete.\n'
}

main() {
  require_root
  install_host_packages
  verify_host_capacity
  disable_debugfs
  install_mise
  install_toolchains
  configure_git
  checkout_serving_stack
  download_serving_artifacts
  start_vllm
  start_vllm_proxy
  configure_opencode
  create_mirrors
  warm_dependency_caches
  verify
}

main "$@"
