"""NoiseSimulator:可复现性、逐带操作数、结构噪声不越界。"""
import unittest

from entlink.noise import NoiseSimulator


class NoiseTests(unittest.TestCase):
    TEXT = "阿莫西林胶囊 每日两次"

    def test_same_seed_same_output(self):
        sim = NoiseSimulator(seed=7)
        a, _ = sim.apply(self.TEXT, "medium")
        b, _ = sim.apply(self.TEXT, "medium")
        self.assertEqual(a, b)

    def test_diff_seed_diff_output(self):
        a, _ = NoiseSimulator(seed=1).apply(self.TEXT, "heavy")
        b, _ = NoiseSimulator(seed=2).apply(self.TEXT, "heavy")
        self.assertNotEqual(a, b)

    def test_band_op_counts(self):
        for band, min_ops in [("light", 1), ("medium", 2), ("heavy", 3), ("extreme", 4)]:
            for seed in range(10):
                _, report = NoiseSimulator(seed=seed).apply(self.TEXT, band)
                self.assertGreaterEqual(report.ops_applied, min_ops, f"{band} seed={seed}")
                self.assertEqual(report.band, band)

    def test_unknown_band(self):
        with self.assertRaises(ValueError):
            NoiseSimulator(seed=0).apply(self.TEXT, "nope")

    def test_reported_layers_recorded(self):
        _, report = NoiseSimulator(seed=3).apply(self.TEXT, "extreme")
        self.assertEqual(len(report.layers_used), report.ops_applied)
        for layer in report.layers_used:
            self.assertIn(layer, ("lookalike", "homophone", "variant", "width", "punct", "deletion"))

    def test_no_identity_self_maps(self):
        # 回归:形近表不得有 k==v 恒等映射——曾把无操作计为一次噪声 op,
        # 虚增 ops_applied 并污染 manifest 登记的噪声模型
        from entlink.noise import LOOKALIKE
        self.assertFalse(any(k == v for k, v in LOOKALIKE.items()))

    def test_noise_keeps_length_sane(self):
        # 结构噪声允许 ±ops 的长度变化,但不允许雪崩
        for seed in range(20):
            out, report = NoiseSimulator(seed=seed).apply(self.TEXT, "heavy")
            self.assertLessEqual(abs(len(out) - len(self.TEXT)), report.ops_applied)


if __name__ == "__main__":
    unittest.main()
