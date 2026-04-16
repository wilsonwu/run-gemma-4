#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
REPO_ROOT=""
ENV_TEMPLATE=""
ENV_FILE=""

REMOTE_REPO_URL="https://github.com/wilsonwu/run-gemma-4"
REMOTE_REF="${RUN_GEMMA_REF:-main}"
ASSET_BASE_URL="${RUN_GEMMA_ASSET_BASE_URL:-}"
INSTALL_DIR="${RUN_GEMMA_INSTALL_DIR:-}"

SHELL_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
SHELL_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
SHELL_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

NON_INTERACTIVE=0
NO_START=0
FORCE_RECREATE=0
BOOTSTRAP_MODE=0

OS_NAME=""
COMPOSE_NAME=""
COMPOSE_CMD=()
CONFIGURE_VALUES=1
WRITE_ENV_FILE=0

IMAGE_REPO=""
IMAGE_TAG=""
HOST_PORT=""
MODEL_PREPARE_MODE=""
MODEL_ALIAS=""
MODEL_PATH=""
MODEL_URL=""
MODEL_SHA256=""
CONTEXT_SIZE=""
BATCH_SIZE=""
LLAMA_THREADS=""
HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY=""

TEMPLATE_IMAGE_REPO=""
TEMPLATE_MODEL_URL=""
TEMPLATE_MODEL_SHA256=""
TEMPLATE_NO_PROXY=""

NETWORK_DETECTION_RAN=0
NETWORK_PROFILE="unknown"
NETWORK_REASON="Network probing has not run yet."
NETWORK_GITHUB_STATUS="not-tested"
NETWORK_GHCR_STATUS="not-tested"
NETWORK_MODELSCOPE_STATUS="not-tested"

log() {
  printf '[install] %s\n' "$*"
}

warn() {
  printf '[install] warning: %s\n' "$*" >&2
}

die() {
  printf '[install] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Interactive Docker Compose launcher for run-gemma-4.

You can run it from a cloned repository, or stream it directly:
  curl -fsSL https://raw.githubusercontent.com/wilsonwu/run-gemma-4/main/install.sh | bash

When streamed, the installer downloads compose.yaml and .env.example into a
local install directory before writing .env and starting Docker Compose.

Options:
  -y, --yes                 Accept defaults and skip interactive prompts.
  --force                   Recreate .env from template defaults instead of reusing it.
  --no-start                Write .env only. Do not start Docker Compose.
  --install-dir PATH        Target directory for online installs. Defaults to ./run-gemma-4.
  --ref REF                 Git ref used for raw asset downloads. Defaults to main.
  --asset-base-url URL      Override the raw asset base URL.
  -h, --help                Show this help message.

Windows note:
  Run this script from Git Bash or WSL after Docker Desktop is already running.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        NON_INTERACTIVE=1
        ;;
      --force)
        FORCE_RECREATE=1
        ;;
      --no-start)
        NO_START=1
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die '--install-dir requires a value'
        INSTALL_DIR="$2"
        shift
        ;;
      --ref)
        [[ $# -ge 2 ]] || die '--ref requires a value'
        REMOTE_REF="$2"
        shift
        ;;
      --asset-base-url)
        [[ $# -ge 2 ]] || die '--asset-base-url requires a value'
        ASSET_BASE_URL="$2"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done
}

detect_os() {
  case "$(uname -s)" in
    Linux*)
      OS_NAME="linux"
      ;;
    Darwin*)
      OS_NAME="macos"
      ;;
    CYGWIN*|MINGW*|MSYS*)
      OS_NAME="windows"
      ;;
    *)
      OS_NAME="unknown"
      ;;
  esac
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local suffix="[y/N]"
  local answer=""

  if [[ "$default_answer" == "y" ]]; then
    suffix="[Y/n]"
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    [[ "$default_answer" == "y" ]]
    return
  fi

  while true; do
    printf '%s %s ' "$prompt" "$suffix"
    IFS= read -r answer
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      answer="$default_answer"
    fi

    case "$answer" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
    esac

    warn 'please answer y or n'
  done
}

