#!/usr/bin/env python3
"""Project the ASR model config (.github/config/asr/models.json) onto the pinned
source manifest (Resources/ASRModels/manifest.json).

2026-10-07 业主指令（config 目录 = .github/config）：
- config 是**唯一手工维护面**（id/variant/许可/revision/watch 规则/版本策略/
  文件布局/pin 值）；源清单是该 config 的**纯投影**（生成物）。
- 验收基准：本生成器对现行 config 的输出与仓库已提交 manifest **逐字节相等**
  （test-asr-config-projection.py 钉死）。
- watch 规则（T3 解析器消费）：hf-repo = HuggingFace 仓库（revision=commit）；
  github-release = GitHub Release 资产（revision=资产文件名内版本段）；
  github-commit = raw.githubusercontent 静态文件（revision=commit）。

URL 文法单源：hf-repo 成员文件的下载 URL 仅在此处合成；显式 url 字段
（次源锁定文件，如各 notice）原样透传。
"""
import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent

CONFIG_DEFAULT = REPO_ROOT / ".github" / "config" / "asr" / "models.json"

WATCH_KINDS = {"hf-repo", "github-release", "github-commit"}


def compose_url(watch, revision, member):
    if watch.get("kind") == "hf-repo":
        return "https://huggingface.co/%s/resolve/%s/%s" % (watch["repo"], revision, member)
    if watch.get("kind") == "github-commit":
        return "https://raw.githubusercontent.com/%s/%s/%s" % (watch["repo"], revision, member)
    raise ValueError("watch kind cannot compose member URLs: " + str(watch.get("kind")))


def _validate_watch(watch, where):
    if not isinstance(watch, dict) or watch.get("kind") not in WATCH_KINDS:
        raise ValueError("entry has no valid watch rule: " + where)
    if watch["kind"] in ("hf-repo", "github-commit") and not watch.get("repo"):
        raise ValueError("watch rule missing repo: " + where)
    if watch["kind"] == "github-release" and not watch.get("asset"):
        raise ValueError("github-release watch missing asset pattern: " + where)


def project_file(entry_watch, revision, item, where):
    if not isinstance(item, dict) or "role" not in item or "path" not in item:
        raise ValueError("file entry is malformed: " + where)
    has_member, has_url = "member" in item, "url" in item
    if has_member == has_url:
        raise ValueError("file must declare exactly one of member/url: " + where)
    url = compose_url(entry_watch, revision, item["member"]) if has_member else item["url"]
    for size_key in ("bytes", "sha256"):
        if not isinstance(item.get(size_key), (int, str)) or item[size_key] in ("", None):
            raise ValueError("file pin is incomplete (%s): %s" % (size_key, where))
    return {"role": item["role"], "path": item["path"],
            "bytes": item["bytes"], "sha256": item["sha256"], "url": url}


def project(config):
    if config.get("formatVersion") != 1:
        raise ValueError("Unsupported config formatVersion")
    manifest = {"formatVersion": config["formatVersion"],
                "bundledModels": config["bundledModels"],
                "models": [], "shared": []}
    for entry in config["models"]:
        where = "%s.%s" % (entry.get("id"), entry.get("variant"))
        _validate_watch(entry.get("watch"), where)
        if "versionPolicy" not in entry:
            raise ValueError("entry missing versionPolicy: " + where)
        model = {"id": entry["id"], "variant": entry.get("variant"),
                 "license": entry["license"], "revision": entry["revision"],
                 "source": entry["source"], "files": []}
        for item in entry.get("files", []):
            model["files"].append(project_file(entry["watch"], entry["revision"], item,
                                               where + "/" + str(item.get("path"))))
        if "archive" in entry:
            archive = entry["archive"]
            model["archive"] = {
                "url": archive["url"], "bytes": archive["bytes"], "sha256": archive["sha256"],
                "root": archive["root"],
                "parts": [{"role": p["role"], "member": p["member"], "path": p["path"]}
                          for p in archive["parts"]]}
        manifest["models"].append(model)
    for shared in config["shared"]:
        where = "shared/" + str(shared.get("path"))
        _validate_watch(shared.get("watch"), where)
        manifest["shared"].append({"role": shared["role"], "path": shared["path"],
                                   "bytes": shared["bytes"], "sha256": shared["sha256"],
                                   "url": shared["url"]})
    return manifest


def manifest_bytes(manifest):
    # 与仓库既有 manifest 完全同形（insertion order + indent=2 + 尾换行），
    # 逐字节复现是 test-asr-config-projection 的验收基准。
    return (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=CONFIG_DEFAULT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path,
                        help="比对模式：生成结果必须与给定文件逐字节相等，否则退出 1")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_bytes())
        data = manifest_bytes(project(config))
        if args.check is not None:
            existing = args.check.read_bytes()
            if existing != data:
                print("ASR-GEN-ERROR: projection differs from " + str(args.check), file=sys.stderr)
                return 1
            print("projection matches " + str(args.check), flush=True)
            return 0
        if args.output is None:
            raise ValueError("--output or --check is required")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        print("source manifest generated: models=%d shared=%d bytes=%d"
              % (len(project(config)["models"]), len(config["shared"]), len(data)), flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("ASR-GEN-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
