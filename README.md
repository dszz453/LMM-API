# LMM-API

大模型 API 网关的 **AMD64 Docker 镜像**。基于开源项目
[MIXAPI](https://github.com/aiprodcoder/MIXAPI)（Apache-2.0）构建。

把国内外主流大模型（OpenAI、Claude、Gemini、通义千问、Kimi、
豆包等）统一转换成 **OpenAI 兼容接口 / Claude 接口 / Gemini 接口**，
适合个人或企业内部做 API 统一管理、Key 管理与渠道分发。

---

## 快速开始

```bash
docker compose up -d
```

访问 <http://localhost:3000>，首次进入需注册管理员账号。

查看日志：

```bash
docker compose logs -f
```

或使用一键脚本（自动检查端口、构建、启动、健康检查）：

```bash
bash deploy.sh
```

---

## 镜像说明

| 项 | 值 |
|----|-----|
| 基础镜像 | `alpine:3.20` |
| 架构 | **仅 AMD64**（x86_64） |
| 上游版本 | MIXAPI `v2.5.1cl` |
| 镜像体积 | 85.2 MB |
| 暴露端口 | `3000` |
| 数据目录 | `/data`（数据库与日志） |
| 时区 | `Asia/Shanghai` |

镜像由官方发布的预编译二进制打包而成，**不包含源码**，体积小、启动快。

---

## 三种构建方式

按你的网络环境选用。

### `Dockerfile`（默认）

构建时从 GitHub Release 下载官方已编译的 AMD64 二进制并打包。

```bash
docker build --platform linux/amd64 -t lmm-api:2.5.1cl .
```

> ⚠️ **国内网络注意**：实测从 GitHub CDN 下载 70MB 二进制只有
> **20~40 KB/s**，整个构建要十几分钟。若你在这里，请用下面的
> `Dockerfile.offline`。

### `Dockerfile.offline`（国内环境推荐）

先在能联网的机器下好二进制，再 COPY 进镜像，**构建只需几十秒**。

```bash
# 1) 下载二进制
bash scripts/fetch-binary.sh v2.5.1cl

# 2) 构建
docker build -f Dockerfile.offline -t lmm-api:2.5.1cl .
```

实测对比（同一台服务器）：

| 方式 | 二进制获取 | 构建耗时 |
|------|-----------|---------|
| `Dockerfile` | 走 GitHub CDN，约 15 分钟 | 总耗时约 15 分钟 |
| `Dockerfile.offline` | SSH 直传 70MB，**10 秒** | **25 秒** |

### `Dockerfile.build`（从源码完整编译）

多阶段构建：`bun` 编译 React 前端 → `golang:1.24` 编译 Go 后端
并把前端嵌入 → 打包成精简运行镜像。

```bash
git clone --depth 1 https://github.com/aiprodcoder/MIXAPI.git src
docker build -f Dockerfile.build --platform linux/amd64 -t lmm-api:build ./src
```

耗时最长（前端编译慢，建议给 Docker 至少 4GB 内存），
适合需要自行改动源码的场景。

---

## 镜像验证记录

已在 x86_64 环境实际构建并运行验证：

| 检查项 | 结果 |
|--------|------|
| 二进制架构 | `ELF 64-bit, e_machine=62` → AMD64 ✓ |
| 镜像架构 | `docker inspect` → `amd64/linux` ✓ |
| 镜像体积 | 85.2 MB |
| 容器状态 | `Up (healthy)` |
| 启动耗时 | 约 4.8 秒 |
| Web 前端 | 已嵌入，`/` 返回 HTML 200 ✓ |
| 状态接口 | `/api/status` 返回 200，数据库初始化正常 ✓ |

二进制 SHA256（`v2.5.1cl` amd64）：
`cbc88a50d82349ef98405e0aec3ce9d5a33afc6cd42dac7e9c4b49b4e05e2775`

---

## 版本说明

当前使用上游 **`v2.5.1cl`**（2025-11-02 发布）。

> ⚠️ 上游仓库自带的 `Dockerfile` 停留在 `v1.2`，而该 release 现已不存在，
> 直接使用上游 Dockerfile 构建会失败。本仓库已更新到可用版本。

切换版本：

```bash
docker build --platform linux/amd64 \
  --build-arg MIXAPI_VERSION=v2.5.1cl \
  -t lmm-api:2.5.1cl .
```

查询可用版本：

```bash
curl -s https://api.github.com/repos/aiprodcoder/MIXAPI/releases \
  | grep '"tag_name"'
```

---

## 数据持久化

`docker-compose.yml` 已把 `/data` 挂载到宿主机 `./data`，
数据库（默认 SQLite）和日志都在里面。**升级镜像时不要删除这个目录**。

如需改用 MySQL / PostgreSQL，通过 `SQL_DSN` 环境变量指定：

```yaml
environment:
  SQL_DSN: "root:password@tcp(mysql:3306)/lmm-api"
```

---

## 常见问题

**Q：端口 3000 被占用？**
改 `docker-compose.yml` 里 `ports` 冒号左边的值，如 `"3300:3000"`。

**Q：构建时下载二进制极慢或失败？**
用 `Dockerfile.offline`。先 `bash scripts/fetch-binary.sh` 在别处下好
二进制，再构建即可。若目标机器完全无法访问 GitHub，可在能联网的
机器上构建好镜像再迁移：

```bash
docker save lmm-api:2.5.1cl | gzip > lmm-api.tar.gz
# 传到目标机器后
gunzip -c lmm-api.tar.gz | docker load
```

**Q：在 ARM 设备上能跑吗？**
不能。本镜像只含 AMD64 二进制。ARM 需自行改用
`mixapi-v2.5.1cl-linux-arm64` 构建（`fetch-binary.sh` 支持第二参数
指定架构）。

**Q：初始管理员怎么创建？**
首次访问 Web 界面时按提示注册，第一个注册的账号即为管理员。

---

## 目录结构

```
LMM-API/
├── Dockerfile              # 联网构建（下载官方二进制）
├── Dockerfile.offline      # 离线构建（本地 COPY 二进制）
├── Dockerfile.build        # 从源码完整编译
├── docker-compose.yml
├── deploy.sh               # 一键部署脚本
├── scripts/
│   └── fetch-binary.sh     # 下载二进制并校验架构
└── README.md
```

---

## 许可

本项目仅为上游 MIXAPI 的镜像封装与构建配置。
上游以 **Apache-2.0** 许可发布，本仓库同样遵循该许可。
