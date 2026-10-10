"""通过 GitHub REST API 把 LMM-API 目录推送到仓库。

绕开 git 传输协议（沙箱代理对 git push 支持不佳），
直接调用 Git Data API：先建 blob/tree/commit，再更新 ref，
这样是单次提交，而不是 N 次单文件提交。

用法：python scripts/push_via_api.py <本地目录> <owner/repo> <token>
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

SKIP_DIRS = {"__pycache__", ".git", ".venv", "venv", ".pytest_cache",
             "build-context", "data"}
SKIP_FILES = {".env", "mix-api.db", "lmm-api"}
API = "https://api.github.com"

COMMIT_MESSAGE = """feat: 修复部署后登录不进去的问题，补充部署 yaml 与初始化脚本

排查出两个官方 README 未说明的坑：

坑一：首次部署后没有账号，登录不进去
  容器启动时 users 表为 0 行，日志明确提示
  "system is not initialized and no root user exists"。
  MIXAPI 不会自动创建默认管理员，必须先调用 POST /api/setup
  创建第一个管理员账号，系统才算初始化完成。
  容器重启后会依据 root 用户是否存在重新判断初始化状态，
  因此没建成账号前重启多少次都无效。

坑二：FRONTEND_BASE_URL 环境变量在单机部署下被忽略
  启动日志有 "FRONTEND_BASE_URL is ignored on master node"。
  该地址真正来源是编译期默认值 setting.ServerAddress
  （硬编码 http://localhost:3000），仅在首次初始化时写入
  options 表，之后以数据库为准。
  影响：passkey_rp_id 指向 localhost:3000，用局域网 IP 访问时
  Passkey 校验域不匹配导致登录失败（密码登录不受影响）。

新增：
- scripts/init_deploy.py         首次初始化：建管理员 + 校验登录 + 地址检查
- scripts/fix_server_address.sh  修正 ServerAddress/PasskeyOrigins/PasskeyRPID
- scripts/set_address.py         shell 脚本调用的 python 实现
- scripts/inspect_db.py          打印数据库全表结构与内容（排障用）
- scripts/ssh_exec.py            基于 paramiko 的远程命令执行辅助

变更：
- docker-compose.yml  移除无效的 FRONTEND_BASE_URL，补注释说明
- README.md           重写，补充「两个必踩的坑」章节
                      与完整的初始化/排障步骤
"""


def api(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "lmm-api-push")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {detail[:400]}") from exc


def collect_files(root: Path) -> list[Path]:
    out = []
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.name in SKIP_FILES:
            continue
        out.append(p)
    return out


def main() -> None:
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)

    root = Path(sys.argv[1]).resolve()
    repo = sys.argv[2]
    token = sys.argv[3]

    files = collect_files(root)
    print(f"待推送 {len(files)} 个文件")

    # 1) 取当前默认分支的最新 commit
    try:
        ref = api("GET", f"/repos/{repo}/git/ref/heads/main", token)
        base_commit_sha = ref["object"]["sha"]
        print(f"基于已有提交 {base_commit_sha[:8]}")
    except RuntimeError as exc:
        text = str(exc)
        if "404" in text or "409" in text:
            base_commit_sha = None
            print("空仓库，将创建首个提交")
        else:
            raise

    base_tree_sha = None
    if base_commit_sha:
        commit = api("GET", f"/repos/{repo}/git/commits/{base_commit_sha}", token)
        base_tree_sha = commit["tree"]["sha"]

    # 2) 逐文件建 blob
    tree_entries = []
    for f in files:
        rel = f.relative_to(root).as_posix()
        content = base64.b64encode(f.read_bytes()).decode()
        blob = api("POST", f"/repos/{repo}/git/blobs", token,
                   {"content": content, "encoding": "base64"})
        tree_entries.append({
            "path": rel,
            "mode": "100755" if f.suffix == ".sh" else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        print(f"  + {rel}")

    # 3) 建 tree
    tree_payload: dict = {"tree": tree_entries}
    if base_tree_sha:
        tree_payload["base_tree"] = base_tree_sha
    tree = api("POST", f"/repos/{repo}/git/trees", token, tree_payload)

    # 4) 建 commit
    if base_commit_sha:
        parents = [base_commit_sha]
        force = False
    else:
        parents = []
        force = True

    commit = api("POST", f"/repos/{repo}/git/commits", token, {
        "message": COMMIT_MESSAGE,
        "tree": tree["sha"],
        "parents": parents,
    })
    print(f"提交创建成功：{commit['sha'][:8]}")

    # 5) 更新引用
    if base_commit_sha:
        api("PATCH", f"/repos/{repo}/git/refs/heads/main", token,
            {"sha": commit["sha"], "force": force})
    else:
        api("POST", f"/repos/{repo}/git/refs", token,
            {"ref": "refs/heads/main", "sha": commit["sha"]})

    print("推送完成")


if __name__ == "__main__":
    main()
