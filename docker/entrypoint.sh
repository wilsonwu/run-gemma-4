#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[entrypoint] $*"
}

normalize_proxy_env() {
  if [[ -n "${HTTP_PROXY:-}" && -z "${http_proxy:-}" ]]; then
    export http_proxy="${HTTP_PROXY}"
  fi

  if [[ -n "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then
    export https_proxy="${HTTPS_PROXY}"
  fi

  if [[ -n "${NO_PROXY:-}" && -z "${no_proxy:-}" ]]; then
    export no_proxy="${NO_PROXY}"
  fi
}

start_llama() {
  local model_path="${MODEL_PATH:-/models/gemma-4-E2B-it-Q4_K_M.gguf}"
  local service_port="${SERVICE_PORT:-8080}"
  local context_size="${CONTEXT_SIZE:-8192}"
  local batch_size="${BATCH_SIZE:-256}"
  local threads="${LLAMA_THREADS:-$(nproc)}"
  local model_alias="${MODEL_ALIAS:-gemma-4-e2b-it-q4km}"

  if [[ ! -f "$model_path" ]]; then
    log "MODEL_PATH does not exist: $model_path"
    exit 1
  fi

  log "starting llama.cpp on port $service_port with model $model_path"
  exec llama-server \
    -m "$model_path" \
    --host 0.0.0.0 \
    --port "$service_port" \
    --alias "$model_alias" \
    -c "$context_size" \
    -b "$batch_size" \
    -t "$threads"
}

main() {
  normalize_proxy_env
  start_llama
}

main "$@"
