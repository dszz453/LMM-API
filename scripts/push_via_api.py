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

COMMIT_MESSAGE = """feat: 支持通过环境变量配置初始管理员与访问地址

上游 MIXAPI 源码里没有任何初始化账号相关的环境变量，
本次在镜像内包一层入口脚本实现该能力。

新增 docker-entrypoint.sh：
  容器启动后自动完成初始化，无需手工调接口或跑脚本。
  1. 后台拉起原程序，轮询 /api/status 等待就绪
  2. 调 /api/setup 查状态，未初始化则用环境变量建管理员
  3. 比对 server_address 与 SERVER_ADDRESS，不一致则写
     SQLite 的 options 表并重启主程序（不重启容器）
  4. 转入前台守护，主程序退出则容器退出

支持的环境变量：
  INIT_ROOT_USER       初始管理员用户名（默认 root）
  INIT_ROOT_PASSWORD   初始管理员密码（不填则不自动建号）
  SERVER_ADDRESS       对外访问地址（填了自动写库生效）
  INIT_AUTO_SETUP      auto / force / off，默认 auto

特性：
- 幂等：管理员已存在时不重复创建，不覆盖密码
- 不用 python：镜像内装 sqlite CLI，改地址走本地命令
- 两个 Dockerfile 均改用 ENTRYPOINT 并安装 sqlite
- healthcheck start_period 由 20s 调至 30s，给初始化留时间

配置方式：
- 新增 .env.example 模板，compose 用 ${VAR:-default} 读取
- .env 已加入 .gitignore/.dockerignore，密码不进仓库

实测验证（192.168.31.180）：
- 全新环境 docker compose up -d 后自动建号 + 修地址，零手工
- 登录用环境变量里的凭据成功，role=100
- 重启容器：正确跳过创建，提示「系统已初始化」
- 账号未被破坏，信号处理正常

新增 scripts/test-env-init.sh 用于回归测试该能力。
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
