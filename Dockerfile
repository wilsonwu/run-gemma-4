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

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    SERVICE_PORT=8080 \
    MODEL_RUNTIME=auto \
    MODEL_PATH=/models/model.gguf \
    OLLAMA_MODELS=/models/ollama \
    HF_HOME=/models/.cache/huggingface \
    TRANSFORMERS_CACHE=/models/.cache/huggingface

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl libgomp1 tini \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 appuser \
    && useradd --system --uid 10001 --gid appuser --create-home --home-dir /home/appuser appuser

WORKDIR /app

COPY app/requirements.txt /app/requirements.txt

RUN pip install --upgrade pip \
    && pip install -r /app/requirements.txt

RUN curl -fsSL "${OLLAMA_INSTALL_URL}" | sh

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
