#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[publish-ghcr] $*"
}

die() {
  log "$*"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

extract_repo_path() {
  local remote_url="$1"

  case "$remote_url" in
    git@github.com:*.git)
      echo "${remote_url#git@github.com:}" | sed 's/\.git$//'
      ;;
    https://github.com/*.git)
      echo "${remote_url#https://github.com/}" | sed 's/\.git$//'
      ;;
    https://github.com/*)
      echo "${remote_url#https://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
}

if ! command -v docker >/dev/null 2>&1; then
  die "docker is required"
fi

if ! docker buildx version >/dev/null 2>&1; then
  die "docker buildx is required"
fi

REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
if [[ -z "${REMOTE_URL}" ]]; then
  die "git remote 'origin' is not configured"
fi

REPO_PATH="$(extract_repo_path "${REMOTE_URL}")" || die "unsupported GitHub remote: ${REMOTE_URL}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/${REPO_PATH}}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)}"
IMAGE_VERSION="${IMAGE_VERSION:-${IMAGE_TAG}}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
PUSH="${PUSH:-1}"
PUBLISH_LATEST="${PUBLISH_LATEST:-0}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VCS_REF="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
GHCR_USERNAME="${GHCR_USERNAME:-${REPO_PATH%%/*}}"
BUILDER_NAME="${BUILDX_BUILDER:-}"
PIP_INDEX_URL_VALUE="${PIP_INDEX_URL:-https://pypi.org/simple}"
PIP_EXTRA_INDEX_URL_VALUE="${PIP_EXTRA_INDEX_URL:-}"
INSTALL_OLLAMA_VALUE="${INSTALL_OLLAMA:-0}"
INSTALL_TRANSFORMERS_VALUE="${INSTALL_TRANSFORMERS:-0}"
TORCH_INDEX_URL_VALUE="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cpu}"
TORCH_VERSION_VALUE="${TORCH_VERSION:-2.6.0+cpu}"

if [[ -n "${GHCR_TOKEN:-}" ]]; then
  log "logging in to ghcr.io as ${GHCR_USERNAME}"
  printf '%s' "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
else
  log "GHCR_TOKEN is not set, assuming docker is already logged in to ghcr.io"
fi

BUILD_ARGS=(
  --platform "${PLATFORMS}"
  --build-arg "REPO_URL=https://github.com/${REPO_PATH}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
  --build-arg "INSTALL_OLLAMA=${INSTALL_OLLAMA_VALUE}"
  --build-arg "INSTALL_TRANSFORMERS=${INSTALL_TRANSFORMERS_VALUE}"
  --build-arg "PIP_INDEX_URL=${PIP_INDEX_URL_VALUE}"
  --build-arg "TORCH_INDEX_URL=${TORCH_INDEX_URL_VALUE}"
  --build-arg "TORCH_VERSION=${TORCH_VERSION_VALUE}"
  -t "${IMAGE_REPO}:${IMAGE_TAG}"
)

if [[ -n "${PIP_EXTRA_INDEX_URL_VALUE}" ]]; then
  BUILD_ARGS+=( --build-arg "PIP_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL_VALUE}" )
fi

if [[ -n "${HTTP_PROXY:-}" ]]; then
  BUILD_ARGS+=( --build-arg "HTTP_PROXY=${HTTP_PROXY}" --build-arg "http_proxy=${HTTP_PROXY}" )
fi

if [[ -n "${HTTPS_PROXY:-}" ]]; then
  BUILD_ARGS+=( --build-arg "HTTPS_PROXY=${HTTPS_PROXY}" --build-arg "https_proxy=${HTTPS_PROXY}" )
fi

if [[ -n "${NO_PROXY:-}" ]]; then
  BUILD_ARGS+=( --build-arg "NO_PROXY=${NO_PROXY}" --build-arg "no_proxy=${NO_PROXY}" )
fi

if [[ -n "${BUILDER_NAME}" ]]; then
  BUILD_ARGS=( --builder "${BUILDER_NAME}" "${BUILD_ARGS[@]}" )
fi

if [[ "${PUBLISH_LATEST}" == "1" ]]; then
  BUILD_ARGS+=( -t "${IMAGE_REPO}:latest" )
fi

log "building ${IMAGE_REPO}:${IMAGE_TAG} for ${PLATFORMS}"
if [[ "${INSTALL_OLLAMA_VALUE}" != "1" ]]; then
  log "INSTALL_OLLAMA=${INSTALL_OLLAMA_VALUE}, skipping ollama binary in this image"
fi
if [[ "${INSTALL_TRANSFORMERS_VALUE}" != "1" ]]; then
  log "INSTALL_TRANSFORMERS=${INSTALL_TRANSFORMERS_VALUE}, skipping transformers runtime in this image"
fi

if [[ "${PUSH}" == "1" ]]; then
  docker buildx build "${BUILD_ARGS[@]}" --push "${REPO_ROOT}"
  log "published ${IMAGE_REPO}:${IMAGE_TAG}"
  if [[ "${PUBLISH_LATEST}" == "1" ]]; then
    log "published ${IMAGE_REPO}:latest"
  fi
else
  if [[ "${PLATFORMS}" == *","* ]]; then
    die "PUSH=0 only supports a single platform because docker buildx --load cannot load multi-platform images"
  fi

  docker buildx build "${BUILD_ARGS[@]}" --load "${REPO_ROOT}"
  log "loaded ${IMAGE_REPO}:${IMAGE_TAG} into the local docker daemon"
fi