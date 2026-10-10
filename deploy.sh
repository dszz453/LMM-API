#!/usr/bin/env bash
# LMM-API 快速部署脚本（适用于 Linux / NAS / 软路由等已装 Docker 的环境）
#
# 会自动检查 .env 是否存在，不存在则用 .env.example 生成并提示修改。
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
echo "==> 检查环境变量配置 .env"
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "已从 .env.example 生成 .env"
        echo
        echo "【请先编辑 .env，填入你的管理员密码和访问地址】"
        echo "  必须修改的两项："
        echo "    INIT_ROOT_PASSWORD  = 你的密码（至少 8 位）"
        echo "    SERVER_ADDRESS      = 你实际访问用的地址（勿写 localhost）"
        echo
        read -r -p "现在编辑 .env 吗？[Y/n] " ans
        case "${ans:-Y}" in
            [Yy]*)
                "${EDITOR:-vi}" .env
                ;;
            *)
                echo "已跳过。直接用现有配置继续（可能仍是默认密码，请尽快修改）"
                ;;
        esac
    else
        echo "警告：未找到 .env 和 .env.example，将使用默认配置"
        echo "      默认不会创建管理员账号，需手工执行 scripts/init_deploy.sh"
    fi
else
    echo ".env 已存在"
fi

echo
echo "==> 检查端口 $PORT 是否被占用"
if command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ":${PORT} "; then
    echo "警告：端口 $PORT 已被占用，请改 docker-compose.yml 或设置 PORT 环境变量"
    exit 1
fi
echo "端口可用"

echo
echo "==> 启动服务"
# 优先用线上镜像；若配置了 build 则 compose 会自行构建
$DC up -d

echo
echo "==> 等待服务就绪（首次会自动创建管理员，可能需要 30 秒）"
for i in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
        echo "服务已就绪"
        break
    fi
    if [ "$i" -eq 45 ]; then
        echo "警告：健康检查超时，容器日志："
        $DC logs --tail 40
        exit 1
    fi
    sleep 2
done

echo
echo "==> 初始化日志"
$DC logs 2>&1 | grep -E 'entrypoint' || echo "（无 entrypoint 日志，可能不是本镜像）"

echo
$DC ps

# 从 .env 读地址用于提示
ADDR=""
if [ -f .env ]; then
    ADDR=$(grep -E '^SERVER_ADDRESS=' .env | cut -d= -f2- || true)
fi
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "本机IP")

echo
echo "部署完成！"
if [ -n "$ADDR" ]; then
    echo "  访问地址：${ADDR}"
else
    echo "  本机访问：http://127.0.0.1:${PORT}"
    echo "  局域网访问：http://${IP}:${PORT}"
fi
echo
echo "  查看初始化过程：$DC logs -f | grep entrypoint"
echo "  管理员账号见 .env 里的 INIT_ROOT_USER / INIT_ROOT_PASSWORD"
