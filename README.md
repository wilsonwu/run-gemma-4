# Gemma 4 On Kubernetes (CPU)

这套目录提供一条偏工程化的 CPU 部署路径，目标是在 Kubernetes 中运行 Gemma 4 文本推理服务，而不是只给一个单独的 Deployment。

默认推荐路径是：

- `llama.cpp` + GGUF 量化模型，适合 CPU。
- `transformers` 运行时保留给需要直接加载 Hugging Face 权重的场景。
- `ollama` 运行时作为第三种可选封装，适合已经在用 Ollama 模型分发方式的场景。

## 目录说明

- `Dockerfile`：统一镜像，内置 `llama-server`、`ollama`、Python/Transformers 服务。
- `docker/entrypoint.sh`：运行时选择与服务启动逻辑。
- `docker/prepare-model.sh`：初始化阶段拉取模型到 PVC。
- `app/transformers_server.py`：CPU 下的 OpenAI 风格兼容接口。
- `k8s/base`：基础命名空间、PVC、ConfigMap、Deployment、Service。
- `k8s/overlays/*`：不同运行时的覆盖配置。

## 现实约束

Gemma 4 在 CPU 上能否“跑起来”和“能否实用”不是一回事。

- 如果你要的是可落地的 CPU 部署，优先用 GGUF 量化模型并选择 `llama.cpp`。
- 如果你直接加载 Hugging Face 原始权重，内存压力和延迟都会明显更高。
- 如果模型是 gated repo，需要在 Secret 里提供 `HF_TOKEN`。
- 这套方案面向文本推理；如果你要多模态能力，需要额外补齐图像处理链路。

## 构建镜像

```bash
docker build -t ghcr.io/your-org/gemma-4-cpu:0.1.0 .
docker push ghcr.io/your-org/gemma-4-cpu:0.1.0
```

然后把镜像地址替换到 `k8s/base/deployment.yaml`。

## 运行时选择

通过 `MODEL_RUNTIME` 选择运行时：

- `auto`：按配置自动判断。优先识别 GGUF，其次识别 Ollama，最后回退到 Transformers。
- `llama.cpp`：使用 `llama-server`，推荐 CPU。
- `transformers`：使用 `FastAPI + Transformers`。
- `ollama`：使用 `ollama serve`。

推荐 overlay：

- `k8s/overlays/llama-cpp`：CPU 默认路径。
- `k8s/overlays/transformers`：HF 原始权重路径。
- `k8s/overlays/ollama`：Ollama 路径。

## 模型准备方式

容器里有一个 initContainer，会把模型预拉到 PVC。

### llama.cpp

需要配置：

- `MODEL_RUNTIME=llama.cpp`
- `MODEL_PATH=/models/gemma-4.gguf`
- `MODEL_URL=https://.../gemma-4-q4.gguf`

### transformers

需要配置：

- `MODEL_RUNTIME=transformers`
- `MODEL_PATH=/models/hf-model`
- `HF_MODEL_ID=your-hf-namespace/gemma-4-model`
- `HF_TOKEN`：如果模型仓库受限

### ollama

需要配置：

- `MODEL_RUNTIME=ollama`
- `OLLAMA_MODEL=gemma4:latest`

## 部署

### 1. 准备 Secret

如果你需要访问受限的 Hugging Face 模型，先把 `k8s/base/secret.example.yaml` 里的占位 token 改成真实值，再创建 Secret：

```bash
kubectl apply -f k8s/base/secret.example.yaml
```

### 2. 选择运行时并部署

CPU 推荐：

```bash
kubectl apply -k k8s/overlays/llama-cpp
```

如果你确定要直接跑 HF 权重：

```bash
kubectl apply -k k8s/overlays/transformers
```

如果你已经用 Ollama 管理模型：

```bash
kubectl apply -k k8s/overlays/ollama
```

## 访问方式

```bash
kubectl -n gemma-cpu port-forward svc/gemma-inference 8080:80
```

### OpenAI 风格请求

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "用一句话解释 Kubernetes Service。"}
    ],
    "max_tokens": 128,
    "temperature": 0.2
  }'
```

## 建议的 CPU 资源起点

- `llama.cpp` + 量化模型：从 `8 vCPU / 24 GiB RAM` 起步。
- `transformers` + 原始权重：建议至少 `16 vCPU / 64 GiB RAM`，否则很容易不可用。
- 如果你跑的是更大参数量版本，资源要继续上调。

## 你需要替换的占位配置

- `k8s/base/deployment.yaml` 里的镜像地址。
- 对应 overlay 里的 `MODEL_URL`、`HF_MODEL_ID` 或 `OLLAMA_MODEL`。
- PVC 容量和 CPU/内存限制。

## 说明

这套配置已经把以下逻辑补齐：

- 镜像构建
- 模型预拉取
- 运行时选择
- CPU 友好的默认路径
- Kubernetes 基础资源
- OpenAI 风格接口暴露

如果你的目标是“尽量省资源地在 CPU 上跑 Gemma 4”，先从 `llama.cpp overlay + GGUF Q4/Q5` 开始，不要直接走 Transformers。
