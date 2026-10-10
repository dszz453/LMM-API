"""检查并修正 MIXAPI 数据库中的 server_address 设置。

在容器内运行（需要挂载 /data）。
用法：
    python fix_address.py                 # 只查看
    python fix_address.py <新地址>        # 修改为新地址
"""

import sqlite3
import sys

DB = "/data/mix-api.db"


def main() -> None:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row

    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )]
    print("数据库表：", tables)
    print()

    # 找出可能存配置的表
    target = None
    for name in tables:
        cols = [r[1] for r in conn.execute(f"PRAGMA table_info('{name}')")]
        if "key" in cols and "value" in cols:
            print(f"候选配置表: {name}  列: {cols}")
            target = name

    if not target:
        print("未找到 key/value 形式的配置表")
        return

    print()
    print(f"=== {target} 表中的相关记录 ===")
    rows = list(conn.execute(f"SELECT key, value FROM '{target}'"))
    matched = 0
    for row in rows:
        k, v = row["key"], row["value"]
        if k and any(s in str(k).lower() for s in
                     ("address", "server", "frontend", "passkey", "origin")):
            print(f"  {k} = {v}")
            matched += 1
    print(f"（共 {len(rows)} 条记录，匹配到 {matched} 条相关项）")

    if len(sys.argv) < 2:
        print()
        print("仅查看模式。传入新地址即可修改，例如：")
        print("  python fix_address.py http://192.168.31.180:3000")
        return

    new_addr = sys.argv[1].rstrip("/")
    print()
    print(f"将要修改 server_address -> {new_addr}")

    cur = conn.execute(
        f"UPDATE '{target}' SET value = ? WHERE key = 'ServerAddress'",
        (new_addr,),
    )
    if cur.rowcount == 0:
        # 尝试其他可能的键名
        for key_name in ("server_address", "ServerAddress"):
            cur = conn.execute(
                f"UPDATE '{target}' SET value = ? WHERE key = ?",
                (new_addr, key_name),
            )
            if cur.rowcount:
                break

    conn.commit()
    print(f"已更新 {cur.rowcount} 行")

    print()
    print("=== 修改后 ===")
    for row in conn.execute(f"SELECT key, value FROM '{target}'"):
        k, v = row["key"], row["value"]
        if k and any(s in str(k).lower() for s in
                     ("address", "server", "frontend", "passkey", "origin")):
            print(f"  {k} = {v}")

    conn.close()


if __name__ == "__main__":
    main()
