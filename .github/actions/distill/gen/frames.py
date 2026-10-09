"""CI 侧帧族后处理器(纯字符串层,零依赖;E3 修复的 CI 一半,2026-10-09)。

为什么存在(E3;training-goals.md §2/§4.1)
-----------------------------------------
CI SFT 渲染(gen/sft_dataset.py)此前对模板注入的空 think 段(EMPTY_THINK)做
**100% 剥离**(MiniMind/Qwen2 契约);而部署件 Qwen3-0.6B 运行时**保留**空 think
段(Resources/LLMCatalog/catalog.json 条目 `"frame": "qwen3-nothink"`;Swift 侧
ExtractionPromptBuilder.ChatFrameStyle.qwen3NonThinking)。训练帧族与部署帧不一致
= 「训练/推理不同分布」复发(E3)。本模块把「剥离 vs 保留」下沉为纯函数参数
`family`——取值与训练机正本 refactor/tools/training/shared/trainlib/frames.py
**同名同义**,两侧常量逐字相等由 tests/test_gen_frames_sync.py 合成断言
(训练机树不在 CI 检出时该断言 skip;Swift 帧金样在 CoreKit Qwen3ChatFrameTests)。

帧族(取值 ↔ catalog 条目 frame / Swift ChatFrameStyle rawValue)
---------------------------------------------------------------
- `minimind-strip`(默认):剥离全部空 think 段——CI 旧行为(冻结语料与模板
  渲染逐字节不变;惰性默认),对应 Swift `ChatFrameStyle.chatML`(rawValue "chatml")。
- `qwen3-nothink`:仅**末段** assistant 保留空 think 段(其余段剥离)——与 Qwen3
  官方模板 loop.last 分支、本地 frames.py 的 final 语义、部署帧逐字节同文,
  对应 Swift `ChatFrameStyle.qwen3NonThinking`(rawValue 与 catalog frame 同字面)。

激活方式(默认惰性)与产物落点
-----------------------------
默认族=minimind-strip,行为与参数化之前完全一致;训 Qwen3 目标件时由训练入口
显式传 `--frame-family qwen3-nothink`(见 gen/train_sft_smoke.py),帧族随该次
训练 summary/checkpoint meta 落产物——供下游机械断言
「训练帧族 == catalog 条目 frame」(E3 一致性闸;P3「帧与预算契约」批的输入)。

mask 口径(登记,不在本模块):qwen3-nothink 下 EMPTY_THINK 属**提示词**
(部署端已放进 prompt),监督窗口应自 think 段之后开始——把 think 段纳入监督会
教模型自己产出 think 段(本地 frames.py 同句)。CI 标签窗口调整属 P3 批
(「帧与预算契约」;本模块只做字符串层,不产 token)。

fail-closed 守卫
----------------
- 未知 family → ValueError(绝不静默落回默认族);
- qwen3-nothink 而渲染流不含空 think 段 → ValueError(模板未注入即帧契约不成立,
  静默放行=产出与部署异分布的训练流)。
"""
EMPTY_THINK = "<think>\n\n</think>\n\n"

FAMILY_MINIMIND_STRIP = "minimind-strip"
FAMILY_QWEN3_NOTHINK = "qwen3-nothink"
FAMILIES = (FAMILY_MINIMIND_STRIP, FAMILY_QWEN3_NOTHINK)
# 默认 = 旧 chatML 帧(参数化前行为;与本地 frames.py DEFAULT_FAMILY 同值)
DEFAULT_FAMILY = FAMILY_MINIMIND_STRIP


def checked_family(family):
    """帧族合法性守卫(fail-closed;与本地 frames.py._checked_family 同语义)。"""
    if family not in FAMILIES:
        raise ValueError(f"未知帧族 {family!r}（可选：{', '.join(FAMILIES)}）")
    return family


def apply_frame_family(text, family=DEFAULT_FAMILY):
    """把（chat 模板渲染出的）全文流按帧族后处理。

    minimind-strip：剥离**全部**空 think 段(即参数化前的 100% 剥离行为)。
    qwen3-nothink：仅保留**最后一个**空 think 段(末段 assistant;中间段剥离)——
    与 Qwen3 官方模板 loop.last 分支/本地 frames.py `final` 语义一致；契约要求
    末段必有该段,缺即 ValueError(fail-closed)。
    """
    checked_family(family)
    if family == FAMILY_MINIMIND_STRIP:
        return text.replace(EMPTY_THINK, "")
    index = text.rfind(EMPTY_THINK)
    if index < 0:
        raise ValueError(
            "帧族 qwen3-nothink 要求渲染流含空 think 段(末段 assistant)——模板未注入"
            "即帧契约不成立(fail-closed;部署帧含该段,缺失=训练/推理异分布)"
        )
    # index 之前(含中间 assistant 段)的 think 段剥离;index 起的末段保留
    return text[:index].replace(EMPTY_THINK, "") + text[index:]
