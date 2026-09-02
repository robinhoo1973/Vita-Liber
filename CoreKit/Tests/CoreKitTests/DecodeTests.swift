import Foundation
import Testing
import Domain
import Protocols
import Infrastructure

private func testPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
}

@Suite("M-DECODE · PDF→位图解码与图片降采样（Linux 占位可跑）")
struct DecodeTests {

    @Test("decodeImage：Linux 占位返回 1x1 透明 PNG、尺寸正确", .tags(.linuxRunnable))
    func decodeImagePlaceholder() async throws {
        #if os(Linux)
        let decoder = StubPDFDecoder()
        #else
        return
        #endif

        let png = testPNG()
        let result = try await decoder.decodeImage(png, maxDimension: 2400)
        #expect(result.maxDimension == 2400)
        #expect(result.bitmapData.count > 0)
        #expect(result.originalSize.width == 1 && result.originalSize.height == 1)
    }

    @Test("decodePDF：Linux 占位返回 1 页空白、页码正确", .tags(.linuxRunnable))
    func decodePDFPlaceholder() async throws {
        #if os(Linux)
        let decoder = StubPDFDecoder()
        #else
        return
        #endif

        let pdfData = Data() // 空数据也能跑占位
        let pages = try await decoder.decodePDF(pdfData, scale: 2.0, maxPages: 50)
        #expect(pages.count == 1)
        #expect(pages[0].pageIndex == 0)
        #expect(pages[0].scale == 2.0)
        #expect(pages[0].bitmapData.count > 0)
        #expect(pages[0].originalSize.width > 0 && pages[0].originalSize.height > 0)
    }

    @Test("decodePDF：maxPages 截断不崩（Linux 占位固定 1 页）", .tags(.linuxRunnable))
    func decodePDFMaxPages() async throws {
        #if os(Linux)
        let decoder = StubPDFDecoder()
        let pdfData = Data()
        let pages = try await decoder.decodePDF(pdfData, scale: 1.0, maxPages: 1)
        #expect(pages.count <= 1)
        #else
        return
        #endif
    }

    @Test("DecodedImage/DecodedPage Codable 往返", .tags(.linuxRunnable))
    func codableRoundtrip() throws {
        let img = DecodedImage(bitmapData: Data([1,2,3]), originalSize: Size(width: 100, height: 200), maxDimension: 1000)
        let data = try JSONEncoder().encode(img)
        let decoded = try JSONDecoder().decode(DecodedImage.self, from: data)
        #expect(decoded == img)

        let page = DecodedPage(pageIndex: 0, bitmapData: Data([4,5,6]), originalSize: Size(width: 595, height: 842), scale: 2.0)
        let pdata = try JSONEncoder().encode(page)
        let pdecoded = try JSONDecoder().decode(DecodedPage.self, from: pdata)
        #expect(pdecoded == page)
    }

    @Test("DecodeError 可比较", .tags(.linuxRunnable))
    func errorEquatable() {
        #expect(DecodeError.corruptData == DecodeError.corruptData)
        #expect(DecodeError.corruptData != DecodeError.unsupportedFormat)
    }
}