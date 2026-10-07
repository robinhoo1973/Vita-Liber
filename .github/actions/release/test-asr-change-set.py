#!/usr/bin/env python3
"""test-asr-change-set：变化集单源五态钉（2026-10-08 文案链批，纯离线）。

状态矩阵（沿用发布页既有省略语义）：首发布 None / 同版本 None / 回退 None /
正常增量三元组 / 版本递增但内容全同 = 空三元组（消费方渲染「无变化」行）。
"""
import unittest

from asr_change_set import change_set, tier_key


def _payload(version, models):
    return {"catalogVersion": version, "index": {"models": models}}


def _tier(variant, digest):
    return {"id": "whisper", "variant": variant, "version": "v1", "sha256": digest}


class ChangeSetTests(unittest.TestCase):
    def test_first_publish_is_none(self):
        self.assertIsNone(change_set(None, _payload(7, [_tier("tiny", "a" * 64)])))

    def test_same_version_is_none(self):
        payload = _payload(7, [_tier("tiny", "a" * 64)])
        self.assertIsNone(change_set(payload, payload))

    def test_rollback_version_is_none(self):
        self.assertIsNone(change_set(_payload(8, []), _payload(7, [])))

    def test_delta_triplet(self):
        previous = _payload(6, [_tier("tiny", "a" * 64), _tier("base", "b" * 64)])
        current = _payload(7, [_tier("tiny", "c" * 64), _tier("small", "d" * 64)])
        added, updated, removed = change_set(previous, current)
        self.assertEqual([tier_key(m) for m in added], [("whisper", "small")])
        self.assertEqual([tier_key(m) for m in updated], [("whisper", "tiny")])
        self.assertEqual([tier_key(m) for m in removed], [("whisper", "base")])

    def test_version_bump_with_identical_content_is_empty_triplet(self):
        previous = _payload(6, [_tier("tiny", "a" * 64)])
        current = _payload(7, [_tier("tiny", "a" * 64)])
        result = change_set(previous, current)
        self.assertIsNotNone(result)
        self.assertEqual([len(part) for part in result], [0, 0, 0])

    def test_malformed_previous_degrades_to_none(self):
        self.assertIsNone(change_set({"catalogVersion": "not-a-number"}, _payload(7, [])))


if __name__ == "__main__":
    unittest.main()
