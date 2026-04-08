#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[prepare-model] $*"
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

verify_sha256() {
  local file_path="$1"
  local expected_sha256="$2"
  local actual_sha256

  if [[ -z "$expected_sha256" ]]; then
    return 0
  fi

  actual_sha256="$(sha256sum "$file_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    log "checksum mismatch for $file_path: expected $expected_sha256 got $actual_sha256"
    return 1
  fi

  return 0
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
  local model_sha256="${MODEL_SHA256:-}"
  local ready_path="${model_path}.ready"
  local part_path="${model_path}.part"

  if [[ -f "$model_path" && -s "$model_path" ]]; then
    if ! verify_sha256 "$model_path" "$model_sha256"; then
      log "existing GGUF file is invalid, redownloading: $model_path"
      rm -f "$model_path" "$ready_path" "$part_path"
    elif [[ -z "$model_url" || -f "$ready_path" ]]; then
      log "GGUF model already exists: $model_path"
      return
    else
      log "existing GGUF file has no ready marker, resuming download: $model_path"
      mv "$model_path" "$part_path"
    fi
  fi

  if [[ -z "$model_url" ]]; then
    log "MODEL_URL is empty, expecting GGUF model to be pre-mounted at $model_path"
    return
  fi

  mkdir -p "$(dirname "$model_path")"
  if [[ -f "$ready_path" && ! -f "$model_path" ]]; then
    rm -f "$ready_path"
  fi

  log "downloading GGUF model from $model_url"
  curl -fL --retry 5 --retry-delay 5 -C - "$model_url" -o "$part_path"
  mv "$part_path" "$model_path"

  if ! verify_sha256 "$model_path" "$model_sha256"; then
    rm -f "$model_path" "$ready_path"
    exit 1
  fi

  touch "$ready_path"
}

download_hf_repo() {
  local model_path="${MODEL_PATH:-/models/hf-model}"
  local model_id="${HF_MODEL_ID:-}"
  local revision="${HF_MODEL_REVISION:-main}"
  local -a extra_args=()

  if ! command -v huggingface-cli >/dev/null 2>&1; then
    log "transformers download tooling is not installed in this image, build with INSTALL_TRANSFORMERS=1"
    exit 1
  fi

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

  if ! command -v ollama >/dev/null 2>&1; then
    log "ollama runtime is not installed in this image, build with INSTALL_OLLAMA=1"
    exit 1
  fi

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

  normalize_proxy_env

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
