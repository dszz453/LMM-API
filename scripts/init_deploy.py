"""首次部署初始化脚本 —— 创建管理员账号并修正访问地址。

MIXAPI 首次启动时数据库是空的（users 表 0 行），
此时打开网页只有登录页、没有账号，表现为"登录不进去"。
必须先调用 /api/setup 创建第一个管理员。

另外 MIXAPI 的编译默认地址是 http://localhost:3000,
用局域网 IP 访问时 Passkey 校验会失败，需一并修正。

用法（在宿主机上运行，需能访问到服务）：
    python init_deploy.py --addr http://192.168.31.180:3000 \
        --user root --pass 'YourPassword123'

    # 只检查当前状态
    python init_deploy.py --addr http://192.168.31.180:3000 --check
"""

import argparse
import json
import sys
import urllib.error
import urllib.request


def http(method: str, url: str, body: dict | None = None, timeout: int = 15):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}
    except Exception as e:  # noqa: BLE001
        return 0, {"error": str(e)}


def main() -> int:
    ap = argparse.ArgumentParser(description="LMM-API 首次部署初始化")
    ap.add_argument("--addr", required=True, help="服务访问地址，如 http://192.168.31.180:3000")
    ap.add_argument("--user", default="root", help="管理员用户名（最多 12 字符）")
    ap.add_argument("--pass", dest="password", default=None, help="管理员密码（至少 8 位）")
    ap.add_argument("--check", action="store_true", help="只检查状态，不做修改")
    args = ap.parse_args()

    base = args.addr.rstrip("/")

    # 1) 探测服务是否可达、初始化状态如何
    code, data = http("GET", f"{base}/api/setup")
    if code == 0:
        print(f"[错误] 无法访问 {base}/api/setup：{data.get('error')}")
        return 1

    payload = data.get("data", {})
    initialized = payload.get("status") is True or payload.get("root_init") is True
    print(f"服务地址 : {base}")
    print(f"数据库   : {payload.get('database_type', '未知')}")
    print(f"已初始化 : {initialized}")

    if args.check:
        return 0

    # 2) 未初始化则创建管理员
    if initialized:
        print("\n[跳过] 系统已初始化，无需再次创建管理员。")
    else:
        if not args.password:
            print("\n[错误] 系统未初始化，必须提供 --pass 参数来创建管理员。")
            return 1
        if len(args.user) > 12:
            print(f"\n[错误] 用户名不能超过 12 个字符（当前 {len(args.user)} 个）。")
            return 1
        if len(args.password) < 8:
            print(f"\n[错误] 密码至少 8 位（当前 {len(args.password)} 位）。")
            return 1

        print(f"\n正在创建管理员 '{args.user}' ...")
        code, resp = http("POST", f"{base}/api/setup", {
            "username": args.user,
            "password": args.password,
            "confirmPassword": args.password,
            "SelfUseModeEnabled": False,
            "DemoSiteEnabled": False,
        })
        if code == 200 and resp.get("success"):
            print(f"[成功] {resp.get('message', '系统初始化成功')}")
        else:
            print(f"[失败] HTTP {code}: {resp.get('message') or resp}")
            return 1

    # 3) 验证登录可用
    if args.password:
        code, resp = http("POST", f"{base}/api/user/login", {
            "username": args.user, "password": args.password,
        })
        if code == 200 and resp.get("success"):
            u = resp.get("data", {})
            print(f"[验证] 登录成功：{u.get('username')} / 角色 {u.get('role')}（100=超级管理员）")
        else:
            print(f"[警告] 登录验证未通过：HTTP {code} {resp.get('message') or resp}")

    # 4) 检查访问地址是否正确
    code, st = http("GET", f"{base}/api/status")
    if code == 200:
        d = st.get("data", {})
        sa = d.get("server_address", "")
        rp = d.get("passkey_rp_id", "")
        print(f"\n当前 server_address : {sa}")
        print(f"当前 passkey_rp_id  : {rp}")
        if sa == base:
            print("[OK] 访问地址已与部署地址一致。")
        else:
            print("[提示] 访问地址与部署地址不一致，Passkey 登录可能失败。")
            print("       请执行以下命令修正（需停止容器后写入数据库）：")
            print(f"       scripts/fix_server_address.sh {base}")

    print("\n完成。用浏览器打开：", base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
