import Testing
import Foundation
import Domain
@testable import Infrastructure

@Test func 外键开启且悬空引用被拒_技术4点3() throws {
    let store = try GRDBStore()
    #expect(store.foreignKeysOn)
    #expect(throws: (any Error).self) {
        try store.dbQueue.write { try $0.execute(sql: "INSERT INTO document_file VALUES ('d1','ghost',NULL,0)") }
    }
}
