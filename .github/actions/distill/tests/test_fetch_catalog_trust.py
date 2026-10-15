"""fetch_catalog 指针验签契约(Ed25519 2-of-2;2026-10-11 验签修复批,CI 回移批 unittest 移植)。

背景(同训练侧 macos/tests/test_fetch_catalog_trust_contract.py):`parse_catalog_pointer`
原只做自洽校验(page hash==payload hash==bytes,AES 主钥为公开常量),从不验签,而文面声称
「验签指针」为第一 fail-closed 层(2026-10-10 审查登记项,风险=高)。本套件锁定修复后的语义:
信任根 2-of-2 自签 → 指针 catalog 2-of-2 验签(只对 payload 原始字节,绝不重序列化)→
rootVersion/时间窗/字段集与内嵌清单互核 → 缺根/无签名默认拒;`--allow-unsigned` 逃生门只豁免
「验签能力缺失」,篡改/阈值不足/过期/根损坏恒拒。

金样(TEST-ONLY)= 公仓 App 测试夹具 CoreKit/Tests/CoreKitTests/Fixtures/medical/
(与训练侧 fixtures/medical-trust/ 逐字节同源,Go `golden_export_test.go` 导出;单一材料源,
本套件直接消费,不另拷一份)。其 catalog 私钥在公仓公开(catalog-signing-keys.json 同目录),
严禁当作生产信任根部署;CI 生产根 = 本簇脚本同目录 `pinned-root.json`(公开信封,见
.github/actions/distill/README.md 根投放节)。固定时钟 `NOW` = expected.json 的 `now` 字段值。
"""
import base64
import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import fetch_catalog as fc

HERE = Path(__file__).resolve().parent
DISTILL = HERE.parent

# 仓根锚点逐级上溯（禁止固定层级 parents[N]——四文件化布局下会解析错位,见 workflows/README.md 分簇规则）
REPO_ROOT = HERE
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent
FIXTURES = REPO_ROOT / "CoreKit" / "Tests" / "CoreKitTests" / "Fixtures" / "medical"
PRODUCTION_ROOT = DISTILL / "pinned-root.json"

NOW = datetime(2026, 10, 1, 13, 0, 0, tzinfo=timezone.utc)
REJECTION_PREFIX = "指针验签失败:"
REJECTION_SUFFIX = "——拒绝"
# 夹具字节钉版(换夹具必须同批显式改此表;与夹具目录逐字节同源,训练侧同钉
# pinned-root/installable 两件,此处全六件皆钉)
FIXTURE_SHA256 = {
    "pinned-root.json": "2de1bb41d73f405ca86eadcea7123424051ce8e8df4ca7dea0cb1c0fea53683b",
    "installable-manifest.json": "1bfe22e3f4bfa76c5534c7cdb1d9cb821734f969e665d41c6520fa7e4956718b",
    "expired-manifest.json": "b497553ca114f47cebdbfcf69f80079f4d91d6f4a4c476f1688065ab3aa9a1a2",
    "pointer-single-signature.json": "7436d77b26f2fb7008f731e5c98a52b6ddd89963baa11e14efaa17abb4d2debb",
    "progress-manifest.json": "760c8d41574839c2b2bb5253fbd73f721138b8dbaa725f932d92d70e5dfda025",
    "expected.json": "43f0a318cde3d8046fda5608ceaf999939f3d7c14a1b90147aba401aabbb165c",
}

_TEMP_DIR = tempfile.TemporaryDirectory(prefix="medical-trust-contract-")


