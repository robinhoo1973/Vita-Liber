import Foundation
import Testing
@testable import Domain

/// P3c 升层后的下载值类型纯函数（2026-09-27 委员会测试席②：三次进度 bug 病灶
/// 提纯为 Linux 可跑的回归断言——系列语义/钳制/磁盘满映射不再靠 macOS 才见）。
struct ASRDownloadProgressTests {

    @Test func fractionClampsToUnitRange() {
        var p = ASRDownloadProgress(receivedBytes: 150, totalBytes: 100)
        #expect(p.fraction == 1.0, "回滚/计数修正可使 received 超 total——钳制是 2026-09-20 修复")
        p.receivedBytes = 0; p.totalBytes = 0
        #expect(p.fraction == 0, "total 为零不得除零")
        p.receivedBytes = 50; p.totalBytes = 200
        #expect(p.fraction == 0.25)
    }

    @Test func monotonicGuardAcceptsAcrossSeriesAndRejectsSameSeriesRegression() {
        // 三次进度 bug 病灶：跨系列必须放行（单流重建/阶段换代从 0 重计）；
        // 同系列 received 回退必须拒（旧值迟到）。
        let segmented = ASRDownloadProgress(receivedBytes: 800, totalBytes: 1000, series: 0)
        let rebuiltSingle = ASRDownloadProgress(receivedBytes: 10, totalBytes: 1000, series: 1)
        #expect(ASRDownloadProgress.shouldAccept(previous: segmented, incoming: rebuiltSingle), "跨系列一律放行")
        let stale = ASRDownloadProgress(receivedBytes: 700, totalBytes: 1000, series: 0)
        #expect(!ASRDownloadProgress.shouldAccept(previous: segmented, incoming: stale), "同系列回退必须拒")
        #expect(ASRDownloadProgress.shouldAccept(previous: nil, incoming: stale), "首帧恒放行")
    }

    @Test func monotonicGuardAcceptsEqualReceivedToPropagateTotalCorrection() {
        // 2026-10-03 评审 R1-10a 登记的行为差异：received 相等时 Domain 收、旧 App 复本拒——
        // 收下可让「received 相等但 totalBytes 被服务端修正」的回调入账（更诚实的方向）。
        let current = ASRDownloadProgress(receivedBytes: 500, totalBytes: 1000, series: 0)
        let corrected = ASRDownloadProgress(receivedBytes: 500, totalBytes: 1200, series: 0)
        #expect(ASRDownloadProgress.shouldAccept(previous: current, incoming: corrected))
    }

    @Test func determinatePresentationFollowsByteGranularPhases() {
        let p = ASRDownloadProgress(receivedBytes: 10, totalBytes: 100)
        #expect(ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: nil), "nil 阶段=传输基线，画确定条")
        #expect(ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: .downloading))
        #expect(ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: .verifying))
        #expect(ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: .unpacking))
        #expect(!ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: .activating), "激活无字节粒度，如实不确定")
        #expect(!ASRDownloadProgress.showsDeterminateProgress(progress: p, phase: .pruning))
        #expect(!ASRDownloadProgress.showsDeterminateProgress(progress: nil, phase: .downloading), "无进度值不画 0% 确定条")
    }

    @Test func storageErrorMappingRecognizesPOSIXAndCocoaForms() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 640)  // NSFileWriteOutOfSpaceError
        #expect(ASRDownloadFailure.storageError(from: cocoa) == .insufficientStorage)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 28)   // ENOSPC
        #expect(ASRDownloadFailure.storageError(from: posix) == .insufficientStorage)
        let wrapped = NSError(domain: "test", code: 999, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(ASRDownloadFailure.storageError(from: wrapped) == .insufficientStorage, "底层 ENOSPC 穿透")
        let network = NSError(domain: NSURLErrorDomain, code: -1009)  // notConnectedToInternet
        #expect(ASRDownloadFailure.storageError(from: network) == nil, "网络错误不得误判磁盘满")
    }
}
