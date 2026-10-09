#!/usr/bin/env python3
"""训练链 Release I/O 通道(2026-10-09 CPU 分块链;读取走 api.github.com、写资产走
uploads.github.com——2026-10-08 R0 实证:api 域对资产 POST 结构性 404)。

用法(workflow 内,GITHUB_TOKEN 经 GH_TOKEN 注入):
  python3 gen/release_io.py pick   --release distill-corpus --pattern 'corpus-sha256-.*[.]jsonl$' --out /tmp/target
  python3 gen/release_io.py fetch  --release llama-models --name train-state-train-sft.json --out . --optional
  python3 gen/release_io.py push   --release llama-models --file ckpt/step-0100.pt --draft-ok
  python3 gen/release_io.py latest-run-asset --workflow llm.yml --name corpus-entities --out /tmp     # 兜底通道

设计约束:纯 stdlib(CI 训练 job 只装训练依赖);幂等(同名资产已存在则跳过上传);
draft 释放由本通道按需创建(训练产物 draft 门控,autoPromote=false 纪律)。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

API = "https://api.github.com"
UPLOAD = "https://uploads.github.com"


def _run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def repo() -> str:
    return os.environ.get("GH_REPO") or os.environ["GITHUB_REPOSITORY"]


def _token() -> str:
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not tok:
        raise SystemExit("缺 GH_TOKEN/GITHUB_TOKEN")
    return tok


def list_assets(release: str) -> list[dict]:
    """按 tag 列资产(含 draft)。2026-10-09 实证：by-tag REST 对 **draft** release
    返回 404（llama-models 训练草稿链,`repos/.../releases/tags/llama-models` 404
    而 releases 列表可见）——旧实现致恒空：exists 失明、--replace 删不掉旧同名
    （同名二传 422 翻红）、fetch-ckpt 永不续训。改走 releases 列表过滤（草稿对
    push-access 令牌可见）；repo 级 releases 数远低于 100,单页足够。"""
    r = _run(["gh", "api", f"repos/{repo()}/releases?per_page=100"])
    if r.returncode != 0:
        return []
    try:
        releases = json.loads(r.stdout)
    except ValueError:
        return []
    for rel in releases:
        if rel.get("tag_name") == release:
            return rel.get("assets") or []
    return []


def pick(release: str, pattern: str) -> dict:
    """按正则取最新(created_at 最大)资产。找不到 → 抛。"""
    rx = re.compile(pattern)
    hits = [a for a in list_assets(release) if rx.search(a["name"])]
    if not hits:
        raise SystemExit(f"release {release} 无资产匹配 {pattern}")
    return max(hits, key=lambda a: a["created_at"])


def fetch_asset(release: str, name: str, out_dir: Path, optional: bool = False) -> bool:
    """按资产 id 直取(gh api Accept: octet-stream)。2026-10-09 起不走
    `gh release download`:draft 可见性未知(draft 上 by-tag 404 已实证),
    资产 id 由 list_assets(列表路径,draft 可见)解析,确定性最高。"""
    assets = [a for a in list_assets(release) if a.get("name") == name]
    if not assets:
        if optional:
            print(f"skip(optional): {name}")
            return False
        raise SystemExit(f"下载失败 {release}/{name}: release 列表中不存在该资产")
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / name
    with open(dest, "wb") as fh:
        r = subprocess.run(
            ["gh", "api", f"repos/{repo()}/releases/assets/{assets[0]['id']}",
             "-H", "Accept: application/octet-stream"],
            stdout=fh, stderr=subprocess.PIPE)
    if r.returncode != 0:
        dest.unlink(missing_ok=True)
        if optional:
            print(f"skip(optional): {name}")
            return False
        raise SystemExit(f"下载失败 {release}/{name}: {r.stderr.decode(errors='replace').strip()}")
    return True


def fetch_exit_code(fetched: bool, optional: bool) -> int:
    """fetch 子命令退出码:0=取到;3=optional 跳过;1=硬失败。

    2026-10-09 修(CI 实跑 37858840825):此前 optional 恒 0,workflow 的
    `if fetch --optional`(状态续跑分支)与 `if ! fetch --optional`(实体兜底
    分支)两头皆误——取到/跳过无法区分。跳过与成功必须不同码,条件分支才成立。"""
    if fetched:
        return 0
    return 3 if optional else 1


def ensure_draft(release: str, title: str) -> int:
    """存在(任意态)→ 返回 id;不存在 → 建 draft,返回 id。"""
    r = _run(["gh", "release", "view", release, "-R", repo(), "--json", "databaseId", "--jq", ".databaseId"])
    if r.returncode == 0 and r.stdout.strip() and r.stdout.strip() != "null":
        return int(r.stdout.strip())
    r = _run(["gh", "release", "create", release, "-R", repo(), "--draft",
              "--title", title, "--notes", "训练产物(draft 门控;autoPromote=false 纪律)"])
    if r.returncode != 0:
        # 并发竞态:另一进程已创建 → 重取
        r2 = _run(["gh", "release", "view", release, "-R", repo(), "--json", "databaseId", "--jq", ".databaseId"])
        if r2.returncode == 0 and r2.stdout.strip() != "null":
            return int(r2.stdout.strip())
        raise SystemExit(f"创建 draft 失败: {r.stderr.strip()}")
    return int(_run(["gh", "release", "view", release, "-R", repo(), "--json", "databaseId",
                     "--jq", ".databaseId"]).stdout.strip())


def upload_asset(release: str, file: Path, name: str | None = None, replace: bool = False) -> str:
    """上传;同名已存在:replace=False → skip(内容寻址幂等);replace=True → 删旧同名再传
    (训练状态文件必需:每 chunk 覆盖写)。上传走 uploads.github.com(curl;GH_TOKEN)。"""
    name = name or file.name
    rid = ensure_draft(release, f"{release}(训练产物)")
    existing = {a["name"]: a.get("id") for a in list_assets(release)}
    if name in existing:
        if not replace:
            print(f"skip(已存在): {name}")
            return name
        r = _run(["gh", "api", "-X", "DELETE", f"repos/{repo()}/releases/assets/{existing[name]}"])
        if r.returncode != 0:
            raise SystemExit(f"删旧同名失败 {name}: {r.stderr.strip()}")
        print(f"replaced: {name}")
    # 写前探活(draft 瞬态可见性;2026-10-08 教训:创建后立即写有窗口)
    for i in range(6):
        r = _run(["gh", "api", f"repos/{repo()}/releases/{rid}"])
        if r.returncode == 0:
            break
        print(f"preflight retry {i}")
    r = _run(["curl", "-sS", "--fail-with-body", "-X", "POST",
              "-H", f"Authorization: Bearer {_token()}",
              "-H", "Accept: application/vnd.github+json",
              "-H", "Content-Type: application/octet-stream",
              "--data-binary", f"@{file}",
              f"{UPLOAD}/repos/{repo()}/releases/{rid}/assets?name={name}"])
    if r.returncode != 0:
        raise SystemExit(f"上传失败 {name}: {r.stdout[:300]}")
    print(f"uploaded: {name}")
    return name


def push_checkpoint_set(release: str, prefix: str, ckpt_dir: Path) -> list[str]:
    """上传 checkpoint 三件(ckpt/pointer/sidecar;名带 task 前缀防跨任务碰撞)。"""
    uploaded = []
    ptr = ckpt_dir / "checkpoint-latest.json"
    if not ptr.is_file():
        raise SystemExit(f"缺 checkpoint-latest.json: {ckpt_dir}")
    pointer = json.loads(ptr.read_text(encoding="utf-8"))
    ckpt_name = pointer.get("path") or pointer.get("checkpoint") or ""
    ckpt_path = ckpt_dir / Path(ckpt_name).name
    for f, name in ((ckpt_path, f"{prefix}-{ckpt_path.name}"),
                    (ckpt_dir / f"{ckpt_path.name}.sha256", f"{prefix}-{ckpt_path.name}.sha256"),
                    (ptr, f"{prefix}-checkpoint-latest.json")):
        if not f.is_file():
            raise SystemExit(f"checkpoint 件缺失: {f}")
        uploaded.append(upload_asset(release, f, name))
    return uploaded


def fetch_checkpoint_set(release: str, prefix: str, out_dir: Path) -> bool:
    """取回最新三件并还原为训练器期望命名(checkpoint-latest.json + ckpt + sidecar)。"""
    assets = list_assets(release)
    cks = [a for a in assets if re.match(rf"^{re.escape(prefix)}-ckpt-.*\.pt$", a["name"])]
    if not cks:
        return False
    newest = max(cks, key=lambda a: a["created_at"]).get("created_at")
    newest_name = max(cks, key=lambda a: a["created_at"])["name"]
    base = newest_name[len(prefix) + 1:]
    out_dir.mkdir(parents=True, exist_ok=True)
    for remote, local in ((newest_name, base),
                          (f"{prefix}-{base}.sha256", f"{base}.sha256"),
                          (f"{prefix}-checkpoint-latest.json", "checkpoint-latest.json")):
        if not fetch_asset(release, remote, out_dir, optional=(not remote.endswith(base))):
            if remote == newest_name:
                return False
    return True


def latest_run_asset(workflow: str, name: str, out_dir: Path) -> bool:
    """兜底通道:从最近一次成功 run 的 artifact 取(Release 未含该件时;
    先例:corpus-entities)。"""
    r = _run(["gh", "run", "list", "--workflow", workflow, "-R", repo(),
              "--status", "success", "--limit", "5", "--json", "databaseId"])
    if r.returncode != 0 or not json.loads(r.stdout or "[]"):
        return False
    for run in json.loads(r.stdout):
        rr = _run(["gh", "run", "download", str(run["databaseId"]), "-R", repo(),
                   "-n", name, "-D", str(out_dir)])
        if rr.returncode == 0:
            print(f"artifact {name} ← run {run['databaseId']}")
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("pick")
    p1.add_argument("--release", required=True)
    p1.add_argument("--pattern", required=True)
    p1.add_argument("--out", type=Path, required=True, help="写入 name\\tsize 单行")

    p2 = sub.add_parser("fetch")
    p2.add_argument("--release", required=True)
    p2.add_argument("--name", required=True)
    p2.add_argument("--out", type=Path, required=True)
    p2.add_argument("--optional", action="store_true",
                    help="缺件不硬错;退出码 3=跳过(供 workflow 条件分支区分)")

    p3 = sub.add_parser("push")
    p3.add_argument("--release", required=True)
    p3.add_argument("--file", type=Path, required=True)
    p3.add_argument("--name", default=None)
    p3.add_argument("--draft-ok", action="store_true")
    p3.add_argument("--replace", action="store_true", help="同名覆盖写(训练状态文件必需)")

    p5 = sub.add_parser("push-ckpt")
    p5.add_argument("--release", required=True)
    p5.add_argument("--prefix", required=True)
    p5.add_argument("--dir", type=Path, required=True)

    p6 = sub.add_parser("fetch-ckpt")
    p6.add_argument("--release", required=True)
    p6.add_argument("--prefix", required=True)
    p6.add_argument("--out", type=Path, required=True)

    p4 = sub.add_parser("latest-run-asset")
    p4.add_argument("--workflow", required=True)
    p4.add_argument("--name", required=True)
    p4.add_argument("--out", type=Path, required=True)

    args = parser.parse_args()
    if args.cmd == "pick":
        a = pick(args.release, args.pattern)
        args.out.write_text(f"{a['name']}\t{a['size']}\n", encoding="utf-8")
        print(a["name"])
    elif args.cmd == "fetch":
        ok = fetch_asset(args.release, args.name, args.out, optional=args.optional)
        return fetch_exit_code(ok, args.optional)
    elif args.cmd == "push":
        upload_asset(args.release, args.file, args.name, replace=args.replace)
    elif args.cmd == "push-ckpt":
        push_checkpoint_set(args.release, args.prefix, args.dir)
    elif args.cmd == "fetch-ckpt":
        return 0 if fetch_checkpoint_set(args.release, args.prefix, args.out) else 1
    elif args.cmd == "latest-run-asset":
        ok = latest_run_asset(args.workflow, args.name, args.out)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
