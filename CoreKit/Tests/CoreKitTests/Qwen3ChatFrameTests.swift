import Foundation
import Testing
@testable import Domain

/// ChatML 封帧金样（2026-10-09 换型批：帧构造自 Infrastructure 下沉，金样钉死）。
///
/// 断言的是**逐字节**形态——训练侧（tokenizer chat_template 渲染）与推理侧
/// （本函数）必须同文；任何一侧漂移都会在此处可见（Qwen3 换型的核心契约）。
@Suite("ChatML 帧金样（Domain）")
struct Qwen3ChatFrameTests {

    @Test func chatMLFrameMatchesLegacyByteForByte() {
        // 现役 Qwen2.5/minimind 形态（EMPTY_THINK 剥离后）：assistant 头直连内容
        let frame = ExtractionPromptBuilder.chatML(system: "SYS", user: "USR", frame: .chatML)
        #expect(frame == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSR<|im_end|>\n<|im_start|>assistant\n")
        #expect(!frame.contains("<think>"))
    }

    @Test func qwen3NonThinkingKeepsEmptyThinkSegment() {
        let frame = ExtractionPromptBuilder.chatML(system: "SYS", user: "USR", frame: .qwen3NonThinking)
        #expect(frame == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSR<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(frame.hasSuffix(ExtractionPromptBuilder.emptyThinkSegment))
    }

    @Test func emptyThinkSegmentIsLiteralLockedToTrainingSide() {
        // 与 .github/actions/distill/gen/sft_dataset.py 的 EMPTY_THINK 同字面（两侧同升纪律）。
        #expect(ExtractionPromptBuilder.emptyThinkSegment == "<think>\n\n</think>\n\n")
    }

    @Test func defaultFrameIsLegacyChatML() {
        #expect(ExtractionPromptBuilder.chatML(system: "S", user: "U")
                == ExtractionPromptBuilder.chatML(system: "S", user: "U", frame: .chatML))
    }
}
