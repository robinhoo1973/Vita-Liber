import Foundation
import Testing
@testable import Domain

@Suite struct ValueBoxTests {
    @Test func readWriteRoundTripsUnderConcurrency() async {
        let box = ValueBox<Int>()
        #expect(box.value == nil)
        box.value = 42
        #expect(box.value == 42)
        // 并发读写不崩不死锁：多任务各写各读
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    box.value = i
                    _ = box.value
                }
            }
        }
        #expect(box.value != nil)
    }

    @Test func storingInnerNilIsDistinctFromNeverSet() {
        // ValueBox<Int?> 的存储是 Int??：`.some(nil)` 表示「存过、值为 nil」，
        // 与「从未设置」（外层 nil）可区分
        let box = ValueBox<Int?>()
        #expect(box.value == nil)
        box.value = .some(nil)
        #expect(box.value != nil)
        #expect(box.value == .some(nil))
    }
}
