#if os(Linux)
import Foundation
import Domain
import Protocols

/// M-PREPROC Linux/dev 兜底：无 OpenCV 依赖，返回占位（保证 Linux 构建/测试可跑）。
///
/// - 若启用透视矫正/色彩模式/旋转，仅返回原始帧并标记版本号。
/// - 真实 Linux 环境如需真实预处理，可接入 OpenCV（仅 CI 兜底，不进生产）。
public struct StubImagePreprocessor: ImagePreprocessing {
    public init() {}

    public func preprocess(_ originalData: Data, params: PreprocessParams, baseVersion: Int) async throws -> PreprocessedImage {
        guard !params.resetToOriginal else {
            return PreprocessedImage(processedData: originalData,
                                     originalData: originalData,
                                     appliedParams: params,
                                     version: baseVersion + 1)
        }
        // 占位：直接返回原始帧，版本号+1，标记已尝试处理
        var p = params
        p.enablePerspectiveCorrection = false // 标记未实际矫正
        return PreprocessedImage(processedData: originalData,
                                 originalData: originalData,
                                 appliedParams: p,
                                 version: baseVersion + 1)
    }
}
#endif