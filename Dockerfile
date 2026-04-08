FROM debian:bookworm-slim AS llama-builder

ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_CPP_REF=master

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates cmake git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth=1 --branch "${LLAMA_CPP_REF}" "${LLAMA_CPP_REPO}" .
RUN cmake -S . -B build -DGGML_NATIVE=OFF -DGGML_OPENMP=ON -DLLAMA_BUILD_SERVER=ON -DBUILD_SHARED_LIBS=OFF
RUN cmake --build build --config Release --target llama-server -j "$(nproc)"

FROM python:3.11-slim-bookworm

ARG OLLAMA_INSTALL_URL=https://ollama.com/install.sh
ARG INSTALL_OLLAMA=1
ARG INSTALL_TRANSFORMERS=1
ARG REPO_URL=https://github.com/wilsonwu/run-gemma-4
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_VERSION=dev
ARG PIP_INDEX_URL=https://pypi.org/simple
ARG PIP_EXTRA_INDEX_URL=
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu
ARG TORCH_VERSION=2.6.0+cpu

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    SERVICE_PORT=8080 \
    MODEL_RUNTIME=auto \
    MODEL_PATH=/models/model.gguf \
    OLLAMA_MODELS=/models/ollama \
    HF_HOME=/models/.cache/huggingface \
    TRANSFORMERS_CACHE=/models/.cache/huggingface

LABEL org.opencontainers.image.source="${REPO_URL}" \
            org.opencontainers.image.url="${REPO_URL}" \
            org.opencontainers.image.revision="${VCS_REF}" \
            org.opencontainers.image.created="${BUILD_DATE}" \
            org.opencontainers.image.version="${IMAGE_VERSION}" \
            org.opencontainers.image.title="run-gemma-4" \
            org.opencontainers.image.description="CPU-oriented Gemma 4 runtime image for Kubernetes"

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl libgomp1 tini zstd \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 appuser \
    && useradd --system --uid 10001 --gid appuser --create-home --home-dir /home/appuser appuser

WORKDIR /app

COPY app/requirements.txt /app/requirements.txt

RUN if [ "${INSTALL_TRANSFORMERS}" = "1" ]; then \
            pip install --upgrade pip \
            && pip config set global.index-url "${PIP_INDEX_URL}" \
            && if [ -n "${PIP_EXTRA_INDEX_URL}" ]; then pip config set global.extra-index-url "${PIP_EXTRA_INDEX_URL}"; fi \
            && pip install --index-url "${TORCH_INDEX_URL}" "torch==${TORCH_VERSION}" \
            && pip install -r /app/requirements.txt; \
        fi

RUN if [ "${INSTALL_OLLAMA}" = "1" ]; then curl -fsSL "${OLLAMA_INSTALL_URL}" | sh; fi

COPY --from=llama-builder /src/build/bin/llama-server /usr/local/bin/llama-server
COPY --chown=10001:10001 app/transformers_server.py /app/transformers_server.py
COPY --chown=10001:10001 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=10001:10001 docker/prepare-model.sh /usr/local/bin/prepare-model.sh

RUN mkdir -p /models /tmp/ollama \
    && chown -R 10001:10001 /app /models /tmp/ollama \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/prepare-model.sh

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
