# LMM-API

大模型 API 网关的 **AMD64 Docker 镜像**。基于开源项目
[MIXAPI](https://github.com/aiprodcoder/MIXAPI)（Apache-2.0）构建。

把国内外主流大模型（OpenAI、Claude、Gemini、通义千问、Kimi、
豆包等）统一转换成 **OpenAI 兼容接口 / Claude 接口 / Gemini 接口**，
适合个人或企业内部做 API 统一管理、Key 管理与渠道分发。

---

## 一键部署

```bash
cp .env.example .env
vi .env                 # 填上你的管理员密码和访问地址
docker compose up -d
```

**就这样，不需要其他操作。** 容器启动时会自动读取 `.env` 里的配置，
完成「创建管理员 → 修正访问地址」，直接打开网页就能登录。

`.env` 内容示例：

```env
INIT_ROOT_USER=root
INIT_ROOT_PASSWORD=你的密码（至少8位）
SERVER_ADDRESS=http://192.168.31.180:3000
```

> ⚠️ **`SERVER_ADDRESS` 必须填你实际访问用的地址**（局域网 IP 或域名），
> 不要写 `localhost`。原因见下面「两个必踩的坑」。

查看自动初始化过程：

```bash
docker compose logs -f lmm-api | grep entrypoint
```

---

## 环境变量

本镜像在官方 MIXAPI 之外包了一层入口脚本（`docker-entrypoint.sh`），
支持以下**增强变量**。注意：上游源码里**没有**这些变量，
是本镜像自己实现的（通过调用 `/api/setup` 与直接写 SQLite）。

| 变量 | 默认 | 说明 |
|------|------|------|
| `INIT_ROOT_USER` | `root` | 初始管理员用户名，最多 12 字符 |
| `INIT_ROOT_PASSWORD` | 空 | 初始管理员密码，至少 8 位。**不填则不自动建号** |
| `SERVER_ADDRESS` | 空 | 对外访问地址。填了会自动写入数据库并生效 |
| `INIT_AUTO_SETUP` | `auto` | `auto` 仅未初始化时建号 / `force` 总是尝试 / `off` 关闭 |
| `TZ` | `Asia/Shanghai` | 时区 |

行为说明：

- **幂等**。管理员已存在时不会重复创建，也不会覆盖密码。
  想改密码请登录后台操作，不要靠改环境变量。
- **只生效一次**。首次初始化后，`INIT_ROOT_PASSWORD` 就不再起作用
  （因为账号已存在，脚本会跳过）。
- **地址变更会触发重启**。若 `SERVER_ADDRESS` 与数据库不符，
  脚本会写库并重启主程序（**不是重启容器**，数据不受影响）。
- **不依赖 python**。镜像内装的是 `sqlite`，改地址走宿主机 CLI。

原版支持的变量（`SESSION_SECRET`、`SQL_DSN`、`REDIS_CONN_STRING`、
`STREAMING_TIMEOUT` 等）依然可用，见 `docker-compose.yml` 注释。

---

## 不用环境变量也可以（手动方式）

如果你的平台不方便设置环境变量，可以用脚本手工完成：

```bash
sh scripts/init_deploy.sh \
    --addr http://192.168.31.180:3000 \
    --user root \
    --pass '你的密码（至少8位）'
```

看到 `[OK] 地址修正成功` 即可打开 <http://192.168.31.180:3000> 登录。

> 💡 这个脚本**不依赖 python**，iStoreOS / OpenWrt 等精简系统可直接跑。
> 它会自动完成三件事：创建管理员 → 验证登录 → 修正访问地址。
> 重复执行是安全的（已初始化会自动跳过）。

只检查当前状态、不改动任何东西：

```bash
sh scripts/init_deploy.sh --addr http://192.168.31.180:3000 --check
```

查看日志：

```bash
docker compose logs -f
```

---

## 两个必踩的坑

这两个坑是实际部署时踩出来的，官方 README 没有说明。

### 坑一：部署完直接打开网页，登录不进去

**现象**：容器正常启动、`/api/status` 返回 200、页面能打开，
但一登录就失败，或者根本没有可用的账号。

**原因**：MIXAPI 首次启动时数据库是**空的**：

```
users 表 0 行  →  不存在任何账号
setups 表 0 行 →  系统未初始化
```

启动日志会明确告诉你：

```
[SYS] system is not initialized and no root user exists
```

它**不会**自动创建默认管理员。必须先调用 `/api/setup` 创建第一个
管理员账号，这一步做了系统才算初始化完成（`setup: true`）。

`scripts/init_deploy.sh` 封装了这个流程（纯 shell，无需 python）。

> 注意：`setup` 状态存在内存里，容器重启后会根据「是否存在 root 用户」
> 重新判断。所以只要没创建成功账号，重启多少次都还是未初始化状态。

### 坑二：环境变量 `FRONTEND_BASE_URL` 改了没用

**现象**：`docker-compose.yml` 里设了 `FRONTEND_BASE_URL=http://192.168.31.180:3000`，
但 `/api/status` 返回的 `server_address` 仍然是 `http://localhost:3000`。

**原因**：启动日志里有一行：

```
[SYS] FRONTEND_BASE_URL is ignored on master node
```

**这个环境变量在单机（master 节点）部署时被官方直接忽略。**

真正控制该地址的是代码里编译进去的默认值：

```go
// setting/system_setting.go
var ServerAddress = "http://localhost:3000"
```

它只在**首次初始化**时被写入数据库的 `options` 表。之后以数据库为准，
环境变量完全不起作用。

**影响**：`server_address` 和 `passkey_rp_id` 都指向 `localhost:3000`，
用局域网 IP 访问时 Passkey 校验的域对不上，Passkey 登录失败
（用户名密码登录不受影响）。

**修正方法**：直接改数据库的 `options` 表。项目已提供脚本：

```bash
sh scripts/fix_server_address.sh http://192.168.31.180:3000
```

（`init_deploy.sh` 已内置这一步，通常不需要单独执行。）

它会写入三项并重启容器：

| options.key | 值 | 说明 |
|---|---|---|
| `ServerAddress` | `http://192.168.31.180:3000` | 对外访问地址 |
| `PasskeyOrigins` | `192.168.31.180:3000` | Passkey 允许来源 |
| `PasskeyRPID` | `192.168.31.180` | Passkey RP ID（纯主机名） |

也可以在**管理后台 → 系统设置**里改 `ServerAddress`，效果相同。

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
| 状态接口 | `/api/status` 返回 200 ✓ |
| 首次初始化 | `/api/setup` 创建管理员成功 ✓ |
| 局域网登录 | `POST /api/user/login` 返回 session ✓ |
| 地址修正 | `server_address` 由 `localhost:3000` 改为局域网 IP ✓ |
| 一键脚本 | `init_deploy.sh` 从零到可用，且重复执行幂等 ✓ |
| 环境变量初始化 | `docker compose up -d` 后自动建号 + 修地址，零手工操作 ✓ |

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

改地址、迁移、备份都需要直接操作 `./data/mix-api.db`。

如需改用 MySQL / PostgreSQL，通过 `SQL_DSN` 环境变量指定：

```yaml
environment:
  SQL_DSN: "root:password@tcp(mysql:3306)/lmm-api"
```

---

## 常见问题

**Q：打开网页登录不进去？**
先跑 `sh scripts/init_deploy.sh --addr <你的地址> --check`。
如果显示 `已初始化 : 0`，说明还没创建管理员，加上 `--user` / `--pass`
再跑一次即可。详见「两个必踩的坑 - 坑一」。

**Q：用户名密码能登录，但 Passkey 登录失败？**
`passkey_rp_id` 还是 `localhost:3000`。跑
`sh scripts/fix_server_address.sh <你的地址>` 修正。详见「坑二」。

**Q：端口 3000 被占用？**
改 `docker-compose.yml` 里 `ports` 冒号左边的值，如 `"3300:3000"`。
注意改了端口后，`--addr` 和地址修正要同步改。

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

---

## 目录结构

```
LMM-API/
├── Dockerfile                  # 联网构建（下载官方二进制）
├── Dockerfile.offline          # 离线构建（本地 COPY 二进制）
├── Dockerfile.build            # 从源码完整编译
├── docker-entrypoint.sh        # ★ 容器入口：环境变量驱动的自动初始化
├── docker-compose.yml          # 部署配置（读同目录 .env）
├── .env.example                # 环境变量模板（复制为 .env 后修改）
├── deploy.sh                   # 一键部署脚本
├── scripts/
│   ├── init_deploy.sh          # 手工初始化（纯 shell，推荐）
│   ├── init_deploy.py          # 同上，python 版本（功能更全）
│   ├── fix_server_address.sh   # 单独修正 server_address / Passkey
│   ├── set_address.py          # 上面脚本调用的 python 实现
│   ├── inspect_db.py           # 打印数据库全表结构（排障用）
│   ├── ssh_exec.py             # 远程执行命令（paramiko）
│   ├── test-env-init.sh        # 环境变量自动初始化的测试脚本
│   ├── push_via_api.py         # 通过 API 推送仓库（绕开 git 协议）
│   └── fetch-binary.sh         # 下载二进制并校验架构
└── README.md
```

### 环境变量初始化是怎么实现的

上游源码**没有** `INIT_ROOT_USER` 这类变量，是本镜像自己加的。
原理在 `docker-entrypoint.sh`：

1. 后台拉起原程序，轮询 `/api/status` 等待就绪
2. 调 `/api/setup` 查初始化状态，未初始化且设了密码就建管理员
3. 比对 `/api/status` 的 `server_address` 与 `SERVER_ADDRESS`，
   不一致则用镜像内的 `sqlite` 直接写 `options` 表，再重启主程序
4. 转入前台守护，主程序退出则容器退出（保证生命周期语义正确）

其中第 2、3 步都做了幂等判断，重复启动不会重复执行。

---

## 许可

本项目仅为上游 MIXAPI 的镜像封装与构建配置。
上游以 **Apache-2.0** 许可发布，本仓库同样遵循该许可。
