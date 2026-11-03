import Foundation
import Testing
@testable import Domain

@Suite("SU-OCRB-CONSENSUS · PP-OCRv6 CTC 解码")
struct CTCDecoderTests {
    @Test("去 blank、去连续重复、按词表取字")
    func collapsesBlanksAndRepeats() {
        // classes = 4: blank, A, B, space
        let vocab = ["", "A", "B", " "]
        // T=6: A, A, blank, B, space, B
        let rows: [[Float]] = [
            [0.1, 0.8, 0.05, 0.05],
            [0.1, 0.7, 0.1, 0.1],
            [0.9, 0.02, 0.04, 0.04],
            [0.1, 0.05, 0.8, 0.05],
            [0.1, 0.05, 0.1, 0.75],
            [0.1, 0.05, 0.8, 0.05],
        ]
        let output = CTCDecoder.decode(probabilities: rows.flatMap { $0 }, timesteps: 6,
                                       classes: 4, vocabulary: vocab)
        #expect(output.text == "AB B")
        #expect(output.emittedCharacters == 4)
        #expect(output.confidence > 0.7 && output.confidence <= 0.9)
    }

    @Test("空张量/词表不匹配返回空")
    func invalidInputsReturnEmpty() {
        #expect(CTCDecoder.decode(probabilities: [], timesteps: 0, classes: 4,
                                  vocabulary: [""]).text.isEmpty)
        #expect(CTCDecoder.decode(probabilities: [1, 0, 0, 0], timesteps: 1, classes: 4,
                                  vocabulary: ["", "A"]).text.isEmpty)
    }
}