prompt_with_default() {
  local prompt="$1"
  local variable_name="$2"
  local default_value="$3"
  local allow_empty="$4"
  local clearable="$5"
  local input=""

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    printf -v "$variable_name" '%s' "$default_value"
    return
  fi

  while true; do
    if [[ -n "$default_value" ]]; then
      if [[ "$clearable" -eq 1 ]]; then
        printf '%s [%s] (Enter to keep, - to clear): ' "$prompt" "$default_value"
      else
        printf '%s [%s]: ' "$prompt" "$default_value"
      fi
    else
      printf '%s: ' "$prompt"
    fi

    IFS= read -r input

    if [[ -z "$input" ]]; then
      input="$default_value"
    elif [[ "$clearable" -eq 1 && "$input" == '-' ]]; then
      input=""
    fi

    if [[ "$allow_empty" -eq 0 && -z "$input" ]]; then
      warn 'this value cannot be empty'
      continue
    fi

    printf -v "$variable_name" '%s' "$input"
    return
  done
}

prompt_positive_integer() {
  local prompt="$1"
  local variable_name="$2"
  local default_value="$3"
  local max_value="${4:-}"
  local input=""

  while true; do
    prompt_with_default "$prompt" "$variable_name" "$default_value" 0 0
    input="${!variable_name}"

    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
      warn 'please enter a positive integer'
      continue
    fi

    if [[ "$input" -lt 1 ]]; then
      warn 'value must be greater than zero'
      continue
    fi

    if [[ -n "$max_value" && "$input" -gt "$max_value" ]]; then
      warn "value must be less than or equal to $max_value"
      continue
    fi

    return
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

set_repo_paths() {
  ENV_TEMPLATE="${REPO_ROOT}/.env.example"
  ENV_FILE="${REPO_ROOT}/.env"
}

resolve_asset_base_url() {
  if [[ -n "$ASSET_BASE_URL" ]]; then
    return
  fi

  ASSET_BASE_URL="https://raw.githubusercontent.com/wilsonwu/run-gemma-4/${REMOTE_REF}"
}

asset_url() {
  local relative_path="$1"
  printf '%s/%s' "${ASSET_BASE_URL%/}" "$relative_path"
}

backup_if_changed() {
  local current_path="$1"
  local new_path="$2"
  local backup_path=""

  if [[ ! -f "$current_path" ]]; then
    return
  fi

  if cmp -s "$current_path" "$new_path"; then
    return
  fi

  backup_path="${current_path}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$current_path" "$backup_path"
  log "backed up $(basename "$current_path") to $(basename "$backup_path")"
}

download_asset() {
  local relative_path="$1"
  local destination_path="$2"
  local tmp_path="${destination_path}.tmp"
  local source_url=""

  source_url="$(asset_url "$relative_path")"
  log "downloading $relative_path from $source_url"
  curl -fsSL "$source_url" -o "$tmp_path"

  if [[ -f "$destination_path" ]] && cmp -s "$destination_path" "$tmp_path"; then
    rm -f "$tmp_path"
    return
  fi

  backup_if_changed "$destination_path" "$tmp_path"
  mv "$tmp_path" "$destination_path"
}

load_env_values() {
  local file_path="$1"
  local line=""
  local key=""
  local value=""

  [[ -f "$file_path" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    case "$line" in
      ''|\#*)
        continue
        ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      IMAGE_REPO|IMAGE_TAG|HOST_PORT|MODEL_PREPARE_MODE|MODEL_ALIAS|MODEL_PATH|MODEL_URL|MODEL_SHA256|CONTEXT_SIZE|BATCH_SIZE|LLAMA_THREADS|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file_path"
}

load_template_defaults() {
  IMAGE_REPO=""
  IMAGE_TAG=""
  HOST_PORT=""
  MODEL_PREPARE_MODE=""
  MODEL_ALIAS=""
  MODEL_PATH=""
  MODEL_URL=""
  MODEL_SHA256=""
  CONTEXT_SIZE=""
  BATCH_SIZE=""
  LLAMA_THREADS=""
  HTTP_PROXY=""
  HTTPS_PROXY=""
  NO_PROXY=""
  load_env_values "$ENV_TEMPLATE"

  TEMPLATE_IMAGE_REPO="$IMAGE_REPO"
  TEMPLATE_MODEL_URL="$MODEL_URL"
  TEMPLATE_MODEL_SHA256="$MODEL_SHA256"
  TEMPLATE_NO_PROXY="$NO_PROXY"
}

resolve_runtime_root() {
  local candidate_dir=""

  if [[ -n "$SCRIPT_SOURCE" ]]; then
    candidate_dir="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || true)"
  fi

  if [[ -n "$candidate_dir" && -f "$candidate_dir/compose.yaml" && -f "$candidate_dir/.env.example" ]]; then
    SCRIPT_DIR="$candidate_dir"
    REPO_ROOT="$candidate_dir"
    BOOTSTRAP_MODE=0
    set_repo_paths
    return
  fi

  BOOTSTRAP_MODE=1
  resolve_asset_base_url
  require_command curl || die 'curl is required for online installation'

  if [[ -z "$INSTALL_DIR" ]]; then
    INSTALL_DIR="${PWD}/run-gemma-4"
  fi

  prompt_with_default 'Install directory' INSTALL_DIR "$INSTALL_DIR" 0 0
  mkdir -p "$INSTALL_DIR"
  REPO_ROOT="$(cd "$INSTALL_DIR" && pwd)"
  set_repo_paths

  download_asset 'compose.yaml' "${REPO_ROOT}/compose.yaml"
  download_asset '.env.example' "$ENV_TEMPLATE"
}

probe_url_status() {
  local url="$1"
  local variable_name="$2"
  local http_code=""

  http_code="$(curl -L -o /dev/null -sS --connect-timeout 2 --max-time 6 -w '%{http_code}' "$url" 2>/dev/null || true)"

  if [[ "$http_code" =~ ^[1-5][0-9][0-9]$ && "$http_code" != '000' ]]; then
    printf -v "$variable_name" '%s' 'reachable'
  else
    printf -v "$variable_name" '%s' 'restricted'
  fi
}

has_shell_proxy_defaults() {
  [[ -n "$SHELL_HTTP_PROXY" || -n "$SHELL_HTTPS_PROXY" || -n "$SHELL_NO_PROXY" ]]
}

detect_network_profile() {
  if [[ "$NETWORK_DETECTION_RAN" -eq 1 ]]; then
    return
  fi

  NETWORK_DETECTION_RAN=1

  if ! require_command curl; then
    NETWORK_PROFILE='unknown'
    NETWORK_REASON='curl is not available on the host, so network probing was skipped.'
    NETWORK_GITHUB_STATUS='unknown'
    NETWORK_GHCR_STATUS='unknown'
    NETWORK_MODELSCOPE_STATUS='unknown'
    return
  fi

  log 'probing GitHub, GHCR, and ModelScope reachability'
  probe_url_status 'https://github.com/' NETWORK_GITHUB_STATUS
  probe_url_status 'https://ghcr.io/v2/' NETWORK_GHCR_STATUS
  probe_url_status 'https://www.modelscope.cn/' NETWORK_MODELSCOPE_STATUS

  if [[ "$NETWORK_MODELSCOPE_STATUS" == 'reachable' && "$NETWORK_GHCR_STATUS" != 'reachable' ]]; then
    NETWORK_PROFILE='mainland-china-like'
    if [[ "$NETWORK_GITHUB_STATUS" != 'reachable' ]]; then
      NETWORK_REASON='ModelScope is reachable while GitHub and GHCR look restricted.'
    else
      NETWORK_REASON='ModelScope is reachable while GHCR looks restricted from this network.'
    fi
    return
  fi

  if [[ "$NETWORK_GITHUB_STATUS" == 'reachable' && "$NETWORK_GHCR_STATUS" == 'reachable' ]]; then
    NETWORK_PROFILE='global'
    NETWORK_REASON='GitHub and GHCR are reachable from this network.'
    return
  fi

  NETWORK_PROFILE='unknown'
  NETWORK_REASON='Network checks were inconclusive.'
}

show_network_detection_summary() {
  printf '\nNetwork detection\n'
  printf '  GitHub: %s\n' "$NETWORK_GITHUB_STATUS"
  printf '  GHCR: %s\n' "$NETWORK_GHCR_STATUS"
  printf '  ModelScope: %s\n' "$NETWORK_MODELSCOPE_STATUS"
  printf '  Profile: %s\n' "$NETWORK_PROFILE"
  printf '  Hint: %s\n' "$NETWORK_REASON"

  if has_shell_proxy_defaults; then
    printf '  Shell proxies: detected and available for import\n'
  fi
}

apply_mainland_network_defaults() {
  if [[ -z "$MODEL_URL" ]]; then
    MODEL_URL="$TEMPLATE_MODEL_URL"
  fi

  if [[ -z "$MODEL_SHA256" ]]; then
    MODEL_SHA256="$TEMPLATE_MODEL_SHA256"
  fi

  if [[ -z "$HTTP_PROXY" && -n "$SHELL_HTTP_PROXY" ]]; then
    HTTP_PROXY="$SHELL_HTTP_PROXY"
  fi

  if [[ -z "$HTTPS_PROXY" && -n "$SHELL_HTTPS_PROXY" ]]; then
    HTTPS_PROXY="$SHELL_HTTPS_PROXY"
  fi

  if [[ -z "$NO_PROXY" ]]; then
    if [[ -n "$SHELL_NO_PROXY" ]]; then
      NO_PROXY="$SHELL_NO_PROXY"
    else
      NO_PROXY="$TEMPLATE_NO_PROXY"
    fi
  fi
}

maybe_apply_network_recommendations() {
  detect_network_profile
  show_network_detection_summary

  case "$NETWORK_PROFILE" in
    mainland-china-like)
      printf '\nSuggested defaults for this network\n'
      printf '  - Keep ModelScope as the model source.\n'

      if has_shell_proxy_defaults; then
        printf '  - Import proxy values from the current shell to help GHCR pulls and model downloads.\n'
      else
        printf '  - GHCR may still be slow or blocked. If you have a proxy or mirrored image repository, enter it below.\n'
      fi

      if ask_yes_no 'Apply these suggested defaults before editing values?' 'y'; then
        apply_mainland_network_defaults
      fi
      ;;
    global)
      printf '\nSuggested defaults for this network\n'
      printf '  - Keep the standard GHCR image source unless you already operate a nearer mirror.\n'
      ;;
    *)
      if has_shell_proxy_defaults; then
        printf '\nProxy values are already present in your shell. You can import them below if needed.\n'
      fi
      ;;
  esac
}

