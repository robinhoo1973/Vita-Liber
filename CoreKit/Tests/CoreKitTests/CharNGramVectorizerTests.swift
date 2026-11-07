import Testing
import Foundation
@testable import Domain

/// 训练（Python `scanned_coreml_train.py`）与推理（Swift）共用同一向量化：
/// 这些断言是跨语言契约的钉子。改动算法必须同步 bump catalog 的
/// `featureVersion` 并重训，不得只改一侧。
@Suite("Char n-gram vectorizer parity")
struct CharNGramVectorizerTests {
    @Test("department line matches the Python fixture")
    func departmentFixture() {
        let vector = CharNGramVectorizer.vector(text: "科室：骨科门诊", kind: "encounter", dimension: 4096)
        #expect(vector.reduce(0, +) > 0)
        #expect(abs(vector[3782] - 0.436436) < 1e-5)
        #expect(abs(vector[266] - 0.218218) < 1e-5)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-9)
    }

    @Test("kind token participates and changes the vector")
    func kindToken() {
        let without = CharNGramVectorizer.vector(text: "阿莫西林胶囊", kind: nil, dimension: 4096)
        let encounter = CharNGramVectorizer.vector(text: "阿莫西林胶囊", kind: "encounter", dimension: 4096)
        let prescription = CharNGramVectorizer.vector(text: "阿莫西林胶囊", kind: "prescription", dimension: 4096)
        #expect(without != encounter)
        #expect(encounter != prescription)
    }

    @Test("empty text with a kind still yields a unit vector")
    func emptyText() {
        let vector = CharNGramVectorizer.vector(text: "", kind: "prescription", dimension: 4096)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-9)
    }

    @Test("dimension zero is rejected instead of crashing")
    func zeroDimension() {
        #expect(CharNGramVectorizer.vector(text: "x", kind: nil, dimension: 0).isEmpty)
    }
}
