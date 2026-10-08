#!/usr/bin/env python3
"""ASR 家族/档位常量（轻依赖模块）。

2026-10-08：自 asr_package 拆出——asr_package 经 asr_envelope 拖入
cryptography，凡只需家族/档位集合的轻工具（bootstrap 漂移检查等）不应被迫
安装加解密依赖（CI maintenance drift job `ModuleNotFoundError: cryptography`
实证）。asr_package 继续 re-export 本模块常量，既有消费面零改动；
新增轻工具一律从本模块取常量。
"""

MODELS = {"qwen3", "zipformer", "dolphin", "whisper", "sense-voice", "fire-red", "moonshine"}
# 尺寸档位(FR17.15):按上游真实档名(whisper tiny/base/small/medium/turbo 等),
# 每模型家族 1..5 档,上游缺档如实缺省(2026-10-05 委员会:iOS 适用性评估后扩档)。
VARIANTS = {"tiny", "base", "small", "medium", "large", "turbo"}
