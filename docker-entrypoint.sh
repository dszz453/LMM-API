#!/bin/sh
# ============================================================
# LMM-API 容器入口脚本
#
# 在原程序之外包一层，实现「环境变量驱动的自动初始化」：
#
#   INIT_ROOT_USER       初始管理员用户名（默认 root，最多 12 字符）
#   INIT_ROOT_PASSWORD   初始管理员密码（至少 8 位）
#   SERVER_ADDRESS       对外访问地址，如 http://192.168.31.180:3000
#   INIT_AUTO_SETUP      是否启用自动初始化（默认 auto）
#                          auto  = 未初始化时自动建号
#                          force = 无论是否初始化都尝试建号（失败忽略）
#                          off   = 完全关闭，等价于原版行为
#
# 说明：MIXAPI 原版不支持这些变量（源码里没有 ROOT_USER 之类），
# 本脚本通过调用 /api/setup 与直接改 SQLite 实现，属于本镜像的增强。
# ============================================================

set -u

APP=/app/lmm-api
DATA_DIR=/data
DB="$DATA_DIR/mix-api.db"
PORT="${PORT:-3000}"
BASE="http://127.0.0.1:$PORT"

log() { echo "[entrypoint] $*"; }

# ------------------------------------------------------------
# 工具：等待服务就绪
# ------------------------------------------------------------
wait_ready() {
    i=0
    while [ "$i" -lt 60 ]; do
        if wget -qO- "$BASE/api/status" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# ------------------------------------------------------------
# 工具：查询初始化状态；回显 1=已初始化 0=未初始化
# ------------------------------------------------------------
is_initialized() {
    json=$(wget -qO- "$BASE/api/setup" 2>/dev/null || echo '')
    case "$json" in
        *'"status":true'*)   echo 1 ;;
        *'"root_init":true'*) echo 1 ;;
        *)                   echo 0 ;;
    esac
}

# ------------------------------------------------------------
# 工具：用 JSON 转义（避免密码里的引号/反斜杠破坏请求体）
# ------------------------------------------------------------
json_escape() {
    # 依次转义 反斜杠 -> 双引号
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ------------------------------------------------------------
# 工具：调用 /api/setup 创建管理员
# ------------------------------------------------------------
do_setup() {
    u=$(json_escape "$INIT_ROOT_USER")
    p=$(json_escape "$INIT_ROOT_PASSWORD")
    body=$(printf '{"username":"%s","password":"%s","confirmPassword":"%s","SelfUseModeEnabled":false,"DemoSiteEnabled":false}' "$u" "$p" "$p")

    resp=$(printf '%s' "$body" | wget -qO- --header='Content-Type: application/json' \
        --post-data="$body" "$BASE/api/setup" 2>/dev/null || echo '')

    case "$resp" in
        *'"success":true'*)
            log "管理员 '$INIT_ROOT_USER' 创建成功"
            return 0 ;;
        *'已初始化'*)
            log "系统已初始化，跳过创建"
            return 0 ;;
        *)
            log "创建管理员失败：$resp"
            return 1 ;;
    esac
}

# ------------------------------------------------------------
# 工具：取当前 server_address
# ------------------------------------------------------------
current_address() {
    wget -qO- "$BASE/api/status" 2>/dev/null \
        | tr ',' '\n' | grep '"server_address"' | head -1 | cut -d'"' -f4
}

# ------------------------------------------------------------
# 工具：把地址写进 SQLite（需要 sqlite3 或 python，二者都没则放弃）
# ------------------------------------------------------------
write_address() {
    addr="$1"
    body="${addr#*://}"          # 去掉协议
    host_port="$body"            # host:port
    host_only="${body%%:*}"      # 仅主机名
    [ "$host_only" = "$body" ] && host_only="$body"

    sql_tmp="/tmp/_addr.sql"
    cat > "$sql_tmp" <<EOF
INSERT OR REPLACE INTO options (key, value) VALUES ('ServerAddress', '$addr');
INSERT OR REPLACE INTO options (key, value) VALUES ('PasskeyOrigins', '$host_port');
INSERT OR REPLACE INTO options (key, value) VALUES ('PasskeyRPID', '$host_only');
EOF

    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$DB" < "$sql_tmp" 2>/dev/null && { rm -f "$sql_tmp"; return 0; }
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sqlite3,sys
c=sqlite3.connect('$DB')
for line in open('$sql_tmp'):
    line=line.strip()
    if line: c.execute(line)
c.commit(); c.close()
" 2>/dev/null && { rm -f "$sql_tmp"; return 0; }
    fi

    rm -f "$sql_tmp"
    return 1
}

# ------------------------------------------------------------
# 启动主程序（后台），返回 PID
# ------------------------------------------------------------
start_app() {
    "$APP" &
    APP_PID=$!
    log "主程序已启动 (pid=$APP_PID)"
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
INIT_ROOT_USER="${INIT_ROOT_USER:-root}"
INIT_ROOT_PASSWORD="${INIT_ROOT_PASSWORD:-}"
SERVER_ADDRESS="${SERVER_ADDRESS:-}"
INIT_AUTO_SETUP="${INIT_AUTO_SETUP:-auto}"

cd "$DATA_DIR" 2>/dev/null || true

start_app

# 等待就绪
if ! wait_ready; then
    log "警告：等待服务就绪超时，跳过自动初始化"
else
    # ---- 1) 自动创建管理员 ----
    if [ "$INIT_AUTO_SETUP" != "off" ] && [ -n "$INIT_ROOT_PASSWORD" ]; then
        inited=$(is_initialized)
        if [ "$inited" = "0" ]; then
            log "检测到系统未初始化，开始创建管理员 ..."
            do_setup || true
        elif [ "$INIT_AUTO_SETUP" = "force" ]; then
            log "INIT_AUTO_SETUP=force，尝试创建管理员 ..."
            do_setup || true
        else
            log "系统已初始化，跳过创建管理员"
        fi
    fi

    # ---- 2) 自动修正访问地址 ----
    if [ -n "$SERVER_ADDRESS" ]; then
        want=$(printf '%s' "$SERVER_ADDRESS" | sed 's:/*$::')
        have=$(current_address)
        if [ "$want" != "$have" ]; then
            log "访问地址不一致：当前 '$have'，目标 '$want'"
            if write_address "$want"; then
                log "地址已写入数据库，重启主程序使其生效 ..."
                kill "$APP_PID" 2>/dev/null || true
                wait "$APP_PID" 2>/dev/null || true
                start_app
                wait_ready || log "警告：重启后等待就绪超时"
            else
                log "警告：无 sqlite3/python3，无法自动改地址。"
                log "       请在管理后台 -> 系统设置 里手动修改 ServerAddress。"
            fi
        else
            log "访问地址已正确：$have"
        fi
    fi
fi

# ------------------------------------------------------------
# 前台守护：主程序退出则容器退出
# ------------------------------------------------------------
trap 'log "收到退出信号，正在停止 ..."; kill "$APP_PID" 2>/dev/null; exit 0' TERM INT
while kill -0 "$APP_PID" 2>/dev/null; do
    sleep 2 &
    wait $! 2>/dev/null
done
wait "$APP_PID" 2>/dev/null
exit $?