configure_existing_env_strategy() {
  local choice=""

  load_template_defaults

  if [[ ! -f "$ENV_FILE" ]]; then
    CONFIGURE_VALUES=1
    WRITE_ENV_FILE=1
    return
  fi

  if [[ "$FORCE_RECREATE" -eq 1 ]]; then
    CONFIGURE_VALUES=$((1 - NON_INTERACTIVE))
    WRITE_ENV_FILE=1
    return
  fi

  load_env_values "$ENV_FILE"

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    CONFIGURE_VALUES=0
    WRITE_ENV_FILE=0
    return
  fi

  printf '\nExisting .env detected.\n'
  printf '  1) Start with the current .env as-is\n'
  printf '  2) Review and update the current .env\n'
  printf '  3) Recreate .env from template defaults\n'
  printf '  4) Exit\n'

  while true; do
    printf 'Choose an option [1-4]: '
    IFS= read -r choice
    case "$choice" in
      1)
        CONFIGURE_VALUES=0
        WRITE_ENV_FILE=0
        return
        ;;
      2)
        CONFIGURE_VALUES=1
        WRITE_ENV_FILE=1
        return
        ;;
      3)
        load_template_defaults
        CONFIGURE_VALUES=1
        WRITE_ENV_FILE=1
        return
        ;;
      4)
        exit 0
        ;;
    esac
    warn 'please choose 1, 2, 3, or 4'
  done
}

