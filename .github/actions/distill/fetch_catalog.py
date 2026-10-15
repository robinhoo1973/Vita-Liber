#!/usr/bin/env python3
"""医疗目录资产获取器:CNB Release → 验签指针 → 下载密文 → 信封解密 → 目录 SQLite。

数据纪律(2026-10-07 三域对齐裁决 + 计划文档 §7.6;同日 v3 协议对齐):
- 医疗数据**唯一发布位置** = CNB `robinhoo1973/Resources` release tag `medical-data`
  (本地生产者是唯一写者;源站 WAF 拒云上出口 IP,CI 永不直连源站)。
- **v3 资产文法**(生产端 names.go 白名单逐字对齐,2026-10-07 业主裁决):
  `manifest.json`(签名信封=指针,固定名,最后上传=提交点)/ `overview.json`(固定名,
  展示件可短暂缺席)/ `package-<catalogVersion>.bin`(append-only)。v2 旧名已删,
  **无双重文法**——本脚本不做旧名回退,缺固定名即响亮失败(防静默吃旧资产)。
- 匿名通道:tag 页 SSR(`__NEXT_DATA__`)做资产发现,`/-/releases/download/` 做下载。
  两条通道与 App 侧解析器同源(.github/actions/release/cnb_read.py,路径加载,零复刻;
  2026-10-08 换源:该实现自 prepare-asr-source.py 收敛进 cnb_read.py,见下方 _cnb_read)。
- 包为 AES-256-GCM 分块信封(与 ASR 同构,.github/actions/release/asr_envelope.py 正本)。
  identity = 验签指针里的 sqliteSha256(也是包名第一段);master = App 内嵌公开常量
  (ASRPackageCrypto.masterKeyHex,CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift)。
  **非秘密**——该钥匙随 App 二进制公开;此处不经任何 secret 注入。
- 全部校验 fail-closed:**Ed25519 信任根**(2-of-2 自签,随部署投放的 `pinned-root.json`,
  永不从网络取根)→ **指针验签**(catalog 2-of-2,只对 payload 原始字节,绝不重序列化)
  → 指针字段/时间窗/rootVersion → 资产哈希 → 密文 SHA-256 → 信封 GCM tag →
  内层 SQLite SHA-256,任一层不符即拒绝产出(绝不落半成品)。信任根未配置时默认**拒**;
  过渡期可显式 `--allow-unsigned` 跳过验签(红字警示,见 `verify_catalog_pointer`)。

用法:
  python3 .github/actions/distill/fetch_catalog.py --out-dir corpus-assets
  python3 .github/actions/distill/fetch_catalog.py --local-sqlite /path/catalog.sqlite --out-dir corpus-assets  # 开发旁路
  python3 .github/actions/distill/fetch_catalog.py --release-dir /path/scripts/exchange --out-dir catalog  # 训练机 staged 树

信任根(2026-10-11 验签修复批;同日根投放批):
  - 解析顺序:--trust-root > env VITALIBER_MEDICAL_TRUST_ROOT > 本脚本同目录 pinned-root.json。
    生产根文件出处 = 发布方 provision 产物(`MEDICAL_DATA_TRUST_ROOT_JSON` secret 的值,
    与 App 归档注入的医疗信任根同源);公开信封(仅公钥+自签,非秘密),**三处逐字节同源
    投放**:CI 仓本脚本同目录、训练载荷 `scripts/exchange/`(template 打底随 deploy 落位)、
    发布方 provision 源。测试夹具 `Fixtures/medical/pinned-root.json` 是 **TEST-ONLY**
    材料(私钥公开),严禁与生产根混用/替换部署。
  - 缺根/无签名默认拒(「指针验签失败:…——拒绝」);`--allow-unsigned` = 仅豁免
    「验签能力缺失」(缺根或无签名)的过渡逃生门,放行时打印红字;**验签失败本身
    (篡改/阈值不足/过期/范围不符/根损坏)不被豁免**。信任根就绪后移除该旗标。

可移植覆盖(2026-10-09 W11,训练机 CNB 直取批):训练机没有 CoreKit 树,本脚本对
release 簇(cnb_read/cnb_release/asr_envelope)的路径加载改由 `--release-dir` 或
env `VITALIBER_RELEASE_DIR` 指定**同一目录**内三件套(单源纪律:仍是路径加载同名
正本文件,零复刻实现)。未提供时逐字保持 CI 行为(上溯 CoreKit 锚点 →
.github/actions/release)。三件套自身无 CoreKit/仓内锚点(2026-10-09 核实:
asr_envelope 自含、cnb_read 仅同目录 import cnb_release、cnb_release 仅以自身
`__file__` 定位 cnb-release-notes/),故 staged 目录整包拷走即自洽。
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import http.client
import importlib.util
import json
import os
import re
import shutil
import stat
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from catalog_contract import (MAX_SQLITE_BYTES, SQLITE_ENTRY_NAME, SUPPORTED_SCHEMAS,
                              sha256_file, validate_sqlite)


def _default_release_dir() -> Path:
    """CI 仓内默认:.github/actions/release(逐级上溯 CoreKit 锚点;禁 parents[N])。"""
    root = Path(__file__).resolve().parent
    while root != root.parent and not (root / "CoreKit" / "Sources" / "Domain").is_dir():
        root = root.parent
    return root / ".github" / "actions" / "release"


RELEASE_DIR = _default_release_dir()

# 覆盖目录最小契约:三件套必须共处一目录(路径加载按名查找,缺一即硬错)。
RELEASE_DIR_REQUIRED = ("cnb_read.py", "cnb_release.py", "asr_envelope.py")


def apply_release_dir_override(path) -> None:
    """应用 release 簇目录覆盖(训练机 staged 树;校验三件套齐全后生效)。

    fail-closed:缺件立即抛 ValueError(而不是首次下载时才 AttributeError/FileNotFoundError)。
    """
    global RELEASE_DIR, _CNB_READ_MODULE
    resolved = Path(path).expanduser().resolve()
    missing = [name for name in RELEASE_DIR_REQUIRED if not (resolved / name).is_file()]
    if missing:
        raise ValueError(f"release-dir 覆盖目录缺件 {', '.join(missing)}: {resolved}")
    RELEASE_DIR = resolved
    _CNB_READ_MODULE = None

# .github/actions/release 的解析器/信封实现按需加载(与 probe_cnb_resources.py 同一路径加载法):
# 模块顶层保持 stdlib——零依赖测试闸可直接 import 本模块;信封路径(需 cryptography)
# 只在真正下载/解密时加载,缺依赖时报错信息落在使用点上。
_CNB_READ_MODULE = None


def _cnb_read():
    """路径加载 release 簇的 CNB 匿名读实现(cnb_read.py——单一事实源,零复刻)。

    2026-10-08 修复:此前加载 prepare-asr-source.py 的 parse_cnb_tag_page,而 master
    四文件化把该函数收敛进 cnb_read.py(旧文件只剩兼容壳)——跨簇路径加载耦合到
    函数名,单侧重构即断,首跑 CI 37709201847 实证 AttributeError。
    加载后显式断言函数存在:漂移时响亮失败并指明契约,不得静默 AttributeError。
    """
    global _CNB_READ_MODULE
    if _CNB_READ_MODULE is None:
        if str(RELEASE_DIR) not in sys.path:
            sys.path.insert(0, str(RELEASE_DIR))
        spec = importlib.util.spec_from_file_location("cnb_read", RELEASE_DIR / "cnb_read.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if not hasattr(module, "parse_cnb_tag_page"):
            raise RuntimeError(
                f"跨簇 API 漂移: {RELEASE_DIR / 'cnb_read.py'} 缺 parse_cnb_tag_page——"
                "distill 簇的路径加载契约须随 release 簇重构同步(见 .github/workflows/README.md 簇内耦合规则)")
        _CNB_READ_MODULE = module
    return _CNB_READ_MODULE


DEFAULT_REPOSITORY = "robinhoo1973/Resources"
DEFAULT_TAG = "medical-data"
UA = "vitaliber-distill-catalog/1"
MAX_PAGE_BYTES = 8 << 20           # 与 release 侧解析器同界(SSR 页上限)
MAX_ASSET_BYTES = 1 << 30          # 单资产上限 1 GiB(包 287MB 量级;防失控资产打爆 runner 盘)
DOWNLOAD_ATTEMPTS = 3

# App 内嵌公开包钥(与 CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift:33 同值;
# test_fetch_catalog.py 逐字对齐断言——两处漂移即测试红)。公开、非秘密。
MEDICAL_PACKAGE_KEY_HEX = "2303fac4e6aaacc328f6ac612f77fa91c32594f9c627aab2178b19486ebe7e82"

# v3 资产文法(生产端 names.go 白名单逐字对齐):固定名指针/概览 + package-<版本>.bin。
MANIFEST_ASSET_NAME = "manifest.json"
OVERVIEW_ASSET_NAME = "overview.json"
_PACKAGE_NAME = re.compile(r"^package-([1-9][0-9]{0,18})\.bin$")
_INT64_MAX = (1 << 63) - 1


def _urlopen(url: str, timeout: int):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(request, timeout=timeout)


def fetch_tag_page(repository: str, tag: str) -> bytes:
    url = f"https://cnb.cool/{repository}/-/releases/tag/{tag}"
    last: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with _urlopen(url, timeout=120) as resp:
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status}")
                return resp.read(MAX_PAGE_BYTES + 1)
        except (OSError, urllib.error.URLError, http.client.HTTPException) as exc:
            # C3 修复（三轮核验，同族）：BadStatusLine/ResponseNotReady 等 http.client.HTTPException
            # 不是 OSError 子类——CDN 边缘畸形状态行原先一次即穿（零重试、整轮 fetch 中止）。
            last = exc
            if attempt < DOWNLOAD_ATTEMPTS:
                time.sleep(attempt * 3)
    raise OSError(f"CNB tag 页拉取失败: {url}: {last}")


def _public_download_url(repository: str, tag: str, name: str) -> str:
    if str(RELEASE_DIR) not in sys.path:
        sys.path.insert(0, str(RELEASE_DIR))
    from cnb_release import public_download_url  # 延迟加载:顶层保持 stdlib
    return public_download_url(repository, tag, name)


class TransferIncomplete(ValueError):
    """截断/超长/半途断流(瞬态,可重试)——与「内容不符」(digest 不符,长期性)分型(E7 同族)。

    消费面=download_asset 的重试集合;内容不符立即硬错,不把一次发布缺陷伪装成网络抖动。"""


def download_asset(repository: str, tag: str, asset: dict, dest: Path) -> None:
    """流式下载 + 单趟哈希(**先校验后消费**;坏下载绝不落终名)。

    E7 分型:尺寸不符/传输截断 = TransferIncomplete(退避重试);digest 不符 = 立即硬错。"""
    url = _public_download_url(repository, tag, asset["name"])
    expected_sha = asset["hashValue"]
    expected_size = asset["sizeInByte"]
    if expected_size > MAX_ASSET_BYTES:
        raise ValueError(f"资产超出上限({expected_size} > {MAX_ASSET_BYTES}): {asset['name']}")
    temporary = dest.with_suffix(dest.suffix + ".downloading")
    last: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        digest = hashlib.sha256()
        received = 0
        try:
            with _urlopen(url, timeout=600) as resp, open(temporary, "wb") as fh:
                while True:
                    try:
                        chunk = resp.read(1 << 20)
                    except http.client.IncompleteRead as exc:
                        raise TransferIncomplete(f"传输截断: {asset['name']}") from exc
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > expected_size:
                        raise TransferIncomplete(f"下载超出声明大小: {asset['name']}")
                    digest.update(chunk)
                    fh.write(chunk)
            if received != expected_size:
                raise TransferIncomplete(f"大小不符: {asset['name']}(声明 {expected_size},实收 {received})")
            actual = digest.hexdigest()
            if actual != expected_sha:
                # E4 修复:同函数其余三个失败分支都清 .downloading 临时件,唯独本分支直穿 —
                # 篡改/发布缺陷场景会留下未核验字节(消费者按存在性取件=吃半成品)。
                temporary.unlink(missing_ok=True)
                raise ValueError(f"哈希不符: {asset['name']}(声明 {expected_sha},实测 {actual})"
                                 "——内容不符属长期性错误,不重试(先查发布端)")
            temporary.replace(dest)
            return
        except TransferIncomplete as exc:
            temporary.unlink(missing_ok=True)
            last = exc
            if attempt < DOWNLOAD_ATTEMPTS:
                print(f"下载截断(第 {attempt}/{DOWNLOAD_ATTEMPTS} 次,按瞬态重试): {asset['name']}: {exc}——"
                      f"退避 {attempt * 5}s 后重试", file=sys.stderr)
                time.sleep(attempt * 5)
        except (OSError, urllib.error.URLError, http.client.HTTPException) as exc:
            # C3 修复（三轮核验，同族）：http.client.HTTPException（BadStatusLine 等）非 OSError
            # 子类——畸形状态行原先一次即穿、整轮 fetch 中止（零重试）。
            temporary.unlink(missing_ok=True)
            last = exc
            if attempt < DOWNLOAD_ATTEMPTS:
                print(f"下载失败(第 {attempt}/{DOWNLOAD_ATTEMPTS} 次): {asset['name']}: {exc}——"
                      f"退避 {attempt * 5}s 后重试", file=sys.stderr)
                time.sleep(attempt * 5)
        finally:
            # C6 修复（三轮核验）：清理从「各 except 分支内」升为 finally——KeyboardInterrupt/
            # SystemExit 穿出时（CI 取消、Ctrl+C）原先绕过 unlink 留下 .downloading 孤儿件。
            # 成功路径 replace 后此处为 no-op（missing_ok）。
            temporary.unlink(missing_ok=True)
    raise OSError(f"资产下载失败: {asset['name']}: {last}")


# ---------------------------------------------------------------- 指针信任链(Ed25519 2-of-2)
#
# 2026-10-10 审查登记项(风险=高)修复:原 parse_catalog_pointer 只做自洽校验
# (page hash==payload hash==bytes,主钥为公开常量),从不验签,而文面声称「验签指针」。
# 本段把生产端语义最小移植到训练侧(训练机无 CoreKit 树;零新依赖——cryptography
# 已在两平台 requirements 钉版):
#   - Go 生产端:medical-data/go/lib/medicalrelease/trust.go
#     (ParsePinnedRoot / VerifyPointer / validateRoot / validatePointerFields / verifySignatures);
#   - App 消费端:CoreKit/Sources/Infrastructure/VerifiedMedicalCatalogCandidate.swift
#     (MedicalCatalogSignedEnvelope.decode / MedicalCatalogSignedPointer.decode /
#      MedicalCatalogTrustEvaluator)与 CryptoKitMedicalCatalogTrustVerifier.swift(Ed25519=CryptoKit Curve25519.Signing);
#   - CI 同族 python:.github/actions/release/model_trust.py(verify_envelope;其阈值为通用
#     1..16,医疗 2-of-2 语义以 Go/App 为准)。
# 语义要点:签名只对 base64 解出的 payload **原始字节**验证(绝不重序列化再验);
# 信任根 = 随部署投放的 pinned-root.json(2-of-2 自签;永不从网络取根);
# 阈值 = **恰 2-of-2**(根与 catalog 各两把、互不重叠)。
#
# 已知语义出入(2026-10-11 取证,App 侧未发版面,仅登记不修):Go validatePointerFields
# 允许 packageAssetName 版本 ≤ catalogVersion(续期以新号复用旧包),App 侧
# MedicalCatalogSignedPointer.decode 为 == 严格相等——续期指针 App 会拒。训练侧
# 跟随 Go(≤;训练消费续期指针下载既有包),出入项移交发布方/App 侧裁决。

TRUST_ASSET_KIND = "medical-data"
TRUST_APP = "vitaliber"
TRUST_RELEASE_BASE_URL = f"https://cnb.cool/{DEFAULT_REPOSITORY}/-/releases/download/{DEFAULT_TAG}"
TRUST_ALLOWED_HOSTS = frozenset({"cnb.cool", "asset.cnb.cool"})
TRUST_THRESHOLD = 2
TRUST_MAX_KEYS = 16
TRUST_MAX_SIGNATURES = 16
TRUST_MAX_PAYLOAD_BYTES = 1 << 20
TRUST_MAX_ENVELOPE_BYTES = 2 << 20
TRUST_POINTER_VALIDITY = timedelta(days=31)
TRUST_ISSUED_SKEW = timedelta(minutes=5)
TRUST_SQLITE_SCHEMA_VERSION = 9
TRUST_ROOT_FILE_NAME = "pinned-root.json"           # 与 Go provision 产物同名(publicRootFileName)
TRUST_ROOT_ENV = "VITALIBER_MEDICAL_TRUST_ROOT"

_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"            # Go TimeLayout 逐字回环
_LOWER_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_ROOT_DOCUMENT_KEYS = frozenset({
    "schemaVersion", "role", "app", "assetKind", "version", "expiresAt", "keys",
    "rootKeyIDs", "rootThreshold", "catalogKeyIDs", "catalogThreshold", "assetBaseURL", "allowedHosts",
})
_POINTER_TOP_KEYS = frozenset({
    "schemaVersion", "role", "app", "assetKind", "rootVersion", "catalogVersion", "issuedAt",
    "expiresAt", "sqliteSha256", "packageSha256", "packageSize", "packageAssetName",
    "fetchStateSha256", "installable", "contentSha256", "planSetSHA256", "dataVersion",
    "sqliteSchemaVersion", "releaseTag", "repository", "manifest",
})
_POINTER_HEX_FIELDS = ("sqliteSha256", "packageSha256", "fetchStateSha256", "contentSha256",
                       "dataVersion", "planSetSHA256")
# 指针 ↔ 内嵌清单逐项互核(Go validatePointerFields;清单层 snake_case 为冻结口径)。
_POINTER_MANIFEST_PAIRS = (
    ("contentSha256", "content_sha256"), ("fetchStateSha256", "fetch_state_sha256"),
    ("dataVersion", "data_version"), ("sqliteSha256", "sqlite_sha256"),
    ("planSetSHA256", "plan_set_sha256"),
)
_MANIFEST_REQUIRED_KEYS = frozenset({
    "schema_version", "run_id", "run_status", "installable", "started_at",
    "content_sha256", "sqlite_sha256", "sqlite_schema_version", "plan_set_sha256",
    "config_sha256", "source_policy_sha256", "processor_contracts_sha256",
    "fetch_state_sha256", "data_version", "sources",
})
_MANIFEST_ALLOWED_KEYS = _MANIFEST_REQUIRED_KEYS | {"ended_at"}   # Go omitempty:ended_at 可缺席
_MANIFEST_SCHEMA_VERSION = 2


def _trust_refusal(reason: str) -> ValueError:
    """统一拒绝文本:指针验签失败:<原因>——拒绝(契约文本,测试逐字断言)。"""
    return ValueError(f"指针验签失败:{reason}——拒绝")


def _strict_base64(text, what: str) -> bytes:
    if not isinstance(text, str) or not text:
        raise _trust_refusal(f"{what}不是非空 base64 字符串")
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise _trust_refusal(f"{what} base64 非法") from exc


def _parse_trust_timestamp(value, what: str) -> datetime:
    """仅接受 Go TimeLayout(2006-01-02T15:04:05Z)的逐字回环形式。"""
    if not isinstance(value, str):
        raise _trust_refusal(f"{what}时间戳缺失或非字符串")
    try:
        parsed = datetime.strptime(value, _TIMESTAMP_FORMAT).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise _trust_refusal(f"{what}时间戳格式非法: {value!r}") from exc
    if parsed.strftime(_TIMESTAMP_FORMAT) != value:
        raise _trust_refusal(f"{what}时间戳非规范回环形式: {value!r}")
    return parsed


def _ed25519_verify(public_key: bytes, signature: bytes, message: bytes) -> bool:
    """Ed25519 验签(延迟加载 cryptography:模块顶层保持 stdlib 可导入)。"""
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as exc:  # pragma: no cover - 两平台 requirements 已钉版
        raise _trust_refusal(f"缺 cryptography 依赖(Ed25519 验签不可用): {exc}") from exc
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, message)
        return True
    except InvalidSignature:
        return False


def decode_signed_envelope(raw: bytes, what: str) -> tuple[bytes, list[dict]]:
    """签名信封 → (payload 原始字节, [{'keyId','signature'}])。

    形状逐项对齐 Go decodeStrict(DisallowUnknownFields)+ Swift
    MedicalCatalogSignedEnvelope.decode:顶层恰 {payload, signatures};payload 严格
    base64、非空、≤1 MiB;签名条目恰 {keyId, signature},签名 64 字节严格 base64,
    keyId 去重。签名**数量下限**由调用侧政策定义(0 项=无签名,交验签政策处置)。
    """
    if len(raw) > TRUST_MAX_ENVELOPE_BYTES:
        raise _trust_refusal(f"{what}信封超出上限({len(raw)} > {TRUST_MAX_ENVELOPE_BYTES})")
    try:
        envelope = json.loads(raw)
    except ValueError as exc:
        raise _trust_refusal(f"{what}信封不是合法 JSON: {exc}") from exc
    if not isinstance(envelope, dict) or set(envelope) - {"payload", "signatures"}:
        raise _trust_refusal(f"{what}信封顶层键非法(恰允许 payload/signatures)")
    payload = _strict_base64(envelope.get("payload"), f"{what} payload")
    if not payload or len(payload) > TRUST_MAX_PAYLOAD_BYTES:
        raise _trust_refusal(f"{what} payload 为空或超出上限")
    values = envelope.get("signatures")
    if values is None:
        values = []            # Go:nil 切片等价零值(缺键=无签名)
    if not isinstance(values, list) or len(values) > TRUST_MAX_SIGNATURES:
        raise _trust_refusal(f"{what}签名列表非法")
    signatures: list[dict] = []
    seen: set[str] = set()
    for entry in values:
        if not isinstance(entry, dict) or set(entry) - {"keyId", "signature"}:
            raise _trust_refusal(f"{what}签名条目键非法")
        key_id = entry.get("keyId")
        if not isinstance(key_id, str) or not key_id or key_id in seen:
            raise _trust_refusal(f"{what}签名 keyId 缺失、非法或重复")
        seen.add(key_id)
        raw_signature = _strict_base64(entry.get("signature"), f"{what}签名")
        if len(raw_signature) != 64:
            raise _trust_refusal(f"{what}签名须为 64 字节 Ed25519")
        signatures.append({"keyId": key_id, "signature": raw_signature})
    return payload, signatures


def verify_envelope_signatures(payload: bytes, signatures: list[dict], keys: dict[str, bytes],
                               allowed_ids, what: str) -> int:
    """阈值验签:只计允许 keyId 内的有效签名(未知 keyId 忽略但不计数;Go/Swift 同款)。"""
    permitted = set(allowed_ids)
    verified = 0
    for signature in signatures:
        key_id = signature["keyId"]
        if key_id not in permitted or key_id not in keys:
            continue
        if _ed25519_verify(keys[key_id], signature["signature"], payload):
            verified += 1
    if verified < TRUST_THRESHOLD:
        raise _trust_refusal(f"{what}签名未达 2-of-2 阈值(有效 {verified}/2)")
    return verified


def validate_root_document(document, now: datetime) -> tuple[dict, dict[str, bytes]]:
    """Go validateRoot 的镜像(不含自签校验;返回 (根文档, keyId→公钥))。"""
    if not isinstance(document, dict) or set(document) != _ROOT_DOCUMENT_KEYS:
        raise _trust_refusal("信任根字段集非法(多/少键均拒)")
    if (type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1
            or document["role"] != "root"
            or document["app"] != TRUST_APP or document["assetKind"] != TRUST_ASSET_KIND):
        raise _trust_refusal("信任根范围不符(schema/role/app/assetKind)")
    if type(document["version"]) is not int or not 0 < document["version"] <= _INT64_MAX:
        raise _trust_refusal("信任根 version 非法")
    expires = _parse_trust_timestamp(document["expiresAt"], "信任根")
    if expires <= now:
        raise _trust_refusal(f"信任根已过期({document['expiresAt']})")
    keys_raw = document["keys"]
    if not isinstance(keys_raw, list) or not 1 <= len(keys_raw) <= TRUST_MAX_KEYS:
        raise _trust_refusal("信任根公钥集非法(数量)")
    keys: dict[str, bytes] = {}
    for key in keys_raw:
        if not isinstance(key, dict) or set(key) != {"id", "publicKey"}:
            raise _trust_refusal("信任根公钥条目键非法")
        key_id = key["id"]
        raw = _strict_base64(key["publicKey"], "信任根公钥")
        if (not isinstance(key_id, str) or len(raw) != 32
                or hashlib.sha256(raw).hexdigest() != key_id or key_id in keys):
            raise _trust_refusal(f"信任根公钥身份不符(sha256(pubkey)==id): {key_id!r}")
        keys[key_id] = raw
    root_ids, catalog_ids = document["rootKeyIDs"], document["catalogKeyIDs"]
    if not isinstance(root_ids, list) or not isinstance(catalog_ids, list):
        raise _trust_refusal("信任根签名域 ID 列表非法")
    if (type(document["rootThreshold"]) is not int or type(document["catalogThreshold"]) is not int
            or document["rootThreshold"] != TRUST_THRESHOLD or len(root_ids) != TRUST_THRESHOLD
            or document["catalogThreshold"] != TRUST_THRESHOLD or len(catalog_ids) != TRUST_THRESHOLD):
        raise _trust_refusal("信任根签名域必须恰为 2-of-2(root/catalog)")
    if (len(set(root_ids)) != len(root_ids) or len(set(catalog_ids)) != len(catalog_ids)
            or not set(root_ids) <= set(keys) or not set(catalog_ids) <= set(keys)):
        raise _trust_refusal("信任根签名域 ID 非法(重复或不在公钥集)")
    if set(root_ids) & set(catalog_ids):
        raise _trust_refusal("信任根/catalog 密钥必须分离")
    if document["assetBaseURL"] != TRUST_RELEASE_BASE_URL:
        raise _trust_refusal(f"信任根 assetBaseURL 不符: {document['assetBaseURL']!r}")
    hosts = document["allowedHosts"]
    if (not isinstance(hosts, list) or not hosts or len(set(hosts)) != len(hosts)
            or not set(hosts) <= TRUST_ALLOWED_HOSTS):
        raise _trust_refusal("信任根 allowedHosts 不符(须为已知主机子集,非空且不重复)")
    return document, keys


def verify_pinned_root(root_json: bytes, now: datetime) -> tuple[dict, dict[str, bytes]]:
    """指定信任根的自校验:形状/范围/2-of-2 自签/有效期。根不在此通过 → 全链拒。"""
    payload, signatures = decode_signed_envelope(root_json, "信任根")
    try:
        document = json.loads(payload)
    except ValueError as exc:
        raise _trust_refusal(f"信任根 payload 不是 JSON 对象: {exc}") from exc
    root, keys = validate_root_document(document, now)
    verify_envelope_signatures(payload, signatures, keys, root["rootKeyIDs"], "信任根")
    return root, keys


def validate_pointer_payload(payload, root_version: int, now: datetime, expected_asset_name: str) -> dict:
    """Go validatePointerFields(+ VerifyPointer 的 rootVersion/时间窗/资产名)的镜像。"""
    if not isinstance(payload, dict) or set(payload) != _POINTER_TOP_KEYS:
        raise _trust_refusal("指针载荷字段集非法(多/少键均拒)")
    if (type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 3 or payload["role"] != "catalog"
            or payload["app"] != TRUST_APP or payload["assetKind"] != TRUST_ASSET_KIND):
        raise _trust_refusal("指针范围不符(schemaVersion/role/app/assetKind)")
    if type(payload["rootVersion"]) is not int or type(payload["catalogVersion"]) is not int \
            or not 0 < payload["rootVersion"] <= _INT64_MAX \
            or not 0 < payload["catalogVersion"] <= _INT64_MAX:
        raise _trust_refusal("指针 root/catalog 版本必须为正整数")
    if payload["rootVersion"] != root_version:
        raise _trust_refusal(f"指针 rootVersion 与信任根不符: {payload['rootVersion']} != {root_version}")
    for name in _POINTER_HEX_FIELDS:
        if not isinstance(payload[name], str) or not _LOWER_HEX64.fullmatch(payload[name]):
            raise _trust_refusal(f"指针 {name} 须为小写 SHA-256 hex")
    if type(payload["packageSize"]) is not int or payload["packageSize"] <= 0:
        raise _trust_refusal("指针 packageSize 必须为正整数")
    if type(payload["sqliteSchemaVersion"]) is not int or payload["sqliteSchemaVersion"] not in SUPPORTED_SCHEMAS:
        raise _trust_refusal(f"指针不支持物理 SQLite schema {payload['sqliteSchemaVersion']!r}")
    if payload["sqliteSchemaVersion"] == 9 and payload["dataVersion"] != payload["contentSha256"]:
        raise _trust_refusal("unified R/dataVersion/contentSha256 不符")
    if type(payload["installable"]) is not bool:
        raise _trust_refusal("指针 installable 必须为布尔")
    if payload["repository"] != DEFAULT_REPOSITORY or payload["releaseTag"] != DEFAULT_TAG:
        raise _trust_refusal(f"指针 repository/releaseTag 不符: {payload['repository']!r}/{payload['releaseTag']!r}")
    name = payload["packageAssetName"]
    if not isinstance(name, str):
        raise _trust_refusal("指针 packageAssetName 非字符串")
    match = _PACKAGE_NAME.fullmatch(name)
    if match is None or int(match.group(1)) > payload["catalogVersion"]:
        raise _trust_refusal(f"包资产名不符文法或版本晚于 catalogVersion: {name!r}")
    # v3 内嵌清单:键集/互核(snake_case 清单层;Go validatePointerFields 逐项)。
    manifest = payload["manifest"]
    if not isinstance(manifest, dict) or set(manifest) - _MANIFEST_ALLOWED_KEYS \
            or not _MANIFEST_REQUIRED_KEYS <= set(manifest):
        raise _trust_refusal("指针内嵌清单字段集非法")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != _MANIFEST_SCHEMA_VERSION:
        raise _trust_refusal(f"内嵌清单 schema_version 非 {_MANIFEST_SCHEMA_VERSION}")
    if type(manifest["installable"]) is not bool or manifest["installable"] != payload["installable"]:
        raise _trust_refusal("指针/清单 installable 不符")
    if type(manifest["sqlite_schema_version"]) is not int \
            or manifest["sqlite_schema_version"] != payload["sqliteSchemaVersion"]:
        raise _trust_refusal("指针/清单 sqlite_schema_version 不符")
    for pointer_name, manifest_name in _POINTER_MANIFEST_PAIRS:
        if manifest[manifest_name] != payload[pointer_name]:
            raise _trust_refusal(f"指针/清单 {pointer_name} 不符")
    sources = manifest["sources"]
    if not isinstance(sources, list) or not sources or not all(isinstance(s, dict) for s in sources):
        raise _trust_refusal("内嵌清单 sources 非法(须为非空对象数组)")
    # 时间窗(Go VerifyPointer):issued ≤ now+5min;expires > now;issued < expires ≤ issued+31d。
    issued = _parse_trust_timestamp(payload["issuedAt"], "指针")
    expires = _parse_trust_timestamp(payload["expiresAt"], "指针")
    if issued > now + TRUST_ISSUED_SKEW:
        raise _trust_refusal(f"指针签发时间超前(issuedAt={payload['issuedAt']})")
    if expires <= now:
        raise _trust_refusal(f"指针已过期({payload['expiresAt']})")
    if expires <= issued or expires - issued > TRUST_POINTER_VALIDITY:
        raise _trust_refusal("指针有效期非正或超过 31 天")
    if expected_asset_name != MANIFEST_ASSET_NAME:
        raise _trust_refusal(f"资产名不符:预期 {MANIFEST_ASSET_NAME},实为 {expected_asset_name!r}")
    return payload


def resolve_trust_root_path(explicit=None) -> Path:
    """信任根解析:--trust-root > env VITALIBER_MEDICAL_TRUST_ROOT > 本脚本同目录 pinned-root.json。"""
    if explicit is not None:
        return Path(explicit).expanduser()
    from_env = os.environ.get(TRUST_ROOT_ENV, "").strip()
    if from_env:
        return Path(from_env).expanduser()
    return Path(__file__).resolve().with_name(TRUST_ROOT_FILE_NAME)


def _warn_unsigned(reason: str) -> None:
    print(f"\033[31m[警告] --allow-unsigned:指针验签已跳过({reason})——"
          "本批医疗目录未经发布方签名验证,仅限信任根未就绪的过渡期,请尽快部署 pinned-root.json;\033[0m",
          file=sys.stderr)


def verify_catalog_pointer(raw: bytes, *, trust_root=None, now: datetime | None = None,
                           allow_unsigned: bool = False,
                           expected_asset_name: str = MANIFEST_ASSET_NAME) -> dict | None:
    """指针验签(信任链第一层)。返回验签通过的指针载荷;逃生门放行时返回 None(调用方自解析)。

    - 信任根存在 → **必须**自校通过(根损坏/过期/2-of-2 不足 = 硬拒,逃生门不豁免);
      指针有签名 → 必须达 catalog 2-of-2(篡改/阈值不足/过期/范围不符 = 硬拒,不豁免);
      指针无签名 → 默认拒;--allow-unsigned 时红字警示放行。
    - 信任根缺 → 默认拒(「未配置信任根」);--allow-unsigned 时红字警示放行。
      (逃生门只豁免「验签能力缺失」,绝不豁免「验签失败」——被篡改的指针带旗标也拒。)
    """
    now = now or datetime.now(timezone.utc)
    root_path = resolve_trust_root_path(trust_root)
    if not root_path.is_file():
        if not allow_unsigned:
            raise _trust_refusal(
                f"未配置信任根({root_path} 不存在或不是文件;经 --trust-root 或 "
                f"{TRUST_ROOT_ENV} 提供 pinned-root.json,或显式 --allow-unsigned 跳过)")
        _warn_unsigned(f"未配置信任根({root_path})")
        return None
    try:
        root_json = root_path.read_bytes()
    except OSError as exc:
        raise _trust_refusal(f"信任根读取失败({root_path}): {exc}") from exc
    root, keys = verify_pinned_root(root_json, now)
    payload, signatures = decode_signed_envelope(raw, "指针")
    if not signatures:
        if not allow_unsigned:
            raise _trust_refusal("指针无签名")
        _warn_unsigned("指针无签名")
        return None
    verify_envelope_signatures(payload, signatures, keys, root["catalogKeyIDs"], "指针")
    try:
        pointer = json.loads(payload)
    except ValueError as exc:
        raise _trust_refusal(f"指针载荷不是 JSON 对象: {exc}") from exc
    return validate_pointer_payload(pointer, root["version"], now, expected_asset_name)


# ---------------------------------------------------------------- 指针解析

def parse_catalog_pointer(raw: bytes, *, trust_root=None, now: datetime | None = None,
                          allow_unsigned: bool = False,
                          expected_asset_name: str = MANIFEST_ASSET_NAME) -> dict:
    """`manifest.json`(签名信封)→ Ed25519 验签 → 指针载荷(base64 内嵌 JSON;v3 协议)。

    v3(2026-10-07 业主裁决,生产端 names.go/trust.go)相对 v2 的差异:
    - 资产文法:固定名 `manifest.json`/`overview.json` + `package-<catalogVersion>.bin`
      (append-only;续期复用旧包时 manifest 的 packageAssetName 可小于当前 catalogVersion,
      但不可能大于——本函数按此断言);
    - 逐源清单**内嵌** payload(`manifest` 字段),无独立 manifest 资产与 manifestSha256 间接绑定;
    - 包名不再内嵌哈希(内容哈希全在载荷里),因此名称层交叉退化为「版本 ≤ catalogVersion」,
      哈希校验由下载后逐层执行(页内 hashValue → 密文 SHA → GCM → 内层 sqlite SHA)。

    信任链(2026-10-11 验签修复批):先经 verify_catalog_pointer 做 Ed25519 2-of-2 验签
    (信任根 = 随部署投放的 pinned-root.json;缺根/无签名默认拒,`--allow-unsigned` 为
    红字警示的过渡逃生门),验签通过后才做形状校验——形状层保底 fail-closed:
    缺任一关键字段/名称文法不符即拒(指针是后续一切校验的锚)。
    """
    verified = verify_catalog_pointer(raw, trust_root=trust_root, now=now,
                                      allow_unsigned=allow_unsigned,
                                      expected_asset_name=expected_asset_name)
    if verified is not None:
        payload = verified
    else:
        try:
            envelope = json.loads(raw)
            payload = json.loads(base64.b64decode(envelope["payload"]))
        except (ValueError, KeyError, TypeError) as exc:
            raise ValueError(f"指针文件形状非法: {exc}") from exc
        if not isinstance(payload, dict):
            raise ValueError("指针载荷不是 JSON 对象")
        validate_pointer_payload(payload, payload.get("rootVersion"), now or datetime.now(timezone.utc),
                                 expected_asset_name)
    for key in ("packageAssetName", "packageSha256", "sqliteSha256", "dataVersion", "contentSha256"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise ValueError(f"指针载荷缺字段: {key}")
    match = _PACKAGE_NAME.fullmatch(payload["packageAssetName"])
    if match is None:
        raise ValueError(f"包资产名不符文法(package-<版本>.bin): {payload['packageAssetName']}")
    catalog_version = payload.get("catalogVersion")
    if not isinstance(catalog_version, int) or catalog_version <= 0:
        raise ValueError(f"指针载荷缺有效 catalogVersion: {catalog_version!r}")
    if int(match.group(1)) > catalog_version:
        raise ValueError(f"包版本晚于 catalogVersion: {match.group(1)} > {catalog_version}")
    # v3 内嵌清单一致性(签名覆盖整体;两处若漂移即载荷自相矛盾)。
    inner = payload.get("manifest")
    if not isinstance(inner, dict):
        raise ValueError("指针载荷无内嵌 manifest(v3 起必填)")
    if inner.get("sqlite_sha256") and inner["sqlite_sha256"] != payload["sqliteSha256"]:
        raise ValueError("内嵌清单 sqlite_sha256 与指针不符")
    if inner.get("data_version") and inner["data_version"] != payload["dataVersion"]:
        raise ValueError("内嵌清单 data_version 与指针不符")
    return payload


def select_manifest_asset(assets: list[dict]) -> dict:
    """v3 固定名指针资产(manifest.json);缺失即拒(不做任何旧名回退——生产端
    明确「无双重文法」,迁移期旧资产已删除,静默回退会掩盖协议漂移)。"""
    for asset in assets:
        if asset["name"] == MANIFEST_ASSET_NAME:
            return asset
    names = ", ".join(a["name"] for a in assets[:10]) or "(空)"
    raise ValueError(f"tag 页缺 {MANIFEST_ASSET_NAME}(现资产前 10:{names})")


# ---------------------------------------------------------------- 解密 + 解包

def extract_sqlite_zip(zip_path: Path, sqlite_out: Path, identity: str) -> None:
    """Accept exactly the fixed, ordinary SQLite member; publish only after its gate."""
    import zipfile
    import uuid
    tmp_sqlite = sqlite_out.with_name(sqlite_out.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with zipfile.ZipFile(zip_path) as archive:
            members = archive.infolist()
            if len(members) != 1:
                raise ValueError("包内必须只有 medical-catalog.sqlite 普通文件")
            member = members[0]
            mode = member.external_attr >> 16
            if (member.filename != SQLITE_ENTRY_NAME or member.orig_filename != SQLITE_ENTRY_NAME
                    or member.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                    or member.flag_bits & 1
                    or member.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                    or not 0 < member.file_size <= MAX_SQLITE_BYTES):
                raise ValueError("包内固定 SQLite 条目不是受支持的普通文件")
            digest, written = hashlib.sha256(), 0
            with archive.open(member) as src, open(tmp_sqlite, "xb") as dst:
                for chunk in iter(lambda: src.read(1 << 20), b""):
                    written += len(chunk)
                    if written > member.file_size or written > MAX_SQLITE_BYTES:
                        raise ValueError("包内 SQLite 超过声明大小/预算")
                    digest.update(chunk)
                    dst.write(chunk)
            if written != member.file_size or digest.hexdigest() != identity:
                raise ValueError("内层 SQLite SHA-256/大小与指针不符")
        validate_sqlite(tmp_sqlite, sqlite_sha256=identity)
        tmp_sqlite.replace(sqlite_out)
    finally:
        tmp_sqlite.unlink(missing_ok=True)


def decrypt_and_extract(cipher: Path, zip_path: Path, sqlite_out: Path, identity: str) -> None:
    """信封 → ZIP → 内层 SQLite。identity = 指针 sqliteSha256(信封 key/nonce 派生锚)。"""
    if str(RELEASE_DIR) not in sys.path:
        sys.path.insert(0, str(RELEASE_DIR))
    from asr_envelope import decrypt_package, is_envelope_file  # 延迟加载(需 cryptography)
    if not is_envelope_file(cipher):
        raise ValueError(f"密文前缀不是 VLASR 信封: {cipher}")
    master = bytes.fromhex(MEDICAL_PACKAGE_KEY_HEX)
    decrypt_package(master, identity, cipher, zip_path)
    extract_sqlite_zip(zip_path, sqlite_out, identity)
    print(f"[ok] 内层 SQLite 校验通过: {SQLITE_ENTRY_NAME} sha256={identity[:16]}…")


# ---------------------------------------------------------------- 主流程

def run_remote(repository: str, tag: str, out_dir: Path, keep_intermediates: bool,
               trust_root=None, allow_unsigned: bool = False) -> dict:
    print(f"[fetch] tag 页: {repository} / {tag}")
    page = fetch_tag_page(repository, tag)
    assets = _cnb_read().parse_cnb_tag_page(page, repository, tag)
    print(f"[fetch] 资产 {len(assets)} 件")

    work = out_dir / ".fetch-work"
    work.mkdir(parents=True, exist_ok=True)
    manifest_asset = select_manifest_asset(assets)
    pointer_path = work / MANIFEST_ASSET_NAME
    download_asset(repository, tag, manifest_asset, pointer_path)
    pointer = parse_catalog_pointer(pointer_path.read_bytes(), trust_root=trust_root,
                                    allow_unsigned=allow_unsigned)
    if pointer["installable"] is not True:
        raise ValueError("指针 installable=false，研发/partial 包不可交付")
    print(f"[fetch] 指针(v3 manifest.json):catalogVersion={pointer.get('catalogVersion')} "
          f"dataVersion={pointer['dataVersion'][:16]}… installable={pointer.get('installable')}")

    # 资产层与指针载荷的交叉校验(缺一件即拒):包必在页内且页内哈希 == 载荷密文 SHA。
    by_name = {a["name"]: a for a in assets}
    package_asset = by_name.get(pointer["packageAssetName"])
    if package_asset is None:
        raise ValueError(f"tag 页缺少指针所指包资产: {pointer['packageAssetName']}")
    if (package_asset["hashValue"] != pointer["packageSha256"]
            or package_asset["sizeInByte"] != pointer["packageSize"]):
        raise ValueError("包资产页内哈希/大小与已签指针不符")

    # overview.json 固定名、替换发布,可短暂缺席(展示件非权威)——缺席不判失败。
    overview_asset = by_name.get(OVERVIEW_ASSET_NAME)

    cipher = work / package_asset["name"]
    print(f"[fetch] 下载包 {package_asset['sizeInByte'] / 1048576:.0f} MiB …")
    download_asset(repository, tag, package_asset, cipher)
    if cipher.stat().st_size != pointer["packageSize"] or sha256_file(cipher) != pointer["packageSha256"]:
        raise ValueError("密文包 SHA-256/大小与已签指针不符")

    zip_path = work / "package.zip"
    sqlite_out = out_dir / "catalog.sqlite"
    staged_sqlite = work / SQLITE_ENTRY_NAME
    decrypt_and_extract(cipher, zip_path, staged_sqlite, pointer["sqliteSha256"])
    identity = validate_sqlite(staged_sqlite, schema=pointer["sqliteSchemaVersion"],
        data_version=pointer["dataVersion"], content_sha256=pointer["contentSha256"],
        sqlite_sha256=pointer["sqliteSha256"])
    signed_payload = _strict_base64(json.loads(pointer_path.read_bytes())["payload"], "指针 payload")
    signed_digest = hashlib.sha256(signed_payload).hexdigest()

    # E5 修复：指针落盘排在核心件（catalog.sqlite）**校验通过之后**——原先在校验前复制，
    # 失败时 out_dir 会留下「新数据版本的 pointer.json + 截断/旧 sqlite」的混合半成品，
    # 与「任一层不符即拒绝产出(绝不落半成品)」契约相反。原始签名信封逐字节留档(provenance)。
    # 半成品窗口再收紧：复制同样走临时名+原子换名（copy2 中途被杀不再留截断 pointer）。
    if overview_asset is not None:
        download_asset(repository, tag, overview_asset, work / "overview.json")

    pointer_dst = out_dir / "pointer.json"
    pointer_tmp = out_dir / ".pointer.json.tmp"
    shutil.copy2(pointer_path, pointer_tmp)
    os.replace(staged_sqlite, sqlite_out)
    os.replace(pointer_tmp, pointer_dst)
    if overview_asset is not None:
        os.replace(work / "overview.json", out_dir / "overview.json")

    if not keep_intermediates:
        shutil.rmtree(work, ignore_errors=True)

    return {
        "mode": "cnb-release-v3",
        **identity.descriptor(),
        "signedPointerDigest": signed_digest,
        "repository": repository,
        "tag": tag,
        "catalogVersion": pointer.get("catalogVersion"),
        "dataVersion": pointer["dataVersion"],
        "contentSha256": pointer["contentSha256"],
        "sqliteSha256": pointer["sqliteSha256"],
        "packageAssetName": pointer["packageAssetName"],
        "packageSha256": pointer["packageSha256"],
        "sqliteSchemaVersion": pointer.get("sqliteSchemaVersion"),
        "installable": pointer.get("installable"),
        "pointerPath": str(out_dir / "pointer.json"),
        "sqlitePath": str(sqlite_out),
        "licenses": {
            "TFDA": "藥品許可證資料集(OGDL v1 顯名聲明,三語)",
            "NHSA": "医保药品目录批次数据(官方接口频控纪律,见 lexicon-data-sources.md §2)",
            "HK": "data.gov.hk / HA 公開數據",
            "CN-REF": "国家卫健委/医保局公开目录",
        },
    }


def run_local(sqlite: Path, out_dir: Path) -> dict:
    target = out_dir / "catalog.sqlite"
    identity = validate_sqlite(sqlite)
    if sqlite.resolve() != target.resolve():
        # E5 同款：--local-sqlite 旁路同样临时名+原子换名（原先 copy2 直写终名，中途失败
        # 会留下“存在即消费”的截断 catalog.sqlite）。
        local_tmp = target.with_name(target.name + ".tmp")
        try:
            shutil.copy2(sqlite, local_tmp)
            validate_sqlite(local_tmp, schema=identity.schema, data_version=identity.data_version,
                            content_sha256=identity.content_sha256, sqlite_sha256=sha256_file(sqlite))
            os.replace(local_tmp, target)
        finally:
            local_tmp.unlink(missing_ok=True)
    return {
        "mode": "local-sqlite",
        **identity.descriptor(),
        "note": "开发旁路:直接使用本机已解密目录(生产语料一律走 CNB Release,fetch_catalog.py 远端模式)",
        "sqlitePath": str(target),
        "sqliteSha256": sha256_file(target),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--local-sqlite", type=Path, default=None,
                        help="开发旁路:跳过网络,直接用本机目录 SQLite(仅本地原型期)")
    parser.add_argument("--release-dir", type=Path, default=None,
                        help="release 簇(cnb_read/cnb_release/asr_envelope)所在目录覆盖:"
                             "训练机 staged 树用;提供时跳过 CoreKit 上溯。env VITALIBER_RELEASE_DIR 等价,"
                             "命令行优先;两者都不给 = CI 仓内默认解析(行为不变)")
    parser.add_argument("--keep-intermediates", action="store_true",
                        help="保留 .fetch-work/(密文+ZIP,供失败诊断;默认成功后清理)")
    parser.add_argument("--pointer-only", action="store_true",
                        help="只读指针信封(manifest.json):打印 dataVersion/catalogVersion 即退"
                             "(训练调度器数据门禁用;不下载 package)")
    parser.add_argument("--trust-root", type=Path, default=None,
                        help="医疗信任根(pinned-root.json,2-of-2 自签 Ed25519)文件路径;"
                             "缺省=env VITALIBER_MEDICAL_TRUST_ROOT,再缺省=本脚本同目录 pinned-root.json。"
                             "缺根即拒(「指针验签失败:未配置信任根…——拒绝」)")
    parser.add_argument("--allow-unsigned", action="store_true",
                        help="过渡逃生门:信任根未部署/指针无签名时跳过验签(红字警示;"
                             "验签失败本身——篡改/阈值不足/过期/根损坏——不豁免,恒拒)")
    args = parser.parse_args()

    override = args.release_dir or os.environ.get("VITALIBER_RELEASE_DIR", "").strip() or None
    if override:
        try:
            apply_release_dir_override(override)
        except ValueError as exc:
            print(f"FAILED: {exc}", file=sys.stderr)
            return 1
        print(f"[fetch] release 簇目录覆盖生效: {RELEASE_DIR}")

    if args.pointer_only:
        try:
            work = args.out_dir / ".pointer-work"
            work.mkdir(parents=True, exist_ok=True)
            pointer_path = work / MANIFEST_ASSET_NAME
            # 资产元数据取自同一 SSR tag 页(与 run_remote 同一条发现路径):download_asset
            # 需要 hashValue/sizeInByte 做先验后传。此前误传资产名**字符串**,TypeError 被
            # llm.yml 的 `2>/dev/null || echo ""` 吞成「指针不可达」——执行点复判从未生效
            # (2026-10-09 W11 训练机直连实证);本函数自锁:契约测试断言实参是资产字典。
            assets = _cnb_read().parse_cnb_tag_page(
                fetch_tag_page(args.repository, args.tag), args.repository, args.tag)
            download_asset(args.repository, args.tag, select_manifest_asset(assets), pointer_path)
            pointer = parse_catalog_pointer(pointer_path.read_bytes(), trust_root=args.trust_root,
                                            allow_unsigned=args.allow_unsigned)
            print(json.dumps({"dataVersion": pointer.get("dataVersion", ""),
                              "catalogVersion": pointer.get("catalogVersion", "")},
                             ensure_ascii=False))
        except (OSError, ValueError, urllib.error.URLError) as exc:
            print(f"FAILED: {exc}", file=sys.stderr)
            return 1
        return 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        if args.local_sqlite is not None:
            descriptor = run_local(args.local_sqlite, args.out_dir)
        else:
            descriptor = run_remote(args.repository, args.tag, args.out_dir, args.keep_intermediates,
                                    trust_root=args.trust_root, allow_unsigned=args.allow_unsigned)
    except (OSError, ValueError, urllib.error.URLError) as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1
    source_path = args.out_dir / "source.json"
    source_tmp = args.out_dir / ".source.json.tmp"
    source_tmp.write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(source_tmp, source_path)
    print(json.dumps(descriptor, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
