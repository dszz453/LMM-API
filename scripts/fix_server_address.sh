#!/bin/sh
# 修正 MIXAPI 的访问地址（server_address / Passkey 来源）。
#
# 原因：MIXAPI 编译默认地址是 http://localhost:3000，
# 用局域网 IP 访问时 Passkey 校验会对不上，表现为"登录不进去"。
# 环境变量 FRONTEND_BASE_URL 在 master 节点上被官方忽略，只能改数据库。
#
# 用法（在服务器上，项目目录内执行）：
#     sh scripts/fix_server_address.sh http://192.168.31.180:3000
#
# 数据库默认在 ./data/mix-api.db（对应容器内 /data/mix-api.db）

set -e

NEW_ADDR="$1"
if [ -z "$NEW_ADDR" ]; then
    echo "用法: sh scripts/fix_server_address.sh http://<IP>:<PORT>"
    exit 1
fi

# 去掉结尾斜杠
NEW_ADDR=$(echo "$NEW_ADDR" | sed 's:/*$::')
BODY=$(echo "$NEW_ADDR" | sed 's:^[a-z]*://::')
HOST_PORT="$BODY"
HOST_ONLY=$(echo "$BODY" | cut -d: -f1)

# 定位数据目录：优先 ./data，其次 /mnt/docker/lmm-api-data
DATA_DIR=""
for d in ./data /mnt/docker/lmm-api-data; do
    if [ -f "$d/mix-api.db" ]; then
        DATA_DIR="$d"
        break
    fi
done

if [ -z "$DATA_DIR" ]; then
    echo "错误：找不到 mix-api.db。请确认在项目目录下运行，或手动指定数据目录。"
    exit 1
fi

echo "数据目录: $DATA_DIR"
echo "目标地址: $NEW_ADDR"

echo "停止容器 lmm-api ..."
docker stop lmm-api >/dev/null 2>&1 || true

echo "写入配置 ..."
docker run --rm -v "$(cd "$DATA_DIR" && pwd)":/data python:3.11-slim python -c "
import sqlite3
c = sqlite3.connect('/data/mix-api.db')
updates = {
    'ServerAddress':  '$NEW_ADDR',
    'PasskeyOrigins': '$HOST_PORT',
    'PasskeyRPID':    '$HOST_ONLY',
}
for k, v in updates.items():
    if c.execute('SELECT 1 FROM options WHERE key=?', (k,)).fetchone():
        c.execute('UPDATE options SET value=? WHERE key=?', (v, k))
    else:
        c.execute('INSERT INTO options (key, value) VALUES (?, ?)', (k, v))
    print('  ', k, '=', v)
c.commit(); c.close()
"

echo "启动容器 ..."
docker start lmm-api >/dev/null

sleep 5
echo "验证："
curl -s "http://127.0.0.1:3000/api/status" \
    | tr ',' '\n' | grep -E 'server_address|passkey_rp_id'

echo
echo "完成。"
