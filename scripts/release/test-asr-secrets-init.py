#!/usr/bin/env python3
"""init_asr_secrets 引导逻辑回归(2026-10-05):决策/改写/解析全部走纯函数,
gh 网络调用不参与(引导失败语义 = CI 硬红,本地必须可独立验证)。"""
import tempfile
import unittest
from pathlib import Path

from init_asr_secrets import (KEY_RE, generate_key, parse_secret_names, plan,
                              read_swift_key, read_test_key, rewrite_embedded_key)

OLD_KEY = "a" * 64
OTHER_KEY = "b" * 64

SWIFT_SOURCE = """    /// 主密钥（hex，与 CI secret ASR_PACKAGE_KEY 同值）。
    private static let masterKeyHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    static func identity(id: String) -> String { id }
"""

TEST_SOURCE = """TEST_PACKAGE_KEY = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ROLES = {}
"""


class PlanTests(unittest.TestCase):
    def test_noop_when_env_matches_embedded(self):
        action, _ = plan(OLD_KEY, "", OLD_KEY, OLD_KEY)
        self.assertEqual(action, "noop")

    def test_fail_when_env_key_malformed(self):
        action, message = plan("xyz", "", OLD_KEY, OLD_KEY)
        self.assertEqual(action, "fail")
        self.assertIn("64-hex", message)

    def test_fail_when_swift_key_missing(self):
        action, _ = plan(OLD_KEY, "", None, OLD_KEY)
        self.assertEqual(action, "fail")

    def test_fail_when_env_mismatches_swift(self):
        action, message = plan(OLD_KEY, "", OTHER_KEY, OLD_KEY)
        self.assertEqual(action, "fail")
        self.assertIn("不一致", message)

    def test_fail_when_env_mismatches_test_constant(self):
        action, _ = plan(OLD_KEY, "", OLD_KEY, OTHER_KEY)
        self.assertEqual(action, "fail")

    def test_fail_without_token_when_missing(self):
        action, message = plan("", "", OLD_KEY, OLD_KEY)
        self.assertEqual(action, "fail")
        self.assertIn("ASR_ADMIN_TOKEN", message)

    def test_generate_with_token_when_missing(self):
        action, _ = plan("", "ghp_admin", OLD_KEY, OLD_KEY)
        self.assertEqual(action, "generate")

    def test_env_key_comparison_is_case_insensitive(self):
        action, _ = plan(OLD_KEY.upper(), "", OLD_KEY, OLD_KEY)
        self.assertEqual(action, "noop")


class RewriteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.swift = Path(self.temporary.name) / "ASRPackageCrypto.swift"
        self.test = Path(self.temporary.name) / "test-asr-package-integrity.py"
        self.swift.write_text(SWIFT_SOURCE, encoding="utf-8")
        self.test.write_text(TEST_SOURCE, encoding="utf-8")

    def test_generate_key_format(self):
        first, second = generate_key(), generate_key()
        self.assertRegex(first, KEY_RE)
        self.assertNotEqual(first, second)

    def test_rewrite_updates_both_files(self):
        key = "c" * 64
        changed = rewrite_embedded_key(self.swift, self.test, key)
        self.assertEqual(set(changed), {str(self.swift), str(self.test)})
        self.assertEqual(read_swift_key(self.swift), key)
        self.assertEqual(read_test_key(self.test), key)
        # 除密钥字面量外的行保持逐字节不变
        swift_text = self.swift.read_text(encoding="utf-8")
        self.assertIn("/// 主密钥（hex，与 CI secret ASR_PACKAGE_KEY 同值）。", swift_text)
        self.assertIn("static func identity(id: String) -> String { id }", swift_text)
        self.assertIn("ROLES = {}", self.test.read_text(encoding="utf-8"))

    def test_rewrite_missing_constant_raises(self):
        self.swift.write_text("no key here", encoding="utf-8")
        with self.assertRaises(ValueError):
            rewrite_embedded_key(self.swift, self.test, "d" * 64)

    def test_read_key_missing_file_returns_none(self):
        self.assertIsNone(read_swift_key(Path(self.temporary.name) / "nope.swift"))
        self.assertIsNone(read_test_key(Path(self.temporary.name) / "nope.py"))


class ParseSecretNamesTests(unittest.TestCase):
    def test_parses_plain_table(self):
        text = ("ASR_PACKAGE_KEY\t2026-10-05\tAll environments\n"
                "CNB_RESOURCE_TOKEN\t2026-10-04\tAll environments\n")
        self.assertEqual(parse_secret_names(text), {"ASR_PACKAGE_KEY", "CNB_RESOURCE_TOKEN"})

    def test_skips_header_and_blank(self):
        text = "NAME\tUPDATED\tVISIBILITY\n\nASR_SIGNING_KEYS_JSON\t2026-10-05\tAll environments\n"
        self.assertEqual(parse_secret_names(text), {"ASR_SIGNING_KEYS_JSON"})

    def test_empty_output_no_names(self):
        self.assertEqual(parse_secret_names(""), set())


if __name__ == "__main__":
    unittest.main()
