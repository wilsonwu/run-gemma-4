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

download_gguf() {
  local model_path="${MODEL_PATH:-/models/gemma-4-E2B-it-Q4_K_M.gguf}"
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

main() {
  local prepare_mode="${MODEL_PREPARE_MODE:-init}"

  normalize_proxy_env

  if [[ "$prepare_mode" == "skip" ]]; then
    log "MODEL_PREPARE_MODE=skip, nothing to do"
    exit 0
  fi

  download_gguf
}

main "$@"