show_configuration() {
  printf '\nConfiguration summary\n'
  printf '  IMAGE_REPO=%s\n' "$IMAGE_REPO"
  printf '  IMAGE_TAG=%s\n' "$IMAGE_TAG"
  printf '  HOST_PORT=%s\n' "$HOST_PORT"
  printf '  MODEL_URL=%s\n' "$MODEL_URL"
  printf '  MODEL_SHA256=%s\n' "${MODEL_SHA256:-<empty>}"
  printf '  MODEL_ALIAS=%s\n' "$MODEL_ALIAS"
  printf '  CONTEXT_SIZE=%s\n' "$CONTEXT_SIZE"
  printf '  BATCH_SIZE=%s\n' "$BATCH_SIZE"
  printf '  LLAMA_THREADS=%s\n' "$LLAMA_THREADS"
  printf '  HTTP_PROXY=%s\n' "${HTTP_PROXY:-<empty>}"
  printf '  HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-<empty>}"
  printf '  NO_PROXY=%s\n' "${NO_PROXY:-<empty>}"
}

prompt_for_configuration() {
  local proxy_default='n'
  local advanced_default='n'

  printf '\nCompose configuration\n'
  printf 'Press Enter to keep a value. Use - on clearable fields to erase the current value.\n'

  maybe_apply_network_recommendations

  if [[ "$NETWORK_PROFILE" == 'mainland-china-like' ]]; then
    proxy_default='y'
  fi

  if [[ "$NETWORK_PROFILE" == 'mainland-china-like' && "$NETWORK_GHCR_STATUS" != 'reachable' ]]; then
    advanced_default='y'
    warn 'GHCR looks restricted from this network. If you have a mirrored image repository, enter it when advanced settings are shown.'
  fi

  prompt_positive_integer 'Host port to expose locally' HOST_PORT "$HOST_PORT" 65535
  prompt_with_default 'Image tag' IMAGE_TAG "$IMAGE_TAG" 0 0
  prompt_with_default 'Model download URL' MODEL_URL "$MODEL_URL" 0 0
  prompt_with_default 'Model SHA256 checksum' MODEL_SHA256 "$MODEL_SHA256" 1 1

  if [[ -n "$HTTP_PROXY" || -n "$HTTPS_PROXY" || -n "$NO_PROXY" ]]; then
    proxy_default='y'
  fi

  if ask_yes_no 'Review proxy settings?' "$proxy_default"; then
    prompt_with_default 'HTTP proxy' HTTP_PROXY "$HTTP_PROXY" 1 1
    prompt_with_default 'HTTPS proxy' HTTPS_PROXY "$HTTPS_PROXY" 1 1
    prompt_with_default 'NO_PROXY list' NO_PROXY "$NO_PROXY" 1 1
  fi

  if ask_yes_no 'Review advanced runtime settings?' "$advanced_default"; then
    prompt_with_default 'Image repository' IMAGE_REPO "$IMAGE_REPO" 0 0
    prompt_with_default 'Model alias' MODEL_ALIAS "$MODEL_ALIAS" 0 0
    prompt_with_default 'Model path inside the container' MODEL_PATH "$MODEL_PATH" 0 0
    prompt_positive_integer 'Context size' CONTEXT_SIZE "$CONTEXT_SIZE"
    prompt_positive_integer 'Batch size' BATCH_SIZE "$BATCH_SIZE"
    prompt_positive_integer 'Llama threads' LLAMA_THREADS "$LLAMA_THREADS"
  fi

  show_configuration

  if ! ask_yes_no 'Write this configuration to .env?' 'y'; then
    die 'aborted by user'
  fi
}

