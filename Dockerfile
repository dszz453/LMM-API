# ============================================================
# LMM-API — AMD64 Docker 镜像
#
# 基于 MIXAPI v2.5.1cl 官方发布的已编译二进制构建。
# 上游项目：https://github.com/aiprodcoder/MIXAPI
#
# 说明：上游仓库自带的 Dockerfile 停留在 v1.2，且该 release
# 已不存在（构建会失败）。此文件更新到当前最新版 v2.5.1cl。
#
# 构建：
#   docker build --platform linux/amd64 -t lmm-api:2.5.1cl .
# ============================================================
FROM alpine:3.20

ARG MIXAPI_VERSION=v2.5.1cl
ARG TARGETARCH=amd64

LABEL org.opencontainers.image.title="LMM-API"
LABEL org.opencontainers.image.description="大模型 API 网关，统一 OpenAI/Claude/Gemini 兼容接口"
LABEL org.opencontainers.image.source="https://github.com/aiprodcoder/MIXAPI"
LABEL org.opencontainers.image.version="${MIXAPI_VERSION}"

RUN apk add --no-cache \
        ca-certificates \
        tzdata \
        wget \
        sqlite \
    && rm -rf /var/cache/apk/*

# 时区设为东八区，日志时间与国内一致
ENV TZ=Asia/Shanghai

WORKDIR /app

# 强校验架构：本镜像只针对 AMD64
RUN set -eux; \
    arch="$(apk --print-arch)"; \
    if [ "$arch" != "x86_64" ]; then \
        echo "错误：本镜像仅支持 AMD64，当前架构为 $arch"; \
        exit 1; \
    fi; \
    wget -O /app/lmm-api \
        "https://github.com/aiprodcoder/MIXAPI/releases/download/${MIXAPI_VERSION}/mixapi-${MIXAPI_VERSION}-linux-amd64"; \
    chmod +x /app/lmm-api; \
    # 简单校验是 ELF 可执行文件，避免下载到错误页面
    head -c 4 /app/lmm-api | grep -q "ELF" || { echo "错误：下载的并非 ELF 可执行文件"; exit 1; }; \
    /app/lmm-api --version 2>/dev/null || echo "（二进制未提供 --version 参数，跳过）"

EXPOSE 3000

# 数据目录持久化：SQLite 数据库与日志都在这里
VOLUME ["/data"]
WORKDIR /data

# 入口脚本：环境变量驱动的自动初始化（建管理员 + 修地址）
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- http://127.0.0.1:3000/api/status >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
