#!/bin/sh
# LMM-API 首次初始化（纯 shell 实现，不依赖 python）
#
# 适用环境：iStoreOS / OpenWrt / 精简 Linux 等没有 python 的机器。
#
# 做两件事：
#   1. 调用 /api/setup 创建第一个管理员（系统未初始化时）
#   2. 修正 server_address / Passkey 配置为实际访问地址
#
# 用法：
#   sh scripts/init_deploy.sh --addr http://192.168.31.180:3000 \
#       --user root --pass 'YourPassword123'
#
#   # 只检查状态
#   sh scripts/init_deploy.sh --addr http://192.168.31.180:3000 --check

ADDR=""
USER_NAME="root"
PASSWORD=""
CHECK_ONLY=0

usage() {
    echo "用法: sh scripts/init_deploy.sh --addr <地址> [--user <用户名>] [--pass <密码>] [--check]"
    echo ""
    echo "  --addr   服务访问地址，如 http://192.168.31.180:3000（必填）"
    echo "  --user   管理员用户名，默认 root，最多 12 字符"
    echo "  --pass   管理员密码，至少 8 位"
    echo "  --check  只检查状态，不做任何修改"
    echo ""
    echo "示例:"
    echo "  sh scripts/init_deploy.sh --addr http://192.168.31.180:3000 --user root --pass 'Abc123456'"
}

# ---- 解析参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        --addr)  ADDR="$2"; shift 2 ;;
        --user)  USER_NAME="$2"; shift 2 ;;
        --pass)  PASSWORD="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
done

if [ -z "$ADDR" ]; then
    echo "错误：必须指定 --addr"
    usage
    exit 1
fi
# 去掉结尾斜杠（用 shell 参数展开，兼容 busybox，无需 sed）
while [ "${ADDR%/}" != "$ADDR" ]; do
    ADDR="${ADDR%/}"
done

# ---- 依赖检查 ----
if ! command -v curl >/dev/null 2>&1; then
    echo "错误：需要 curl，请先安装（opkg install curl）"
    exit 1
fi

echo "服务地址 : $ADDR"

# ---- 1) 查询初始化状态 ----
SETUP_JSON=$(curl -s -m 15 "$ADDR/api/setup" 2>/dev/null || echo '')

if echo "$SETUP_JSON" | grep -q '"status":true'; then
    INITIALIZED=1
elif echo "$SETUP_JSON" | grep -q '"root_init":true'; then
    INITIALIZED=1
else
    INITIALIZED=0
fi

if [ -z "$SETUP_JSON" ]; then
    echo "错误：无法访问 $ADDR/api/setup，请确认服务已启动、地址正确。"
    exit 1
fi

echo "已初始化 : $INITIALIZED"

if [ "$CHECK_ONLY" = "1" ]; then
    if [ "$INITIALIZED" = "0" ]; then
        echo
        echo "[提示] 系统未初始化，还需提供 --user 和 --pass 创建管理员。"
    fi
    exit 0
fi

# ---- 2) 未初始化则创建管理员 ----
if [ "$INITIALIZED" = "1" ]; then
    echo "[跳过] 系统已初始化，无需创建管理员。"
