#!/usr/bin/env bash
# LMM-API 快速部署脚本（适用于 Linux / NAS / 软路由等已装 Docker 的环境）
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-3000}"

echo "==> 检查 Docker 环境"
if ! command -v docker >/dev/null 2>&1; then
    echo "错误：未检测到 docker，请先安装"
    exit 1
fi
docker --version
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "错误：未检测到 Docker Compose"
    exit 1
fi
echo "使用：$DC"

echo
echo "==> 检查端口 $PORT 是否被占用"
if command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ":${PORT} "; then
    echo "警告：端口 $PORT 已被占用，请改 docker-compose.yml 或设置 PORT 环境变量"
    exit 1
fi
echo "端口可用"

echo
echo "==> 构建镜像（首次约 1-2 分钟）"
$DC build

echo
echo "==> 启动服务"
$DC up -d

echo
echo "==> 等待服务就绪"
for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
        echo "服务已就绪"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "警告：健康检查超时，容器日志："
        $DC logs --tail 40
        exit 1
    fi
    sleep 2
done

echo
$DC ps
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "本机IP")
echo
echo "部署完成！"
echo "  本机访问：http://127.0.0.1:${PORT}"
echo "  局域网访问：http://${IP}:${PORT}"
echo "  首次进入需注册管理员账号"
