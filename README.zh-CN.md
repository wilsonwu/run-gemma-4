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
- 可配置的模型下载地址与代理参数

## 默认运行时

默认发布镜像聚焦在最实用的路径：

- 运行时：`llama.cpp`
- 模型格式：`GGUF`
- 默认模型源：ModelScope
- 默认模型文件：`gemma-4-E2B-it-Q4_K_M.gguf`

仓库现在刻意只保留这一条运行路径，不再维护 `transformers` 或 `ollama` 的旁支逻辑。

## 网络注意事项

这个项目里，镜像拉取和模型下载是故意分开的两件事：

- 容器镜像来源：`ghcr.io/wilsonwu/run-gemma-4`
- 模型文件来源：你在 `MODEL_URL` 里指定的地址

对于中国大陆用户：

- 默认 `MODEL_URL` 已经指向 ModelScope，因为它通常比 global 模型站更容易访问，也更稳定。
- 但 GHCR 在部分中国网络环境下仍然可能偏慢或不稳定。Compose 场景下，可以在 `.env` 里改 `IMAGE_REPO`；Kubernetes 场景下，可以直接把 [k8s/deployment.yaml](k8s/deployment.yaml) 里两个镜像地址改成你自己的镜像仓库或区域镜像。
- 如果你仍然要直接使用 GHCR，建议按实际网络环境设置 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`。

对于 global 用户：

- 直接从 GHCR 拉镜像通常就是最简单的路径。
- 如果 ModelScope 在你所在区域不是最快的模型源，可以在 `.env` 或 [k8s/configmap.yaml](k8s/configmap.yaml) 里把 `MODEL_URL` 改成离你更近的 GGUF 下载地址。
- 镜像来源和模型来源可以自由组合。比如镜像继续用 GHCR，但模型改成别的对象存储或公开下载源。

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
- `.env.example` 里保留了运行时代理参数
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
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`：代理设置

当前默认策略：

- GGUF 直链：ModelScope

这样拆分的原因很直接：

- 单个 GGUF 文件是这个仓库里最简单、最稳定的分发形式
- 直接改 `MODEL_URL` 就可以切换到任意镜像站、对象存储或者公司内部制品地址，而不需要改代码

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
- `platforms`

另外，这些参数在 [.github/workflows/build-image.yml](.github/workflows/build-image.yml) 顶部也保留了可编辑默认值。这样 `main` / tag 的自动构建保持简单，同时又保留了代理和目标平台的可配置能力。

如果 `Build and push image` 这一步在登录成功后仍然报 GHCR `403 Forbidden`，通常说明“认证成功了，但当前 token 没有写入这个已有 package 的权限”。这在镜像最初是通过本地 PAT 手工 push 创建、而不是由当前仓库的 GitHub Actions 首次创建时很常见。

第一优先应该先检查 GitHub 上这个 package 的权限关系：

- 打开 `ghcr.io/wilsonwu/run-gemma-4` 对应 package 的设置页
- 确认当前仓库已经被加入这个 package 的 Actions 访问范围
- 如果这个 package 不是由当前仓库工作流首次创建的，就需要在 package 设置里重新关联或显式授权

建议做法：

- 配置仓库 secret `GHCR_TOKEN`：使用 classic PAT，至少包含 `write:packages` 和 `read:packages`
- 配置仓库 secret `GHCR_USERNAME`：填写这个 token 所属的 GitHub 用户名

当前工作流已经绑定到 GitHub Environment `run-gemma-4`。如果这个 environment 里存在 `GHCR_TOKEN`，登录步骤会自动优先使用这个 PAT；如果没有，才会回退到内置 `GITHUB_TOKEN`。

如果这个 PAT 就属于仓库 owner 账号，那现在不需要额外配置 `GHCR_USERNAME`。只有你后面想进一步自定义登录逻辑时，才需要再加它。

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