else
    if [ -z "$PASSWORD" ]; then
        echo "错误：系统未初始化，必须提供 --pass 参数创建管理员。"
        exit 1
    fi
    if [ ${#PASSWORD} -lt 8 ]; then
        echo "错误：密码至少 8 位（当前 ${#PASSWORD} 位）。"
        exit 1
    fi
    if [ ${#USER_NAME} -gt 12 ]; then
        echo "错误：用户名不能超过 12 个字符。"
        exit 1
    fi

    echo
    echo "正在创建管理员 '$USER_NAME' ..."
    RESP=$(curl -s -m 20 -X POST "$ADDR/api/setup" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASSWORD\",\"confirmPassword\":\"$PASSWORD\",\"SelfUseModeEnabled\":false,\"DemoSiteEnabled\":false}" 2>/dev/null)

    if echo "$RESP" | grep -q '"success":true'; then
        echo "[成功] 管理员创建完成。"
    else
        echo "[失败] $RESP"
        exit 1
    fi

    # 登录验证
    LOGIN=$(curl -s -m 20 -X POST "$ADDR/api/user/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null)
    if echo "$LOGIN" | grep -q '"success":true'; then
        echo "[验证] 登录成功。"
    else
        echo "[警告] 登录验证未通过：$LOGIN"
    fi
fi

# ---- 3) 检查并修正访问地址 ----
STATUS=$(curl -s -m 15 "$ADDR/api/status" 2>/dev/null || echo '')
SA=$(echo "$STATUS" | tr ',' '\n' | grep '"server_address"' | head -1 | cut -d'"' -f4)
RP=$(echo "$STATUS" | tr ',' '\n' | grep '"passkey_rp_id"' | head -1 | cut -d'"' -f4)

echo
echo "当前 server_address : $SA"
echo "当前 passkey_rp_id  : $RP"

if [ "$SA" = "$ADDR" ]; then
    echo "[OK] 访问地址已与部署地址一致。"
    echo
    echo "完成。用浏览器打开：$ADDR"
    exit 0
fi

echo
echo "[修正] 访问地址不一致，正在改为 $ADDR ..."

# 定位数据目录
DATA_DIR=""
for d in ./data /mnt/docker/lmm-api-data; do
    if [ -f "$d/mix-api.db" ]; then DATA_DIR="$d"; break; fi
done

if [ -z "$DATA_DIR" ]; then
    echo "[警告] 找不到 mix-api.db（已查找 ./data 和 /mnt/docker/lmm-api-data）。"
    echo "       可手动执行：sh scripts/fix_server_address.sh $ADDR"
    echo "       或在管理后台 -> 系统设置 里修改 ServerAddress。"
    exit 0
fi

ABS_DATA_DIR=$(cd "$DATA_DIR" && pwd)
# 去掉协议前缀，得到 host:port（用参数展开，兼容 busybox）
BODY="$ADDR"
case "$BODY" in
    *"://"*) BODY="${BODY#*://}" ;;
esac
HOST_PORT="$BODY"
HOST_ONLY="${BODY%%:*}"
case "$HOST_ONLY" in
    *:*|"") HOST_ONLY="$BODY" ;;  # 没有冒号则整段即主机名
esac

echo "数据目录: $ABS_DATA_DIR"

# 写一个临时 sql 脚本，避免多行 python 在 shell 里转义的坑
TMP_SQL="/tmp/lmm_update_$$.sql"
cat > "$TMP_SQL" <<EOF
INSERT OR REPLACE INTO options (key, value) VALUES ('ServerAddress', '$ADDR');
INSERT OR REPLACE INTO options (key, value) VALUES ('PasskeyOrigins', '$HOST_PORT');
INSERT OR REPLACE INTO options (key, value) VALUES ('PasskeyRPID', '$HOST_ONLY');
EOF

docker stop lmm-api >/dev/null 2>&1 || true

# sqlite3 不一定可用；优先用宿主机 sqlite3，其次用 python 容器
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$ABS_DATA_DIR/mix-api.db" < "$TMP_SQL" \
        && echo "  配置已写入（sqlite3）" \
        || echo "  [警告] sqlite3 写入失败"
    rm -f "$TMP_SQL"
else
    # 把 sql 文件挂进容器执行
    docker run --rm -v "$ABS_DATA_DIR":/data -v "$TMP_SQL":/tmp/u.sql:ro \
        python:3.11-slim python -c "
import sqlite3
c = sqlite3.connect('/data/mix-api.db')
with open('/tmp/u.sql') as f:
    for line in f:
        line = line.strip()
        if line:
            c.execute(line)
c.commit()
c.close()
print('  配置已写入')
" && rm -f "$TMP_SQL" || {
        echo "  [警告] 写入失败。可能需要先拉取 python 镜像："
        echo "         docker pull python:3.11-slim"
        rm -f "$TMP_SQL"
    }
fi

docker start lmm-api >/dev/null 2>&1 || true
sleep 5

SA2=$(curl -s -m 15 "$ADDR/api/status" 2>/dev/null | tr ',' '\n' | grep '"server_address"' | head -1 | cut -d'"' -f4)
echo "修正后 server_address : $SA2"

if [ "$SA2" = "$ADDR" ]; then
    echo "[OK] 地址修正成功。"
else
    echo "[警告] 地址仍为 $SA2，请手动在后台修改。"
fi

echo
echo "完成。用浏览器打开：$ADDR"
