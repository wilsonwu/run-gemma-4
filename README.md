# Run Gemma 4 Anywhere

[中文说明](README.zh-CN.md)

This repository packages one practical Gemma 4 inference path that users can start from either Docker Compose or Kubernetes.

The default experience is CPU-first and uses `llama.cpp + GGUF`, because that is the most realistic way to offer a one-command inference setup across laptops, Docker hosts, and Kubernetes clusters.

## What Users Get

- A published image on GHCR.
- A ready-to-run `compose.yaml` for local validation.
- A ready-to-run standard Kubernetes manifest set.
- Resumable model downloads with SHA256 verification.
- Configurable model source URLs, Hugging Face mirror endpoints, and proxy variables.

## Default Runtime

The default published image is intentionally focused on the practical path:

- Runtime: `llama.cpp`
- Model format: `GGUF`
- Default model source: ModelScope
- Default model file: `gemma-4-E2B-it-Q4_K_M.gguf`

`transformers` and `ollama` remain available as advanced build options, but they are not enabled in the default image published from `main` and release tags.

## Docker Compose Quick Start

1. Copy `.env.example` to `.env`.
2. Review `MODEL_URL`, `MODEL_SHA256`, and `IMAGE_TAG`.
3. Start the stack:

```bash
docker compose up -d
```

1. Watch the model preparation phase if this is the first run:

```bash
docker compose logs -f prepare-model
```

1. Send a smoke test request:

```bash
curl http://127.0.0.1:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Please answer in one short sentence. What is Kubernetes Service?\nAnswer:",
    "n_predict": 96,
    "temperature": 0.1,
    "stop": ["\n\n"]
  }'
```

Notes:

- Compose defaults to `ghcr.io/wilsonwu/run-gemma-4:latest`.
- The compose file bind-mounts the local `docker/entrypoint.sh` and `docker/prepare-model.sh`, so local script updates take effect immediately.
- Host-side proxy variables and in-container proxy variables are both supported through `.env.example`.
- If a model download is interrupted, restarting Compose will resume the download.
- If a downloaded GGUF file is corrupt, it will be deleted and downloaded again automatically.

## Kubernetes Quick Start

The Kubernetes entry point is [k8s](k8s).

1. Review and edit [k8s/configmap.yaml](k8s/configmap.yaml).
2. Create the namespace first:

```bash
kubectl apply -f k8s/namespace.yaml
```

1. If your GHCR package is private, create an image pull secret and uncomment the `imagePullSecrets` block in [k8s/deployment.yaml](k8s/deployment.yaml):

```bash
kubectl -n gemma-cpu create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GHCR_TOKEN
```

1. If you need a gated Hugging Face model later, create the optional secret used by the Deployment:

```bash
kubectl -n gemma-cpu create secret generic model-access \
  --from-literal=HF_TOKEN=YOUR_HF_TOKEN
```

1. If you want to pin a release image, replace `ghcr.io/wilsonwu/run-gemma-4:latest` in both image fields in [k8s/deployment.yaml](k8s/deployment.yaml).

1. Apply the manifests:

```bash
kubectl apply -f k8s/
```

1. Forward the service locally:

```bash
kubectl -n gemma-cpu port-forward svc/gemma-inference 8080:80
```

1. Send the same smoke test request:

```bash
curl http://127.0.0.1:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Please answer in one short sentence. What is Kubernetes Service?\nAnswer:",
    "n_predict": 96,
    "temperature": 0.1,
    "stop": ["\n\n"]
  }'
```

Notes:

- The standard Kubernetes path no longer depends on Kustomize.
- All namespaced resources now explicitly target `gemma-cpu`, so the YAMLs can be applied directly.

## Model Source Strategy

The project is designed so users can point model preparation to different download sources depending on network conditions.

Recommended knobs:

- `MODEL_URL`: direct GGUF file URL for `llama.cpp`
- `MODEL_SHA256`: optional but recommended integrity check
- `HF_ENDPOINT`: mirror endpoint for Hugging Face based downloads
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`: host or cluster level proxy settings

Current defaults:

- GGUF direct download: ModelScope
- Hugging Face mirror endpoint: `https://hf-mirror.com`

This split exists for a reason:

- direct GGUF files are usually fastest from a China-friendly object store or model hub URL
- Hugging Face repos are often more reliable through a mirror endpoint than through the global host

## Image Publishing

Image builds are handled by GitHub Actions in [.github/workflows/build-image.yml](.github/workflows/build-image.yml).

Publishing rules:

- Push to `main`: publish `ghcr.io/wilsonwu/run-gemma-4:latest`
- Push to `main`: publish `ghcr.io/wilsonwu/run-gemma-4:sha-<short-sha>`
- Push a Git tag such as `v0.2.0`: publish `ghcr.io/wilsonwu/run-gemma-4:v0.2.0`

Optional `workflow_dispatch` parameters:

- `http_proxy`
- `https_proxy`
- `no_proxy`
- `pip_index_url`
- `pip_extra_index_url`
- `torch_index_url`
- `torch_version`
- `platforms`
- `install_transformers`
- `install_ollama`

The workflow keeps editable defaults near the top of [.github/workflows/build-image.yml](.github/workflows/build-image.yml), so automatic `main` and tag builds stay simple while proxy and package source overrides remain available.

Use GitHub Actions as the default publishing path. The fallback script [docker/publish-ghcr.sh](docker/publish-ghcr.sh) is still available for local publishing and accepts the same categories of parameters through environment variables.

## Repository Layout

- [Dockerfile](Dockerfile): container image definition
- [compose.yaml](compose.yaml): local one-command entry point
- [.env.example](.env.example): Compose environment template
- [docker/prepare-model.sh](docker/prepare-model.sh): model download logic with resume and checksum verification
- [docker/entrypoint.sh](docker/entrypoint.sh): runtime dispatch logic
- [k8s](k8s): standard Kubernetes manifests
- [.github/workflows/build-image.yml](.github/workflows/build-image.yml): CI image publishing workflow

## License

See [LICENSE](LICENSE).
