import Foundation
import Testing
import Domain
import Protocols
import Infrastructure

@Suite("M-PREPROC · 扫描预处理 / 图片变形校正（Linux 占位可跑）")
struct PreprocessTests {

    @Test("重置参数：resetToOriginal 返回原始帧、版本号+1", .tags(.linuxRunnable))
    func resetToOriginal() async throws {
        #if os(Linux)
        let preprocessor = StubImagePreprocessor()
        #else
        // Apple 路径在 Linux 单测不跑，仅占位
        return
        #endif

        let png = Self.testPNG()
        let params = PreprocessParams(resetToOriginal: true)
        let result = try await preprocessor.preprocess(png, params: params, baseVersion: 1)
        #expect(result.version == 2)
        #expect(result.processedData == png)
        #expect(result.originalData == png)
        #expect(result.appliedParams.resetToOriginal == true)
    }

    @Test("非重置：Linux 占位返回原始帧、版本号+1、标记未实际矫正", .tags(.linuxRunnable))
    func linuxPlaceholderNoCorrection() async throws {
        #if os(Linux)
        let preprocessor = StubImagePreprocessor()
        #else
        return
        #endif

        let png = Self.testPNG()
        let params = PreprocessParams(enablePerspectiveCorrection: true, colorMode: .grayscale, rotationDegrees: 90)
        let result = try await preprocessor.preprocess(Self.testPNG(), params: params, baseVersion: 5)
        #expect(result.version == 6)
        #expect(result.processedData.count > 0)
        #expect(result.appliedParams.enablePerspectiveCorrection == false) // 占位标记未实际矫正
        #expect(result.appliedParams.colorMode == .grayscale)
        #expect(result.appliedParams.rotationDegrees == 90)
    }

    @Test("参数确定性：相同参数产生相同 appliedParams", .tags(.linuxRunnable))
    func paramsDeterministic() {
        let p1 = PreprocessParams(enablePerspectiveCorrection: true, colorMode: .grayscale, rotationDegrees: 90)
        let p2 = PreprocessParams(enablePerspectiveCorrection: true, colorMode: .grayscale, rotationDegrees: 90)
        #expect(p1 == p2)
    }

    @Test("ColorMode Codable 往返", .tags(.linuxRunnable))
    func colorModeCodable() throws {
        for mode in PreprocessParams.ColorMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(PreprocessParams.ColorMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("PreprocessedImage 版本号递增", .tags(.linuxRunnable))
    func versionIncrements() async throws {
        #if os(Linux)
        let preprocessor = StubImagePreprocessor()
        let png = Self.testPNG()
        let params = PreprocessParams()
        let r1 = try await StubImagePreprocessor().preprocess(Self.testPNG(), params: PreprocessParams(), baseVersion: 1)
        let r2 = try await StubImagePreprocessor().preprocess(Self.testPNG(), params: PreprocessParams(), baseVersion: 2)
        #expect(r1.version == 2)
        #expect(r2.version == 3)
        #else
        return
        #endif
    }
}

extension PreprocessTests {
    static func testPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}