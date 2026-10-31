#if canImport(Compression)
// linux-blind: Compression 仅 Apple 平台；Linux 编译空单元（预推钩子 [2]）。
import Compression
import Foundation

public enum CatalogSliceLeafletFailure: Error, Equatable {
    case unavailable
    case legacySchema
    case corruptText
}

enum CatalogSliceLeafletCodec {
    static func inflate(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        var capacity = max(64, data.count * 8)
        while capacity <= 64 * 1024 * 1024 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&buffer, buffer.count, base, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
            if written > 0 && written < capacity {
                return String(decoding: buffer[0..<written], as: UTF8.self)
            }
            capacity *= 4
        }
        return nil
    }
}
#endif