validate_configuration() {
  [[ -n "$IMAGE_REPO" ]] || die 'IMAGE_REPO must not be empty'
  [[ -n "$IMAGE_TAG" ]] || die 'IMAGE_TAG must not be empty'
  [[ -n "$MODEL_ALIAS" ]] || die 'MODEL_ALIAS must not be empty'
  [[ -n "$MODEL_PATH" ]] || die 'MODEL_PATH must not be empty'
  [[ -n "$MODEL_URL" ]] || die 'MODEL_URL must not be empty'

  [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || die 'HOST_PORT must be numeric'
  (( HOST_PORT >= 1 && HOST_PORT <= 65535 )) || die 'HOST_PORT must be between 1 and 65535'
  [[ "$CONTEXT_SIZE" =~ ^[0-9]+$ ]] || die 'CONTEXT_SIZE must be numeric'
  (( CONTEXT_SIZE >= 1 )) || die 'CONTEXT_SIZE must be greater than zero'
  [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || die 'BATCH_SIZE must be numeric'
  (( BATCH_SIZE >= 1 )) || die 'BATCH_SIZE must be greater than zero'
  [[ "$LLAMA_THREADS" =~ ^[0-9]+$ ]] || die 'LLAMA_THREADS must be numeric'
  (( LLAMA_THREADS >= 1 )) || die 'LLAMA_THREADS must be greater than zero'
}

write_env_file() {
  local backup_path=''
  local tmp_path="${ENV_FILE}.tmp"

  if [[ -f "$ENV_FILE" ]]; then
    backup_path="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$ENV_FILE" "$backup_path"
    log "backed up existing .env to $(basename "$backup_path")"
  fi

  cat > "$tmp_path" <<EOF
IMAGE_REPO=$IMAGE_REPO
IMAGE_TAG=$IMAGE_TAG
HOST_PORT=$HOST_PORT

MODEL_PREPARE_MODE=$MODEL_PREPARE_MODE
MODEL_ALIAS=$MODEL_ALIAS
MODEL_PATH=$MODEL_PATH
MODEL_URL=$MODEL_URL
MODEL_SHA256=$MODEL_SHA256

CONTEXT_SIZE=$CONTEXT_SIZE
BATCH_SIZE=$BATCH_SIZE
LLAMA_THREADS=$LLAMA_THREADS

HTTP_PROXY=$HTTP_PROXY
HTTPS_PROXY=$HTTPS_PROXY
NO_PROXY=$NO_PROXY
EOF

  mv "$tmp_path" "$ENV_FILE"
  log "wrote $(basename "$ENV_FILE")"
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    COMPOSE_NAME='docker compose'
    return
  fi

  if require_command docker-compose && docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    COMPOSE_NAME='docker-compose'
    return
  fi

  die 'Docker Compose was not found. Install Docker Compose V2 or docker-compose.'
}

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

check_runtime_prerequisites() {
  [[ -f "$ENV_TEMPLATE" ]] || die '.env.example is missing'
  [[ -f "${REPO_ROOT}/compose.yaml" ]] || die 'compose.yaml is missing'

  if ! require_command docker; then
    die 'docker is not installed. Install Docker Desktop or Docker Engine first.'
  fi

  if ! docker info >/dev/null 2>&1; then
    if [[ "$OS_NAME" == 'windows' ]]; then
      die 'Docker Engine is not reachable. Start Docker Desktop, then run this script again from Git Bash or WSL.'
    fi
    die 'Docker Engine is not reachable. Start Docker and run this script again.'
  fi

  detect_compose
}

run_compose_workflow() {
  local pull_default='y'

  log 'validating compose configuration'
  compose config -q

  if [[ "$NO_START" -eq 1 ]]; then
    log 'configuration is ready; skipping startup because --no-start was requested'
    return
  fi

  if [[ "$IMAGE_TAG" != 'latest' ]]; then
    pull_default='n'
  fi

  if ask_yes_no 'Pull the image before starting?' "$pull_default"; then
    if ! compose pull; then
      warn 'image pull failed'
      if [[ "$NETWORK_PROFILE" == 'mainland-china-like' ]]; then
        warn 'This network still looks unfriendly to GHCR. Try setting HTTP_PROXY/HTTPS_PROXY or replace IMAGE_REPO with your mirrored registry, then rerun the installer.'
      fi
      if ! ask_yes_no 'Continue with any locally cached image instead?' 'y'; then
        exit 1
      fi
    fi
  fi

  log "starting services with ${COMPOSE_NAME} up -d"
  compose up -d

  printf '\nStarted services\n'
  printf '  Install dir:   %s\n' "$REPO_ROOT"
  printf '  API endpoint:  http://127.0.0.1:%s/completion\n' "$HOST_PORT"
  printf '  Show status:   %s ps\n' "$COMPOSE_NAME"
  printf '  Show logs:     %s logs -f prepare-model gemma\n' "$COMPOSE_NAME"
  printf '  Stop later:    %s down\n' "$COMPOSE_NAME"

  if ask_yes_no 'Follow startup logs now?' 'y'; then
    compose logs -f prepare-model gemma
  fi
}

print_intro() {
  printf 'Run Gemma 4 Compose Installer\n'
  printf 'Mode: %s\n' "$([[ "$BOOTSTRAP_MODE" -eq 1 ]] && printf 'online bootstrap' || printf 'local repository')"
  printf 'Repository source: %s\n' "$REMOTE_REPO_URL"
  if [[ "$BOOTSTRAP_MODE" -eq 1 ]]; then
    printf 'Asset source: %s\n' "$ASSET_BASE_URL"
  fi
  printf 'Install directory: %s\n' "$REPO_ROOT"
  printf 'Detected OS: %s\n' "$OS_NAME"

  if [[ "$OS_NAME" == 'windows' ]]; then
    printf 'Shell note: run this script from Git Bash or WSL. Docker Desktop must already be running.\n'
  fi
}

main() {
  parse_args "$@"
  detect_os
  resolve_runtime_root
  cd "$REPO_ROOT"
  print_intro
  check_runtime_prerequisites
  configure_existing_env_strategy

  if [[ "$CONFIGURE_VALUES" -eq 1 ]]; then
    prompt_for_configuration
  fi

  validate_configuration

  if [[ "$WRITE_ENV_FILE" -eq 1 ]]; then
    write_env_file
  else
    log 'using existing .env without changes'
  fi

  run_compose_workflow
}

main "$@"