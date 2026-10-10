"""将 MIXAPI 的 ServerAddress / Passkey 配置修正为指定地址。

在容器外运行（挂载 /data），直接写 SQLite 的 options 表。
容器重启后会从 options 表加载，覆盖编译期默认值 localhost:3000。

用法：
    python set_address.py                          # 只查看
    python set_address.py http://192.168.31.180:3000
"""

import sqlite3
import sys

DB = "/data/mix-api.db"

# 需要随 ServerAddress 一起同步的键：
#   ServerAddress   —— 对外访问地址，影响前端展示、回调链接、聊天客户端 baseURL
#   PasskeyOrigins  —— Passkey 允许的来源，必须是 host:port
#   PasskeyRPID     —— Passkey 的 RP ID，必须是纯主机名（不含协议和端口）
SYNC_KEYS = ("ServerAddress", "PasskeyOrigins", "PasskeyRPID")


def main() -> None:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row

    rows = {r["key"]: r["value"] for r in
            conn.execute("SELECT key, value FROM options")}
    print("当前相关配置：")
    for k in SYNC_KEYS:
        print(f"  {k} = {rows.get(k, '<未设置，使用编译默认值>')}")

    if len(sys.argv) < 2:
        print()
        print("仅查看模式。传入新地址即可修改，例如：")
        print("  python set_address.py http://192.168.31.180:3000")
        return

    new_addr = sys.argv[1].rstrip("/")
    # 从 URL 中解析出 host:port 与 host
    body = new_addr.split("://", 1)[-1]
    host_port = body
    host_only = body.split(":")[0]

    updates = {
        "ServerAddress": new_addr,
        "PasskeyOrigins": host_port,
        "PasskeyRPID": host_only,
    }

    print()
    print(f"将要更新为：{updates}")
    for k, v in updates.items():
        exists = conn.execute(
            "SELECT 1 FROM options WHERE key = ?", (k,)
        ).fetchone()
        if exists:
            conn.execute("UPDATE options SET value = ? WHERE key = ?", (v, k))
            print(f"  已更新 {k} = {v}")
        else:
            conn.execute("INSERT INTO options (key, value) VALUES (?, ?)", (k, v))
            print(f"  已新增 {k} = {v}")

    conn.commit()
    print()
    print("=== 修改后 ===")
    rows = {r["key"]: r["value"] for r in
            conn.execute("SELECT key, value FROM options")}
    for k in SYNC_KEYS:
        print(f"  {k} = {rows.get(k)}")

    conn.close()


if __name__ == "__main__":
    main()
