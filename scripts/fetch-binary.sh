#!/usr/bin/env bash
# 下载 MIXAPI 二进制到 build-context/，供 Dockerfile.offline 离线构建使用。
#
# 用法：
#   bash scripts/fetch-binary.sh                # 默认版本
#   bash scripts/fetch-binary.sh v2.5.1cl       # 指定版本
#   bash scripts/fetch-binary.sh v2.5.1cl arm64 # 指定架构（默认 amd64）
set -euo pipefail

VERSION="${1:-v2.5.1cl}"
ARCH="${2:-amd64}"

cd "$(dirname "$0")/.."
mkdir -p build-context

URL="https://github.com/aiprodcoder/MIXAPI/releases/download/${VERSION}/mixapi-${VERSION}-linux-${ARCH}"
OUT="build-context/lmm-api"

echo "下载: $URL"
echo "保存到: $OUT"

if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 --retry-delay 5 -o "$OUT" "$URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$OUT" "$URL"
else
    echo "错误：需要 curl 或 wget"
    exit 1
fi

echo
echo "校验文件："
SIZE=$(wc -c < "$OUT")
echo "  大小: $SIZE 字节 ($((SIZE / 1024 / 1024)) MB)"

# 校验 ELF 魔数与架构
if head -c 4 "$OUT" | grep -q "ELF"; then
    echo "  ELF 格式: 是"
else
    echo "  错误：不是 ELF 文件，可能下载到了错误页面"
    rm -f "$OUT"
    exit 1
fi

if [ "$ARCH" = "amd64" ]; then
    MACHINE=$(od -An -tu2 -j18 -N2 "$OUT" | tr -d ' ')
    if [ "$MACHINE" = "62" ]; then
        echo "  架构: AMD64 (x86-64) 确认"
    else
        echo "  警告：架构字段为 $MACHINE，预期 62 (AMD64)"
    fi
fi

# 记录校验和
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$OUT" > "$OUT.sha256"
    echo "  SHA256 已保存到 $OUT.sha256"
fi

echo
echo "完成。现在可以构建："
echo "  docker build -f Dockerfile.offline -t lmm-api:${VERSION} ."
