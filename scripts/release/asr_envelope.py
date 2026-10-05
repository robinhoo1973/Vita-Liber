"""ASR 下载包加密信封(2026-10-05 业主 R1:包必须加密+压缩;R2:同内容哈希比对)。

格式(与 App 侧 CoreKit `ASRPackageCrypto` 逐字节对齐):
  头:magic "VLASR\\x01"(6) + u8 version=1 + u32 BE chunk_size + u64 BE plaintext_size + u32 BE chunk_count
  每块:u32 BE ciphertext_len + (ct + tag16)——nonce 由块序号经 HKDF 派生,
  **不入帧**(2026-10-05 审查修正:旧 docstring 声称帧内含 nonce12,与两侧实现均不符)。

密钥/随机数派生(确定性——同内容同信封字节,R2 哈希比对成立;AES-GCM 安全
——密钥按包身份派生,不同包不同密钥;nonce 按块序号派生,同密钥下永不重放):
  key     = HKDF-SHA256(master, info="vitaliber/asr/aes256gcm/v1/key/" + identity, len=32)
  nonce_i = HKDF-SHA256(master, info="vitaliber/asr/aes256gcm/v1/nonce/" + identity + "/" + i, len=12)
  AAD_i   = header + u32 BE i

nonce 派生长度合同(2026-10-05 审查定稿):python 侧直接派生 12 字节;
Swift 侧因工具链约束派生 32 字节取前 12——HKDF 前缀性质(RFC 5869)保证
两者逐字节相同,任何一侧改动派生长度/盐值/信息串即破坏互解。

主密钥经 env `ASR_PACKAGE_KEY`(64 hex)注入;需要加解密处缺密钥 = 硬错
(发布未经加密即违反 R1,绝不静默发明文包)。主密钥与 App 内嵌常量同值,
轮换时两处同步更新(test-asr-package-integrity.py 断言一致)。
"""
import hashlib
import os
import re
import struct
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

ENCRYPTION_SCHEME = "aes256gcm-v1"
MAGIC = b"VLASR\x01"
VERSION = 1
CHUNK_SIZE = 64 * 1024 * 1024
MAX_CHUNK_COUNT = 512
HEADER = struct.Struct(">6sBIQI")  # magic, u8 version, u32 chunk_size, u64 plaintext_size, u32 chunk_count
FRAME = struct.Struct(">I")        # u32 ciphertext_len
TAG_LEN = 16


def identity_string(model_id, variant, version, artifact_revision=None):
    """包身份 = (id, variant, version, artifactRevision)——与 validate_index 的
    身份键同源。artifactRevision 必须进身份:GCM 密钥/nonce 由身份派生,
    同版本号换内容(r2→r3)若沿用同一身份 = 同密钥同 nonce 序列加密不同
    明文 = nonce 重放灾难(2026-10-05 扫尾审查)。"""
    revision = f"-r{artifact_revision}" if artifact_revision is not None else ""
    return f"{model_id}-{variant or ''}-{version}{revision}"


def _hkdf(master, info, length):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=None, info=info).derive(master)


def _key(master, identity):
    return _hkdf(master, b"vitaliber/asr/aes256gcm/v1/key/" + identity.encode(), 32)


def _nonce(master, identity, index):
    return _hkdf(master, b"vitaliber/asr/aes256gcm/v1/nonce/" + identity.encode() + b"/" + str(index).encode(), 12)


def env_package_key():
    """主密钥只从环境读取(与 CI secret 同源);缺失即硬错——绝不静默发明文包。"""
    raw = os.environ.get("ASR_PACKAGE_KEY", "")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", raw):
        raise ValueError("ASR_PACKAGE_KEY must be a 64-hex (32-byte) secret in the environment")
    return bytes.fromhex(raw)


def is_envelope_prefix(prefix):
    return len(prefix) >= len(MAGIC) and prefix[: len(MAGIC)] == MAGIC


def is_envelope_file(path):
    with open(path, "rb") as stream:
        return is_envelope_prefix(stream.read(len(MAGIC)))


def encrypt_package(master, identity, source, destination):
    aead = AESGCM(_key(master, identity))
    size = Path(source).stat().st_size
    chunk_count = (size + CHUNK_SIZE - 1) // CHUNK_SIZE if size else 1
    if chunk_count > MAX_CHUNK_COUNT:
        raise ValueError("Package envelope exceeds the chunk budget")
    header = HEADER.pack(MAGIC, VERSION, CHUNK_SIZE, size, chunk_count)
    with open(source, "rb") as reader, open(destination, "wb") as writer:
        writer.write(header)
        for index in range(chunk_count):
            data = reader.read(CHUNK_SIZE)
            ciphertext = aead.encrypt(_nonce(master, identity, index), data, header + struct.pack(">I", index))
            writer.write(FRAME.pack(len(ciphertext)))
            writer.write(ciphertext)
    return destination


def decrypt_package(master, identity, source, destination):
    with open(source, "rb") as reader:
        header = reader.read(HEADER.size)
        if len(header) != HEADER.size:
            raise ValueError("Truncated package envelope")
        magic, version, chunk_size, plaintext_size, chunk_count = HEADER.unpack(header)
        if magic != MAGIC or version != VERSION:
            raise ValueError("Unsupported package envelope")
        if not 0 < chunk_size <= 256 * 1024 * 1024 or not 0 < chunk_count <= MAX_CHUNK_COUNT:
            raise ValueError("Invalid package envelope header")
        aead = AESGCM(_key(master, identity))
        total = 0
        with open(destination, "wb") as writer:
            for index in range(chunk_count):
                frame = reader.read(FRAME.size)
                if len(frame) != FRAME.size:
                    raise ValueError("Truncated package envelope")
                (cipher_len,) = FRAME.unpack(frame)
                if not 1 <= cipher_len <= chunk_size + 12 + TAG_LEN:
                    raise ValueError("Invalid package envelope chunk length")
                ciphertext = reader.read(cipher_len)
                if len(ciphertext) != cipher_len:
                    raise ValueError("Truncated package envelope")
                try:
                    plain = aead.decrypt(_nonce(master, identity, index), ciphertext,
                                         header + struct.pack(">I", index))
                except InvalidTag as error:
                    raise ValueError("Package envelope authentication failed") from error
                writer.write(plain)
                total += len(plain)
        if reader.read(1):
            raise ValueError("Package envelope has trailing bytes")
        if total != plaintext_size:
            raise ValueError("Package envelope size mismatch")
    return destination
