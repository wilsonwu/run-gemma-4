#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[prepare-model] $*"
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

download_gguf() {
  local model_path="${MODEL_PATH:-/models/model.gguf}"
  local model_url="${MODEL_URL:-}"

  if [[ -f "$model_path" && -s "$model_path" ]]; then
    log "GGUF model already exists: $model_path"
    return
  fi

  if [[ -z "$model_url" ]]; then
    log "MODEL_URL is empty, expecting GGUF model to be pre-mounted at $model_path"
    return
  fi

  mkdir -p "$(dirname "$model_path")"
  log "downloading GGUF model from $model_url"
  curl -fL --retry 5 --retry-delay 5 "$model_url" -o "$model_path"
}

download_hf_repo() {
  local model_path="${MODEL_PATH:-/models/hf-model}"
  local model_id="${HF_MODEL_ID:-}"
  local revision="${HF_MODEL_REVISION:-main}"
  local -a extra_args=()

  if [[ -d "$model_path" ]] && [[ -n "$(find "$model_path" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    log "HF model directory already exists: $model_path"
    return
  fi

  if [[ -z "$model_id" ]]; then
    log "HF_MODEL_ID is empty, expecting Transformers model to be pre-mounted at $model_path"
    return
  fi

  if [[ -n "${HF_TOKEN:-}" ]]; then
    extra_args+=(--token "$HF_TOKEN")
  fi

  mkdir -p "$model_path"
  log "downloading Hugging Face repo $model_id@$revision into $model_path"
  huggingface-cli download "$model_id" \
    --revision "$revision" \
    --local-dir "$model_path" \
    --local-dir-use-symlinks False \
    "${extra_args[@]}"
}

download_ollama_model() {
  local ollama_model="${OLLAMA_MODEL:-}"
  local prepare_host="${OLLAMA_PREPARE_HOST:-127.0.0.1:11434}"
  local server_pid
  local ready=false

  if [[ -z "$ollama_model" ]]; then
    log "OLLAMA_MODEL is empty, skipping ollama pull"
    return
  fi

  export OLLAMA_HOST="$prepare_host"
  export OLLAMA_MODELS="${OLLAMA_MODELS:-/models/ollama}"

  log "starting temporary ollama server on $OLLAMA_HOST"
  ollama serve >/tmp/ollama-init.log 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  for _ in $(seq 1 60); do
    if curl -fsS "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done

  if [[ "$ready" != true ]]; then
    log "ollama API was not ready in time"
    return 1
  fi

  if ollama list | awk 'NR > 1 { print $1 }' | grep -Fxq "$ollama_model"; then
    log "ollama model already present: $ollama_model"
    return
  fi

  log "pulling ollama model: $ollama_model"
  ollama pull "$ollama_model"
}

main() {
  local prepare_mode="${MODEL_PREPARE_MODE:-init}"
  local runtime

  if [[ "$prepare_mode" == "skip" ]]; then
    log "MODEL_PREPARE_MODE=skip, nothing to do"
    exit 0
  fi

  runtime="$(resolve_runtime)"

  case "$runtime" in
    llama.cpp)
      download_gguf
      ;;
    transformers)
      download_hf_repo
      ;;
    ollama)
      download_ollama_model
      ;;
    *)
      log "unsupported MODEL_RUNTIME: $runtime"
      exit 1
      ;;
  esac
}

main "$@"