def fixture_bytes(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def fixture_root_path() -> Path:
    return FIXTURES / "pinned-root.json"


def envelope(raw: bytes) -> dict:
    return json.loads(raw)


def pointer_payload(raw: bytes) -> dict:
    return json.loads(base64.b64decode(json.loads(raw)["payload"]))


def seal(env: dict) -> bytes:
    return json.dumps(env).encode()


def reseal_payload(env: dict, mutate) -> bytes:
    """按 Go CanonicalJSON 形状重编 payload 同名签名——签名随即失效（篡改用例）。"""
    payload = json.loads(base64.b64decode(env["payload"]))
    mutate(payload)
    clone = dict(env)
    clone["payload"] = base64.b64encode(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).decode()
    return seal(clone)


def root_document() -> dict:
    return pointer_payload(fixture_bytes("pinned-root.json"))


def expect_refusal(operation, fragment: str = "") -> str:
    """断言操作以「指针验签失败:<原因>——拒绝」文本拒绝，返回消息全文。"""
    try:
        operation()
    except ValueError as exc:
        message = str(exc)
        assert message.startswith(REJECTION_PREFIX), f"拒绝文本前缀不符: {message}"
        assert message.endswith(REJECTION_SUFFIX), f"拒绝文本后缀不符: {message}"
        if fragment:
            assert fragment in message, f"拒绝文本缺片段 {fragment!r}: {message}"
        return message
    raise AssertionError("预期拒绝,实际通过")


def validate_pointer(payload: dict, *, root_version: int = 1, now: datetime = NOW,
                     expected_asset_name: str = "manifest.json") -> dict:
    return fc.validate_pointer_payload(payload, root_version=root_version, now=now,
                                       expected_asset_name=expected_asset_name)


def expect_pointer_refusal(mutate, fragment: str = "") -> str:
    payload = pointer_payload(fixture_bytes("installable-manifest.json"))
    mutate(payload)
    return expect_refusal(lambda: validate_pointer(payload), fragment)


def _temp_root(root_bytes: bytes) -> Path:
    """写临时根文件（模块级 TemporaryDirectory 托管,进程退出自动清理;不落盘于仓树）。"""
    path = Path(_TEMP_DIR.name) / f"{abs(hash(root_bytes)):016x}-pinned-root.json"
    path.write_bytes(root_bytes)
    return path


# ================================================================ 金样正路

class GoldenTests(unittest.TestCase):
    def test_fixture_files_are_byte_pinned(self):
        for name, digest in FIXTURE_SHA256.items():
            self.assertEqual(hashlib.sha256(fixture_bytes(name)).hexdigest(), digest, f"夹具漂移: {name}")

    def test_golden_root_self_check_passes_and_pins_scope(self):
        root, keys = fc.verify_pinned_root(fixture_bytes("pinned-root.json"), NOW)
        self.assertEqual(root["schemaVersion"], 1)
        self.assertEqual(root["role"], "root")
        self.assertEqual(root["app"], "vitaliber")
        self.assertEqual(root["assetKind"], "medical-data")
        self.assertEqual(root["rootThreshold"], root["catalogThreshold"], 2)
        self.assertEqual(len(root["rootKeyIDs"]), 2)
        self.assertEqual(len(root["catalogKeyIDs"]), 2)
        self.assertEqual(len(keys), 4, "根文档含 2 把 root + 2 把 catalog 公钥")

    def test_golden_pointer_verifies_and_returns_signed_payload(self):
        expected = json.loads(fixture_bytes("expected.json"))
        payload = fc.verify_catalog_pointer(fixture_bytes("installable-manifest.json"),
                                            trust_root=fixture_root_path(), now=NOW)
        self.assertEqual(payload["catalogVersion"], 20)
        self.assertEqual(payload["catalogVersion"], expected["catalogVersion"])
        self.assertEqual(payload["packageAssetName"], "package-20.bin")
        self.assertEqual(payload["packageAssetName"], expected["packageAssetName"])
        self.assertEqual(payload["packageSha256"], expected["packageSha256"])
        self.assertEqual(payload["dataVersion"], expected["dataVersion"])
        self.assertEqual(payload["rootVersion"], 1)
        self.assertIs(payload["installable"], True)
        self.assertEqual(payload["sqliteSchemaVersion"], 7)

    def test_parse_catalog_pointer_verified_path_matches_shape_path(self):
        raw = fixture_bytes("installable-manifest.json")
        verified = fc.parse_catalog_pointer(raw, trust_root=fixture_root_path(), now=NOW)
        self.assertEqual(verified["packageAssetName"], "package-20.bin")
        # 缺信任根默认拒（fail-closed 第一层）——不再有「静默不验签」的路径。
        expect_refusal(lambda: fc.parse_catalog_pointer(raw, trust_root=Path("/nonexistent/pinned-root.json"), now=NOW),
                       "未配置信任根")


# ================================================================ 篡改 / 换包 / 降阈值

class TamperTests(unittest.TestCase):
    def test_tampered_pointer_payload_is_rejected_by_signature(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        tampered = reseal_payload(env, lambda p: p.__setitem__("packageAssetName", "package-19.bin"))
        expect_refusal(lambda: fc.verify_catalog_pointer(tampered, trust_root=fixture_root_path(), now=NOW),
                       "2-of-2")

    def test_single_byte_signature_flip_is_rejected(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        raw = bytearray(base64.b64decode(env["signatures"][0]["signature"], validate=True))
        raw[0] ^= 0x01
        env["signatures"][0]["signature"] = base64.b64encode(bytes(raw)).decode()
        expect_refusal(lambda: fc.verify_catalog_pointer(seal(env), trust_root=fixture_root_path(), now=NOW),
                       "2-of-2")

    def test_swapped_signatures_between_envelopes_are_rejected(self):
        other = envelope(fixture_bytes("progress-manifest.json"))
        env = envelope(fixture_bytes("installable-manifest.json"))
        env["signatures"] = other["signatures"]      # 两枚均为真签名,但签的是别的载荷
        expect_refusal(lambda: fc.verify_catalog_pointer(seal(env), trust_root=fixture_root_path(), now=NOW),
                       "2-of-2")

    def test_single_signature_pointer_is_rejected(self):
        expect_refusal(lambda: fc.verify_catalog_pointer(fixture_bytes("pointer-single-signature.json"),
                                                         trust_root=fixture_root_path(), now=NOW), "2-of-2")

    def test_unknown_keyid_signature_is_ignored_but_never_counted(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        foreign = {"keyId": "00" * 32, "signature": base64.b64encode(bytes(64)).decode()}
        with_foreign = dict(env, signatures=env["signatures"] + [foreign])
        payload = fc.verify_catalog_pointer(seal(with_foreign), trust_root=fixture_root_path(), now=NOW)
        self.assertEqual(payload["catalogVersion"], 20, "未知 keyId 忽略不计数,双签仍足")
        only_foreign = dict(env, signatures=[foreign])
        expect_refusal(lambda: fc.verify_catalog_pointer(seal(only_foreign), trust_root=fixture_root_path(), now=NOW),
                       "2-of-2")

    def test_duplicate_or_malformed_signature_entries_are_rejected(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        duplicate = dict(env, signatures=env["signatures"] + [dict(env["signatures"][0])])
        expect_refusal(lambda: fc.verify_catalog_pointer(seal(duplicate), trust_root=fixture_root_path(), now=NOW),
                       "重复")
        short = dict(env, signatures=[{"keyId": env["signatures"][0]["keyId"],
                                       "signature": base64.b64encode(bytes(63)).decode()}])
        expect_refusal(lambda: fc.verify_catalog_pointer(seal(short), trust_root=fixture_root_path(), now=NOW),
                       "64 字节")


# ================================================================ 时间窗(指针/根)

class TimeWindowTests(unittest.TestCase):
    def test_expired_pointer_is_rejected(self):
        expect_refusal(lambda: fc.verify_catalog_pointer(fixture_bytes("expired-manifest.json"),
                                                         trust_root=fixture_root_path(), now=NOW), "已过期")

    def test_pointer_validity_window_boundaries(self):
        raw = fixture_bytes("installable-manifest.json")
        issued = datetime(2026, 10, 1, 12, 0, 0, tzinfo=timezone.utc)
        expires = datetime(2026, 11, 1, 12, 0, 0, tzinfo=timezone.utc)
        self.assertTrue(fc.verify_catalog_pointer(raw, trust_root=fixture_root_path(), now=issued - timedelta(minutes=5)))
        expect_refusal(lambda: fc.verify_catalog_pointer(raw, trust_root=fixture_root_path(),
                                                         now=issued - timedelta(minutes=5, seconds=1)),
                       "签发时间超前")
        expect_refusal(lambda: fc.verify_catalog_pointer(raw, trust_root=fixture_root_path(), now=expires),
                       "已过期")   # expires > now 严格

    def test_pointer_validity_cap_and_order_are_enforced(self):
        issued = datetime(2026, 10, 1, 12, 0, 0, tzinfo=timezone.utc)
        early = issued - timedelta(minutes=1)   # 早于 issued,避开「已过期」分流
        base = pointer_payload(fixture_bytes("installable-manifest.json"))
        base["expiresAt"] = (issued + timedelta(days=31)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertTrue(validate_pointer(base, now=early), "31 天窗为正边界,允许")
        base["expiresAt"] = (issued + timedelta(days=31, seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        expect_refusal(lambda: validate_pointer(base, now=early), "31 天")
        base["expiresAt"] = issued.strftime("%Y-%m-%dT%H:%M:%SZ")
        expect_refusal(lambda: validate_pointer(base, now=early), "有效期非正")

    def test_root_expiry_is_enforced(self):
        expect_refusal(lambda: fc.verify_pinned_root(fixture_bytes("pinned-root.json"),
                                                     datetime(2029, 1, 1, tzinfo=timezone.utc)),
                       "信任根已过期")

    def test_root_self_signature_is_required(self):
        env = envelope(fixture_bytes("pinned-root.json"))
        expect_refusal(lambda: fc.verify_catalog_pointer(
            fixture_bytes("installable-manifest.json"),
            trust_root=_temp_root(seal(dict(env, signatures=env["signatures"][:1]))), now=NOW), "2-of-2")
        raw = bytearray(base64.b64decode(env["signatures"][0]["signature"], validate=True))
        raw[0] ^= 0x01
        broken = dict(env, signatures=[dict(env["signatures"][0], signature=base64.b64encode(bytes(raw)).decode()),
                                       env["signatures"][1]])
        expect_refusal(lambda: fc.verify_catalog_pointer(
            fixture_bytes("installable-manifest.json"), trust_root=_temp_root(seal(broken)), now=NOW), "2-of-2")


# ================================================================ 根文档语义(接缝)

class RootSemanticsTests(unittest.TestCase):
    def test_root_threshold_must_be_exactly_two_of_two(self):
        for mutation, fragment in (
                (lambda d: d.__setitem__("rootThreshold", 1), "2-of-2"),
                (lambda d: d.__setitem__("catalogThreshold", 1), "2-of-2"),
                (lambda d: d.__setitem__("rootKeyIDs", d["rootKeyIDs"][:1]), "2-of-2"),
                (lambda d: d.__setitem__("catalogKeyIDs", [d["catalogKeyIDs"][0]] * 2), "重复")):
            document = root_document()
            mutation(document)
            expect_refusal(lambda: fc.validate_root_document(document, NOW), fragment)

    def test_root_scope_and_key_identity_are_enforced(self):
        for mutation, fragment in (
                (lambda d: d.__setitem__("assetKind", "asr"), "范围不符"),
                (lambda d: d.__setitem__("version", 0), "version"),
                (lambda d: d["keys"][0].__setitem__("id", "00" * 32), "公钥身份"),
                (lambda d: d.__setitem__("catalogKeyIDs", [d["rootKeyIDs"][0], d["catalogKeyIDs"][1]]), "分离")):
            document = root_document()
            mutation(document)
            expect_refusal(lambda: fc.validate_root_document(document, NOW), fragment)

    def test_root_release_base_hosts_and_field_set_are_pinned(self):
        for mutation, fragment in (
                (lambda d: d.__setitem__("assetBaseURL", "https://github.com/x/y/releases/download/medical-data"), "assetBaseURL"),
                (lambda d: d.__setitem__("allowedHosts", ["evil.example"]), "allowedHosts"),
                (lambda d: d.__setitem__("allowedHosts", []), "allowedHosts"),
                (lambda d: d.__setitem__("allowedHosts", ["asset.cnb.cool", "asset.cnb.cool"]), "allowedHosts"),
                (lambda d: d.__setitem__("extra", 1), "字段集"),
                (lambda d: d.pop("keys"), "字段集")):
            document = root_document()
            mutation(document)
            expect_refusal(lambda: fc.validate_root_document(document, NOW), fragment)


# ================================================================ 指针载荷语义(接缝)

class PointerSemanticsTests(unittest.TestCase):
    def test_pointer_scope_and_root_version_are_enforced(self):
        for mutation, fragment in (
                (lambda p: p.__setitem__("schemaVersion", 2), "范围不符"),
                (lambda p: p.__setitem__("assetKind", "asr"), "范围不符"),
                (lambda p: p.__setitem__("role", "root"), "范围不符")):
            expect_pointer_refusal(mutation, fragment)
        payload = pointer_payload(fixture_bytes("installable-manifest.json"))
        payload["rootVersion"] = 2
        expect_refusal(lambda: validate_pointer(payload, root_version=1), "rootVersion")

    def test_pointer_digest_grammar_is_enforced(self):
        expect_pointer_refusal(lambda p: p.__setitem__("sqliteSha256", p["sqliteSha256"].upper()), "小写 SHA-256")
        expect_pointer_refusal(lambda p: p.__setitem__("dataVersion", "abc"), "小写 SHA-256")
        expect_pointer_refusal(lambda p: p.__setitem__("packageSize", 0), "packageSize")

    def test_pointer_package_name_allows_renewal_lower_version_but_never_newer(self):
        payload = pointer_payload(fixture_bytes("installable-manifest.json"))
        payload["packageAssetName"] = "package-19.bin"   # 续期复用旧包(Go ≤ 语义;App==出入已登记)
        self.assertEqual(validate_pointer(payload)["packageAssetName"], "package-19.bin")
        expect_pointer_refusal(lambda p: p.__setitem__("packageAssetName", "package-21.bin"), "包资产名")
        expect_pointer_refusal(lambda p: p.__setitem__("packageAssetName", "package-020.bin"), "包资产名")

    def test_pointer_schema_and_release_identity_are_pinned(self):
        expect_pointer_refusal(lambda p: p.__setitem__("sqliteSchemaVersion", 8), "SQLite schema")
        expect_pointer_refusal(lambda p: p.__setitem__("repository", "other/repo"), "repository")
        expect_pointer_refusal(lambda p: p.__setitem__("releaseTag", "other-tag"), "repository")

    def test_legacy_and_unified_schema_dispatch_keep_wire_v3_manifest_v2(self):
        for schema in (4, 5, 6, 7, 9):
            payload = pointer_payload(fixture_bytes("installable-manifest.json"))
            payload["sqliteSchemaVersion"] = schema
            payload["manifest"]["sqlite_schema_version"] = schema
            self.assertEqual(validate_pointer(payload)["sqliteSchemaVersion"], schema)
        payload["contentSha256"] = "f" * 64
        payload["manifest"]["content_sha256"] = "f" * 64
        expect_refusal(lambda: validate_pointer(payload), "unified R")

    def test_pointer_manifest_crosscheck_rejects_drift(self):
        expect_pointer_refusal(lambda p: p["manifest"].__setitem__("content_sha256", "0" * 64), "contentSha256")
        expect_pointer_refusal(lambda p: p["manifest"].__setitem__("installable", not p["installable"]), "installable")
        expect_pointer_refusal(lambda p: p["manifest"].__setitem__("sqlite_schema_version", 6), "sqlite_schema_version")

    def test_pointer_and_manifest_field_sets_are_exact(self):
        expect_pointer_refusal(lambda p: p.__setitem__("extraField", 1), "字段集")
        expect_pointer_refusal(lambda p: p.pop("planSetSHA256"), "字段集")
        expect_pointer_refusal(lambda p: p["manifest"].__setitem__("extra_field", 1), "清单字段集")
        expect_pointer_refusal(lambda p: p["manifest"].pop("run_id"), "清单字段集")

        def drop_ended_at(p):
            p["manifest"].pop("ended_at")
        self.assertTrue(validate_pointer(pointer_payload(fixture_bytes("installable-manifest.json"))))  # 基线
        payload = pointer_payload(fixture_bytes("installable-manifest.json"))
        drop_ended_at(payload)
        self.assertTrue(validate_pointer(payload), "ended_at 为 Go omitempty:可缺席(其余 15 键必备)")

    def test_expected_asset_name_must_be_manifest_json(self):
        expect_refusal(lambda: validate_pointer(pointer_payload(fixture_bytes("installable-manifest.json")),
                                                expected_asset_name="pointer.json"), "资产名不符")


# ================================================================ 缺根/无签名与逃生门

class EscapeHatchTests(unittest.TestCase):
    def test_missing_root_default_reject_is_actionable(self):
        message = expect_refusal(lambda: fc.verify_catalog_pointer(
            fixture_bytes("installable-manifest.json"), trust_root=Path("/nonexistent/pinned-root.json"), now=NOW),
            "未配置信任根")
        self.assertIn("--trust-root", message)
        self.assertIn("pinned-root.json", message)
        self.assertIn("--allow-unsigned", message)

    def test_missing_root_escape_hatch_warns_red_and_returns_none(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = fc.verify_catalog_pointer(fixture_bytes("installable-manifest.json"),
                                               trust_root=Path("/nonexistent/pinned-root.json"), now=NOW,
                                               allow_unsigned=True)
        self.assertIsNone(result, "逃生门放行 = 不产出验签载荷(由调用方自解析)")
        self.assertIn("\033[31m", stderr.getvalue())
        self.assertIn("验签已跳过", stderr.getvalue(), "必须红字警示")

    def test_unsigned_pointer_default_reject_and_hatch(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        unsigned = seal(dict(env, signatures=[]))
        expect_refusal(lambda: fc.verify_catalog_pointer(unsigned, trust_root=fixture_root_path(), now=NOW),
                       "指针无签名")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = fc.verify_catalog_pointer(unsigned, trust_root=fixture_root_path(), now=NOW, allow_unsigned=True)
        self.assertIsNone(result)
        self.assertIn("\033[31m", stderr.getvalue())

    def test_escape_hatch_never_excuses_failed_verification(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        tampered = reseal_payload(env, lambda p: p.__setitem__("packageAssetName", "package-19.bin"))
        expect_refusal(lambda: fc.verify_catalog_pointer(tampered, trust_root=fixture_root_path(), now=NOW,
                                                         allow_unsigned=True), "2-of-2")
        corrupt_root = _temp_root(b"{not json")
        expect_refusal(lambda: fc.verify_catalog_pointer(fixture_bytes("installable-manifest.json"),
                                                         trust_root=corrupt_root, now=NOW, allow_unsigned=True),
                       "信任根")

    def test_escape_hatch_keeps_shape_layer_and_pipeline_path(self):
        # 逃生门路径 = 沿用形状层校验:金样可通过(过渡期管线可跑),坏形状仍拒。
        # 显式未配置根:CI 仓部署了生产根,夹具签名与生产 catalog 密钥不符——
        # 那是「验签失败」而非「验签能力缺失」,逃生门不豁免(见 ProductionRootPositionTests)。
        with contextlib.redirect_stderr(io.StringIO()):
            payload = fc.parse_catalog_pointer(fixture_bytes("installable-manifest.json"),
                                               trust_root=Path("/nonexistent/pinned-root.json"),
                                               allow_unsigned=True)
        self.assertEqual(payload["catalogVersion"], 20)
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                fc.parse_catalog_pointer(b'{"payload": "!!!", "signatures": []}',
                                         trust_root=Path("/nonexistent/pinned-root.json"),
                                         allow_unsigned=True)
            except ValueError as exc:
                self.assertTrue(str(exc).startswith("指针文件形状非法"), str(exc))
            else:
                raise AssertionError("坏形状在逃生门下也必须拒")


# ================================================================ 信任根解析与投放位

class TrustRootResolutionTests(unittest.TestCase):
    def test_trust_root_resolution_order(self):
        saved = os.environ.pop("VITALIBER_MEDICAL_TRUST_ROOT", None)
        try:
            self.assertEqual(fc.resolve_trust_root_path(Path("/explicit/root.json")), Path("/explicit/root.json"))
            self.assertEqual(fc.resolve_trust_root_path(), DISTILL / "pinned-root.json")
            os.environ["VITALIBER_MEDICAL_TRUST_ROOT"] = "/env/root.json"
            self.assertEqual(fc.resolve_trust_root_path(), Path("/env/root.json"))
            self.assertEqual(fc.resolve_trust_root_path(Path("/explicit/root.json")), Path("/explicit/root.json"),
                             "命令行优先")
        finally:
            os.environ.pop("VITALIBER_MEDICAL_TRUST_ROOT", None)
            if saved is not None:
                os.environ["VITALIBER_MEDICAL_TRUST_ROOT"] = saved

    def test_ci_root_position_is_provisioned_and_not_the_test_fixture(self):
        """CI 生产根投放位不变式(2026-10-11 根投放批):缺省解析位 = 本簇脚本同目录。

        - 缺根即默认拒——llm.yml 数据门禁用 `|| echo ""` 吞错,故必须由测试钉住「根在位且自校通过」;
        - 生产位绝不能是 TEST-ONLY 夹具(其 catalog 私钥在公仓公开,等价门锁挂在门上);
        - 根过期(2028-10-05)时本测试如实转红——轮换即到期日前重放根并同批更新。
        """
        self.assertTrue(PRODUCTION_ROOT.is_file(), "CI 生产根未投放: .github/actions/distill/pinned-root.json")
        raw = PRODUCTION_ROOT.read_bytes()
        self.assertNotEqual(raw, fixture_bytes("pinned-root.json"),
                            "生产位放着 TEST-ONLY 夹具(私钥公开)——严禁与生产根混用/替换部署")
        fc.verify_pinned_root(raw, datetime.now(timezone.utc))   # 形状/范围/2-of-2 自签/有效期

    def test_production_root_refuses_fixture_signed_pointer_even_with_escape_hatch(self):
        """密钥集互斥的另一面:TEST-ONLY 夹具签的指针在生产根下验签失败,逃生门不豁免。

        (若生产位误放夹具,本测试会因「预期拒绝,实际通过」转红——与上方置放不变式双保险。)
        """
        with contextlib.redirect_stderr(io.StringIO()):
            expect_refusal(lambda: fc.parse_catalog_pointer(
                fixture_bytes("installable-manifest.json"), trust_root=PRODUCTION_ROOT,
                now=NOW, allow_unsigned=True), "2-of-2")


# ================================================================ 主流程接线(假子进程/假网络)

def _assets_for(manifest_bytes: bytes):
    return [{"name": "manifest.json", "hashValue": hashlib.sha256(manifest_bytes).hexdigest(),
             "sizeInByte": len(manifest_bytes)}]


def _wire_remote(manifest_bytes: bytes):
    """替换 tag 页/解析器/下载三个 IO 缝;返回 (downloads 记录, 恢复函数)。"""
    downloads = []
    saved = (fc.fetch_tag_page, fc._cnb_read, fc.download_asset)

    def fake_download(repository, tag, asset, dest):
        downloads.append(asset["name"])
        Path(dest).write_bytes(manifest_bytes)

    fc.fetch_tag_page = lambda repository, tag: b"<page/>"
    fc._cnb_read = lambda: SimpleNamespace(
        parse_cnb_tag_page=lambda page, repository, tag: _assets_for(manifest_bytes))
    fc.download_asset = fake_download

    def restore():
        fc.fetch_tag_page, fc._cnb_read, fc.download_asset = saved
    return downloads, restore


class MainWiringTests(unittest.TestCase):
    def test_run_remote_verifies_pointer_before_package_download(self):
        downloads, restore = _wire_remote(fixture_bytes("installable-manifest.json"))
        try:
            with tempfile.TemporaryDirectory() as tmp:
                try:
                    fc.run_remote("robinhoo1973/Resources", "medical-data", Path(tmp), False,
                                  trust_root=fixture_root_path())
                except ValueError as exc:
                    self.assertIn("缺少指针所指包资产", str(exc), f"应验签通过后卡在资产交叉校验: {exc}")
                else:
                    raise AssertionError("假页无包资产,应止步交叉校验")
            self.assertEqual(downloads, ["manifest.json"], "包未下载(先验后传)")
        finally:
            restore()

    def test_run_remote_refuses_tampered_pointer_before_any_package_download(self):
        env = envelope(fixture_bytes("installable-manifest.json"))
        tampered = reseal_payload(env, lambda p: p.__setitem__("packageAssetName", "package-19.bin"))
        downloads, restore = _wire_remote(tampered)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                expect_refusal(lambda: fc.run_remote("robinhoo1973/Resources", "medical-data", Path(tmp), False,
                                                     trust_root=fixture_root_path()), "2-of-2")
            self.assertEqual(downloads, ["manifest.json"], "验签失败必须在包下载之前拦截")
        finally:
            restore()

    def test_pointer_only_gate_applies_trust_verification(self):
        saved_argv = sys.argv
        downloads, restore = _wire_remote(fixture_bytes("installable-manifest.json"))
        try:
            with tempfile.TemporaryDirectory() as tmp:
                sys.argv = ["fetch_catalog.py", "--pointer-only", "--out-dir", tmp,
                            "--trust-root", str(fixture_root_path())]
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.assertEqual(fc.main(), 0)
                self.assertEqual(json.loads(stdout.getvalue().strip().splitlines()[-1])["catalogVersion"], 20)
        finally:
            restore()
            sys.argv = saved_argv
        tampered = reseal_payload(envelope(fixture_bytes("installable-manifest.json")),
                                  lambda p: p.__setitem__("packageAssetName", "package-19.bin"))
        downloads, restore = _wire_remote(tampered)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                sys.argv = ["fetch_catalog.py", "--pointer-only", "--out-dir", tmp,
                            "--trust-root", str(fixture_root_path())]
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    self.assertEqual(fc.main(), 1, "数据门禁面必须把验签失败打成非零(拒绝)")
                self.assertIn(REJECTION_PREFIX, stderr.getvalue())
        finally:
            restore()
            sys.argv = saved_argv


if __name__ == "__main__":
    unittest.main()
