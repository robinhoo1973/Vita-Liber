import Foundation
import Domain
import Protocols

/// M1a 假 OCR（评审 S2 修正：生产代码不得含 -uitest 分支——
/// 分支收敛到本 provider 的构造参数，AppState 只面向 DocumentCapture 协议）。
/// 结构对齐 §5.2/5.3（CandidateField + 置信度三档）；M1b 换真 Vision 管线，协议不变。
struct FakeOcrProvider: DocumentCapture {
    let fixture: Bool

    func capture() async throws -> OcrConfirmationSet {
        let title = fixture ? "处方样张 · 阿莫西林" : "演示样张 · 处方"
        return OcrConfirmationSet(fields: [   // confirm-ok: F6 OCR 提供者是确认集合法产出方（非语音路径），FR17.13 只约束语音草稿确认
            CandidateField(key: "drug_name", displayLabel: "药名",
                           rawText: "阿莫西林胶囊 0.25g", confidence: fixture ? 0.93 : 0.91),
            CandidateField(key: "dosage", displayLabel: "剂量与用法",
                           rawText: "每日三次 每次一粒", confidence: fixture ? 0.88 : 0.86),
            CandidateField(key: "title", displayLabel: "标题",
                           rawText: title, confidence: 0.98),
        ])
    }
}
