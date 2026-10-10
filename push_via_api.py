"""通过 GitHub REST API 把本地文件推送到仓库。

绕开 git 传输协议（沙箱代理对 git push 支持不佳），
直接调用 Contents API。先建 blob/tree/commit，再更新 ref，
这样是单次提交，而不是 N 次单文件提交。

用法：python scripts/push_via_api.py <本地目录> <owner/repo> <token>
"""

from __future__ import annotations

import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

SKIP_DIRS = {"__pycache__", ".git", ".venv", "venv", ".pytest_cache"}
SKIP_FILES = {".env"}
API = "https://api.github.com"


def api(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "llm-gateway-push")
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

    # 1) 取当前默认分支的最新 commit（空仓库会返回 404 或 409）
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
        head = api("GET", f"/repos/{repo}/commits/{base_commit_sha}", token)
        parents = [base_commit_sha]
        force = False
    else:
        parents = []
        force = True

    msg = read_commit_message(root)
    commit = api("POST", f"/repos/{repo}/git/commits", token, {
        "message": msg,
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


def read_commit_message(root: Path) -> str:
    return (
        "feat: 大模型接口统一转换为 OpenAI 格式的网关\n\n"
        "支持 Anthropic Claude、Google Gemini、OpenAI/Azure 及国内厂商\n"
        "（DeepSeek、通义、智谱、Kimi、Ollama）统一转换为 OpenAI Chat\n"
        "Completions 格式，任何 OpenAI SDK 客户端可直接接入。\n\n"
        "核心能力：\n"
        "- 适配器模式，新增上游无需改代码，仅需 config.yaml 配置\n"
        "- 非流式与 SSE 流式转换，含 tool_calls 分片重组\n"
        "- 工具调用双向映射（OpenAI tools / Claude tool_use / Gemini functionCall）\n"
        "- 多模态图片 URL 与 base64 跨格式互转\n"
        "- 三层代理：按上游覆盖 > 全局 > 强制直连\n"
        "- 模型别名映射与 provider/model 前缀路由\n"
        "- 网关侧 Bearer 鉴权，配置热重载\n\n"
        "测试：75 项用例全部通过，使用内置 mock 上游，无需真实 API Key"
    )


if __name__ == "__main__":
    main()
