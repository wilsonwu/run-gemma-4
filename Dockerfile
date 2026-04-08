FROM debian:bookworm-slim AS llama-builder

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_CPP_REF=master

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates cmake git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth=1 --branch "${LLAMA_CPP_REF}" "${LLAMA_CPP_REPO}" .
RUN cmake -S . -B build -DGGML_NATIVE=OFF -DGGML_OPENMP=ON -DLLAMA_BUILD_SERVER=ON -DBUILD_SHARED_LIBS=OFF
RUN cmake --build build --config Release --target llama-server -j "$(nproc)"

FROM debian:bookworm-slim

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG REPO_URL=https://github.com/wilsonwu/run-gemma-4
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_VERSION=dev

ENV SERVICE_PORT=8080 \
    MODEL_PATH=/models/gemma-4-E2B-it-Q4_K_M.gguf

LABEL org.opencontainers.image.source="${REPO_URL}" \
            org.opencontainers.image.url="${REPO_URL}" \
            org.opencontainers.image.revision="${VCS_REF}" \
            org.opencontainers.image.created="${BUILD_DATE}" \
            org.opencontainers.image.version="${IMAGE_VERSION}" \
            org.opencontainers.image.title="run-gemma-4" \
            org.opencontainers.image.description="CPU-oriented Gemma 4 runtime image for Kubernetes"

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl libgomp1 libstdc++6 tini \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 appuser \
    && useradd --system --uid 10001 --gid appuser --create-home --home-dir /home/appuser appuser

COPY --from=llama-builder /src/build/bin/llama-server /usr/local/bin/llama-server
COPY --chown=10001:10001 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=10001:10001 docker/prepare-model.sh /usr/local/bin/prepare-model.sh

RUN mkdir -p /models /tmp \
    && chown -R 10001:10001 /models /tmp \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/prepare-model.sh

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
