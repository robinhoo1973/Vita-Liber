"""共享签名助手(2026-10-05 审查收敛):envelope 构造与密钥身份合同的单一实现。

sign-asr-catalog.py / generate-asr-signing-keys.py / test-model-trust.py 曾各自
复制 `b64`/`key_id`/`sign_envelope`,且两家生产脚本已出现两种不同的 payload
规范化形态(json_bytes 缩进 vs 紧凑 separators)——签名字节即信任字节,合同
必须单一出口。模型见 model_trust.py 的 verify_envelope/key 身份断言。
"""
import base64
import hashlib

from asr_package import json_bytes


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def key_id(public_key: bytes) -> str:
    """密钥身份 = sha256(32 字节原始公钥)hex——与 model_trust.validate_root 断言同源。"""
    return hashlib.sha256(public_key).hexdigest()


def sign_envelope(payload: dict, signers) -> dict:
    """签名目录/信任根 envelope:payload 走 asr_package.json_bytes 单一规范化。"""
    raw = json_bytes(payload)
    return {
        "payload": b64(raw),
        "signatures": [{"keyId": identity, "signature": b64(key.sign(raw))}
                       for identity, key in signers],
    }
