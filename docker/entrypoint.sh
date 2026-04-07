#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[entrypoint] $*"
}

resolve_runtime() {
  local requested="${MODEL_RUNTIME:-auto}"
  local model_path="${MODEL_PATH:-}"
  local model_url="${MODEL_URL:-}"
  local ollama_model="${OLLAMA_MODEL:-}"

  if [[ -n "$requested" && "$requested" != "auto" ]]; then
    echo "$requested"
    return
  fi

  if [[ "$model_path" == *.gguf || "$model_url" == *.gguf* ]]; then
    echo "llama.cpp"
    return
  fi

  if [[ -n "$ollama_model" ]]; then
    echo "ollama"
    return
  fi

  echo "transformers"
}

start_llama() {
  local model_path="${MODEL_PATH:-/models/model.gguf}"
  local service_port="${SERVICE_PORT:-8080}"
  local context_size="${CONTEXT_SIZE:-4096}"
  local batch_size="${BATCH_SIZE:-256}"
  local threads="${LLAMA_THREADS:-$(nproc)}"
  local model_alias="${MODEL_ALIAS:-gemma-4}"

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

start_transformers() {
  local service_port="${SERVICE_PORT:-8080}"

  if [[ -z "${MODEL_PATH:-}" && -z "${HF_MODEL_ID:-}" ]]; then
    log "MODEL_PATH or HF_MODEL_ID is required for transformers runtime"
    exit 1
  fi

  log "starting transformers runtime on port $service_port"
  exec uvicorn transformers_server:app --host 0.0.0.0 --port "$service_port" --app-dir /app
}

start_ollama() {
  local service_port="${SERVICE_PORT:-8080}"

  export OLLAMA_HOST="0.0.0.0:${service_port}"
  export OLLAMA_MODELS="${OLLAMA_MODELS:-/models/ollama}"

  log "starting ollama runtime on port $service_port"
  exec ollama serve
}

main() {
  local runtime
  runtime="$(resolve_runtime)"

  case "$runtime" in
    llama.cpp)
      start_llama
      ;;
    transformers)
      start_transformers
      ;;
    ollama)
      start_ollama
      ;;
    *)
      log "unsupported MODEL_RUNTIME: $runtime"
      exit 1
      ;;
  esac
}

main "$@"
