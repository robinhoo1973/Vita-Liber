#!/usr/bin/env python3
"""ASR CI 密钥引导(2026-10-05 业主指令):secret `ASR_PACKAGE_KEY` 不存在时,
CI 自动生成 32 字节主密钥并三处同步落地——GitHub Actions secret、
App 内嵌 `ASRPackageCrypto.masterKeyHex`、
`test-asr-package-integrity.TEST_PACKAGE_KEY`——
生成值写 `--key-out`(0600),由 workflow add-mask 后注入本 run 环境。

安全语义(fail-closed):
- secret 已存在(env ASR_PACKAGE_KEY 非空):只校验 64-hex 格式与两处内嵌值
  一致;不一致 = 硬错(发布 App 解不开的包比红更糟)。绝不读取/改写 secret
  值——有意轮换必须先删除 secret 再重跑本脚本。
- secret 不存在 + 无 ASR_ADMIN_TOKEN(gh 无管理凭据):硬错并打印引导步骤。
- secret 不存在 + 有 token:生成、改写两处源码、`gh secret set`(值走 stdin
  不落 argv),再由 workflow 的 git 步骤把源码改动写回仓库(本脚本不 commit)。

轮换语义:删除 secret 后重跑 = 新密钥;旧密钥加密的已发布包全部不可解,
必须随后全量重发布(新目录版本 + 全部包重加密)。
"""
import argparse
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path

SECRET_NAME = "ASR_PACKAGE_KEY"
KEY_RE = re.compile(r"[0-9a-fA-F]{64}\Z")
SWIFT_KEY_RE = re.compile(r'(masterKeyHex\s*=\s*)"([0-9a-fA-F]{64})"')
TEST_KEY_RE = re.compile(r'(TEST_PACKAGE_KEY\s*=\s*)"([0-9a-fA-F]{64})"')


def generate_key() -> str:
    """32 字节 CSPRNG 主密钥(64 hex;与 asr_envelope.env_package_key 合同一致)。"""
    return secrets.token_hex(32)


def read_swift_key(path):
    """App 内嵌 masterKeyHex(小写);文件缺失或无匹配返回 None。"""
    try:
        match = SWIFT_KEY_RE.search(Path(path).read_text(encoding="utf-8"))
    except OSError:
        return None
    return match.group(2).lower() if match else None


def read_test_key(path):
    """测试常量 TEST_PACKAGE_KEY(小写);文件缺失或无匹配返回 None。"""
    try:
        match = TEST_KEY_RE.search(Path(path).read_text(encoding="utf-8"))
    except OSError:
        return None
    return match.group(2).lower() if match else None


def rewrite_embedded_key(swift_path, test_path, key):
    """把两处内嵌密钥常量改写为新值;返回被改写文件路径列表。

    只替换 64-hex 字面量,其余字节不动;任一文件找不到常量 = ValueError
    (绝不带着半边改写的源码继续)。
    """
    changed = []
    for path, pattern in ((Path(swift_path), SWIFT_KEY_RE), (Path(test_path), TEST_KEY_RE)):
        text = path.read_text(encoding="utf-8")
        if pattern.search(text) is None:
            raise ValueError(f"{path}: embedded key constant not found")
        updated = pattern.sub(lambda m: f'{m.group(1)}"{key}"', text)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed.append(str(path))
    return changed


def parse_secret_names(text):
    """gh secret list 纯文本输出 → 名字集合(第一列;表头 NAME 与空行跳过)。"""
    names = set()
    for line in text.splitlines():
        fields = line.split()
        if fields and fields[0] != "NAME":
            names.add(fields[0])
    return names


def secret_exists(repo, admin_token=None):
    """经 gh 查询 repo 的 actions secret 是否存在(失败 = 硬错,不静默假设缺失)。"""
    env = dict(os.environ)
    if admin_token:
        env["GH_TOKEN"] = admin_token
    result = subprocess.run(["gh", "secret", "list", "-R", repo],
                            capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"gh secret list failed: {result.stderr.strip()}")
    return SECRET_NAME in parse_secret_names(result.stdout)


