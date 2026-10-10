# LMM-API

大模型 API 网关的 AMD64 Docker 镜像。基于开源项目
[MIXAPI](https://github.com/aiprodcoder/MIXAPI)（Apache-2.0）构建。

把国内外主流大模型（OpenAI、Claude、Gemini、通义千问、Kimi、
豆包等）统一转换成 **OpenAI 兼容接口 / Claude 接口 / Gemini 接口**，
适合个人或企业内部做 API 统一管理与渠道路由分发。

---

## 快速开始

```bash
docker compose up -d
```

启动后访问 <http://localhost:3000>，首次进入需要注册管理员账号。

查看日志：

```bash
docker compose logs -f
```

---

## 镜像说明

| 项 | 值 |
|----|-----|
| 基础镜像 | `alpine:3.20` |
| 架构 | **仅 AMD64**（x86_64） |
| 上游版本 | MIXAPI `v2.5.1cl` |
| 暴露端口 | `3000` |
| 数据目录 | `/data`（数据库与日志） |
| 时区 | `Asia/Shanghai` |

镜像由官方发布的预编译二进制打包而成，**不包含源码**，
体积小、启动快。

---

## 两个 Dockerfile 的区别

本仓库提供两份构建文件，按需选用：

### `Dockerfile`（默认，推荐）

下载官方 GitHub Release 的已编译 AMD64 二进制并打包。

```bash
docker build --platform linux/amd64 -t lmm-api:2.5.1cl .
```

构建快（约 1 分钟），产物稳定可用。

### `Dockerfile.build`（从源码完整编译）

多阶段构建：先用 `bun` 编译 React 前端，再用 `golang:1.24` 编译
Go 后端并把前端嵌入，最后打包成精简运行镜像。

```bash
# 需要先把上游源码克隆到当前目录
git clone --depth 1 https://github.com/aiprodcoder/MIXAPI.git src
# 然后以 src 为构建上下文
docker build -f Dockerfile.build --platform linux/amd64 -t lmm-api:build ./src
```

构建慢（前端编译耗时较长，建议给 Docker 至少 4GB 内存），
适合需要自行改动源码的场景。

---

## 版本选择

上游最新版本为 `v2.5.1cl`（2025-11-02 发布）。

> ⚠️ 上游仓库自带的 `Dockerfile` 停留在 `v1.2`，而该 release 现已
> 不存在，直接使用会构建失败。本仓库已更新到当前可用版本。

切换版本只需改构建参数：

```bash
docker build --platform linux/amd64 \
  --build-arg MIXAPI_VERSION=v2.5.1cl \
  -t lmm-api:2.5.1cl .
```

可用的历史版本可通过以下命令查询：

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

**Q：构建时下载二进制失败？**
构建阶段需要能访问 GitHub Release。若网络受限，可先手动下载
`mixapi-v2.5.1cl-linux-amd64`，改用 `Dockerfile.build` 走源码编译，
或在能联网的机器上构建好镜像再 `docker save` / `docker load` 迁移。

**Q：在 ARM 设备（如 M 系列 Mac、部分 NAS）上能跑吗？**
不能直接用，本镜像只含 AMD64 二进制。ARM 需自行改用
`mixapi-v2.5.1cl-linux-arm64` 构建，或在上游仓库修改架构分支。

---

## 许可

本项目仅为上游 MIXAPI 的镜像封装与构建配置。
上游以 **Apache-2.0** 许可发布，本仓库同样遵循该许可。
