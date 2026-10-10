"""完整探查 MIXAPI 数据库结构，找出 server_address 的真实存储位置。

在容器内运行（挂载 /data）：
    python inspect_db.py
"""

import sqlite3

DB = "/data/mix-api.db"


def main() -> None:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row

    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    )]
    print("=" * 70)
    print("全部表:", tables)
    print("=" * 70)

    for name in tables:
        cols = [r[1] for r in conn.execute(f"PRAGMA table_info('{name}')")]
        try:
            total = conn.execute(f"SELECT COUNT(*) FROM '{name}'").fetchone()[0]
        except Exception as e:
            total = f"ERR {e}"
        print(f"\n--- 表 {name}  行数={total}")
        print(f"    列: {cols}")

        # 对每张表打印前几行，重点看有无地址类字段
        if isinstance(total, int) and total > 0:
            try:
                rows = conn.execute(f"SELECT * FROM '{name}' LIMIT 8").fetchall()
                for r in rows:
                    d = dict(r)
                    # 截断长值
                    out = {}
                    for k, v in d.items():
                        s = str(v)
                        out[k] = s if len(s) <= 120 else s[:117] + "..."
                    print(f"    {out}")
            except Exception as e:
                print(f"    (读取失败: {e})")

    conn.close()


if __name__ == "__main__":
    main()