def store_secret(repo, key, admin_token=None):
    """注册/更新 secret:值走 stdin 不进 argv/日志;gh 负责公钥加密上传。"""
    env = dict(os.environ)
    if admin_token:
        env["GH_TOKEN"] = admin_token
    result = subprocess.run(["gh", "secret", "set", SECRET_NAME, "-R", repo],
                            input=key, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"gh secret set failed: {result.stderr.strip()}")
    # 回读核对(发布面纪律):注册后必须可枚举,否则后续 run 永远拿不到注入值。
    if not secret_exists(repo, admin_token):
        raise RuntimeError(f"{SECRET_NAME} was stored but is not visible via gh secret list")


def gh_authenticated():
    """本地/CI gh 凭据可用性(ASR_ADMIN_TOKEN 之外的第二条管理通道)。"""
    return subprocess.run(["gh", "auth", "status", "-h", "github.com"],
                          capture_output=True).returncode == 0


def plan(env_key, can_manage_secrets, swift_key, test_key):
    """纯决策函数(可测):返回 (action, message);action ∈ {noop, generate, fail}。

    can_manage_secrets = ASR_ADMIN_TOKEN 已注入(CI)或本地 gh 已登录(owner 手工引导)。
    """
    if env_key:
        if not KEY_RE.match(env_key.strip()):
            return "fail", ("ASR_PACKAGE_KEY env 不是 64-hex 主密钥——检查 secret 值是否被截断/污染")
        if swift_key is None or test_key is None:
            return "fail", ("ASR_PACKAGE_KEY secret 已存在,但内嵌密钥常量缺失(源码被改坏)——"
                            "恢复 ASRPackageCrypto.masterKeyHex / TEST_PACKAGE_KEY 声明")
        if swift_key != env_key.lower() or test_key != env_key.lower():
            return "fail", ("ASR_PACKAGE_KEY secret 与内嵌密钥不一致(轮换漏改一侧,新包在设备上"
                            "全部解密失败)。若 secret 为误建:删除后重跑本 workflow 自动对齐;"
                            "若为有意轮换:删除 secret 后重跑(旧包不可解,须随后全量重发布)")
        return "noop", "ASR_PACKAGE_KEY 已存在且与内嵌密钥一致——跳过"
    if not can_manage_secrets:
        return "fail", ("ASR_PACKAGE_KEY secret 不存在,且无可管理凭据(无 ASR_ADMIN_TOKEN 且本地"
                        "gh 未登录)——无法自动生成。引导:1) 创建具有 Actions secrets 读写权限的"
                        "PAT 并注册为 secret ASR_ADMIN_TOKEN,重跑本 workflow;或 2) 本地"
                        "gh auth login 后执行 python3 scripts/release/init_asr_secrets.py --repo <owner/repo>")
    return "generate", "ASR_PACKAGE_KEY secret 不存在——自动生成并三处落地"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""),
                        help="OWNER/REPO(缺省取 GITHUB_REPOSITORY)")
    parser.add_argument("--swift-file", default="CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift")
    parser.add_argument("--test-file", default="scripts/release/test-asr-package-integrity.py")
    parser.add_argument("--key-out", default=None,
                        help="生成密钥落盘路径(0600;不传则不落盘)")
    args = parser.parse_args()

    env_key = os.environ.get(SECRET_NAME, "")
    admin_token = os.environ.get("ASR_ADMIN_TOKEN", "")
    can_manage = bool(admin_token) or gh_authenticated()
    action, message = plan(env_key, can_manage,
                           read_swift_key(args.swift_file), read_test_key(args.test_file))
    if action == "noop":
        print(message)
        return 0
    if action == "fail":
        print(f"::error::{message}", file=sys.stderr)
        return 1

    if not args.repo:
        print("::error::--repo 未提供且 GITHUB_REPOSITORY 缺失", file=sys.stderr)
        return 1
    if secret_exists(args.repo, admin_token):
        print("::error::ASR_PACKAGE_KEY secret 已存在但 env 未注入——workflow 的 job env 未引用"
              " secrets.ASR_PACKAGE_KEY(接线断,与 secret 缺失不可区分前绝不生成)", file=sys.stderr)
        return 1

    key = generate_key()
    # 顺序:先落源码/落盘,最后注册 secret——中途失败时不残留「secret 已建但源码未改」的半边状态。
    changed = rewrite_embedded_key(args.swift_file, args.test_file, key)
    if args.key_out:
        fd = os.open(args.key_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(key)
    store_secret(args.repo, key, admin_token)
    print(f"{SECRET_NAME} 已生成并注册为 GitHub Actions secret;"
          f"内嵌密钥已改写: {', '.join(changed)};workflow 将写回提交")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
