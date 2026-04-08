# Run Gemma 4 Anywhere

[English README](README.md)

这个仓库面向最终用户提供一套可直接运行 Gemma 4 推理的工程化方案，支持两种入口：

- Docker Compose 本地启动
- Kubernetes 一键部署

默认路径是 CPU 优先的 `llama.cpp + GGUF`，因为这是在笔记本、Docker 主机和 Kubernetes 集群之间最容易统一、也最容易真正跑起来的方案。

## 用户最终得到什么

- 一份已经发布到 GHCR 的镜像
- 一份可直接运行的 `compose.yaml`
- 一份可直接应用的标准 Kubernetes YAML 资源
- 支持断点续传和 SHA256 校验的模型下载逻辑
- 可配置的模型下载地址、Hugging Face 镜像地址与代理参数

## 默认运行时

默认发布镜像聚焦在最实用的路径：

- 运行时：`llama.cpp`
- 模型格式：`GGUF`
- 默认模型源：ModelScope
- 默认模型文件：`gemma-4-E2B-it-Q4_K_M.gguf`

`transformers` 和 `ollama` 仍然保留为高级用法，但默认 CI 发布的镜像不会启用它们。

## Docker Compose 一键启动

1. 复制 `.env.example` 为 `.env`
2. 检查 `MODEL_URL`、`MODEL_SHA256`、`IMAGE_TAG`
3. 启动：

```bash
docker compose up -d
```

1. 第一次启动时可以观察模型下载进度：

```bash
docker compose logs -f prepare-model
```

1. 发一个最小验证请求：

```bash
curl http://127.0.0.1:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "请只用一句中文回答。什么是 Kubernetes Service？\n回答：",
    "n_predict": 96,
    "temperature": 0.1,
    "stop": ["\n\n"]
  }'
```

说明：

- Compose 默认使用 `ghcr.io/wilsonwu/run-gemma-4:latest`
- Compose 会把本地的 `docker/entrypoint.sh` 和 `docker/prepare-model.sh` bind mount 进容器，所以你本地修改脚本后不必重建镜像
- `.env.example` 同时保留了主机侧代理和容器内代理参数
- 模型下载中断后，重新执行 `docker compose up` 会继续下载
- 如果 GGUF 文件损坏，脚本会自动删除并重新下载

## Kubernetes 一键部署

Kubernetes 唯一入口现在就是 [k8s](k8s)。

1. 检查并编辑 [k8s/configmap.yaml](k8s/configmap.yaml)
2. 先创建命名空间：

```bash
kubectl apply -f k8s/namespace.yaml
```

1. 如果你的 GHCR 包是私有的，先创建镜像拉取凭证，并取消 [k8s/deployment.yaml](k8s/deployment.yaml) 里 `imagePullSecrets` 注释：

```bash
kubectl -n gemma-cpu create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GHCR_TOKEN
```

1. 如果后续切换到需要 Hugging Face Token 的受限模型，再创建可选 Secret：

```bash
kubectl -n gemma-cpu create secret generic model-access \
  --from-literal=HF_TOKEN=YOUR_HF_TOKEN
```

1. 如果你要固定某个 release 镜像版本，把 [k8s/deployment.yaml](k8s/deployment.yaml) 里两个 `ghcr.io/wilsonwu/run-gemma-4:latest` 改成目标 tag。

1. 部署：

```bash
kubectl apply -f k8s/
```

1. 转发服务：

```bash
kubectl -n gemma-cpu port-forward svc/gemma-inference 8080:80
```

1. 发送同样的验证请求：

```bash
curl http://127.0.0.1:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "请只用一句中文回答。什么是 Kubernetes Service？\n回答：",
    "n_predict": 96,
    "temperature": 0.1,
    "stop": ["\n\n"]
  }'
```

说明：

- 这条 Kubernetes 路径已经不再依赖 Kustomize。
- 所有带命名空间的资源都已经显式写成 `gemma-cpu`，可以直接按标准 YAML 使用。

## 模型下载策略

这个项目专门按“不同网络环境”设计了模型准备参数。

核心参数：

- `MODEL_URL`：`llama.cpp` 路径下直接指定 GGUF 文件地址
- `MODEL_SHA256`：可选但强烈建议填写，用于完整性校验
- `HF_ENDPOINT`：Hugging Face 镜像地址
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`：代理设置

当前默认策略：

- GGUF 直链：ModelScope
- Hugging Face 镜像：`https://hf-mirror.com`

这样拆分的原因很直接：

- 单个 GGUF 文件通常更适合走国内对象存储或国内模型站直链
- Hugging Face 仓库结构下载通常更适合走镜像站而不是全球源站

## 镜像构建与发布

镜像发布由 GitHub Actions 驱动，工作流位于 [.github/workflows/build-image.yml](.github/workflows/build-image.yml)。

发布规则：

- 提交到 `main`：发布 `ghcr.io/wilsonwu/run-gemma-4:latest`
- 提交到 `main`：同时发布 `ghcr.io/wilsonwu/run-gemma-4:sha-<short-sha>`
- 打 Git Tag，例如 `v0.2.0`：发布 `ghcr.io/wilsonwu/run-gemma-4:v0.2.0`

工作流在 `workflow_dispatch` 下支持的可选参数：

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

另外，这些参数在 [.github/workflows/build-image.yml](.github/workflows/build-image.yml) 顶部也保留了可编辑默认值。这样 `main` / tag 的自动构建保持简单，同时又保留了代理、包源和构建开关的可配置能力。

GitHub Actions 应该是默认的镜像发布路径。本地脚本 [docker/publish-ghcr.sh](docker/publish-ghcr.sh) 仍然保留，但只是可选辅助工具，参数也改成了基于环境变量显式传入，不再依赖自动探测本地代理。

## 仓库结构

- [Dockerfile](Dockerfile)：镜像定义
- [compose.yaml](compose.yaml)：本地一键入口
- [.env.example](.env.example)：Compose 环境变量模板
- [docker/prepare-model.sh](docker/prepare-model.sh)：支持断点续传和校验的模型下载脚本
- [docker/entrypoint.sh](docker/entrypoint.sh)：运行时分发入口
- [k8s](k8s)：标准 Kubernetes YAML 资源
- [.github/workflows/build-image.yml](.github/workflows/build-image.yml)：CI 镜像发布流程

## License

见 [LICENSE](LICENSE)。
