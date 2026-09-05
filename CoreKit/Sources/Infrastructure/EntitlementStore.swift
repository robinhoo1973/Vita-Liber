#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// §5.14 EntitlementStore：权益持久化 + 额度计数。
/// 真 StoreKit 2（Transaction.updates/恢复购买）为部署项（L2 接线），
/// 本实现经协议注入 mock 交易源，逻辑可全量单测。
/// **红线模块（Documents/Observations/Medications/Search/Support）禁止读取本 store**
/// ——L0 静态断言执行（comercial §2.1 永久免费红线）。
public protocol StorefrontProviding: Sendable {
    /// 已购产品集合（生产=StoreKit 2 Transaction.currentEntitlements；
    /// 测试=注入桩）
    func currentEntitlements() async throws -> Set<ProductID>
    func purchase(_ product: ProductID) async throws -> Bool
    func restore() async throws -> Set<ProductID>
}

public actor EntitlementStore {
    private let writer: any DatabaseWriter
    private let storefront: any StorefrontProviding

    public init(writer: any DatabaseWriter, storefront: any StorefrontProviding) {
        self.writer = writer
        self.storefront = storefront
    }

    /// 配额月份键（yyyy-MM）——「20 次/月」必须有月界：单调累加会把免费档
    /// 退化成终身额度（审查修复，comercial §2.3）
    static func monthKey(_ date: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 1970, comps.month ?? 1)
    }

    /// 解析 aiMonthlyUsed 值：JSON {"month":"yyyy-MM","count":N}；旧形态
    /// 纯数字（历史装机）视为当期存量，随下次写入迁移
    static func parseUsage(_ value: String?, for month: String) -> Int {
        guard let value, !value.isEmpty else { return 0 }
        if let data = value.data(using: .utf8) {
            if let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],   // try?-ok: 历史值可能非 JSON（纯数字旧形态），解析失败回落旧形态解析
               let m = payload["month"] as? String, let c = payload["count"] as? Int {
                return m == month ? c : 0
            }
        }
        return Int(value) ?? 0
    }

    public func state() async throws -> EntitlementState {
        let owned = try await storefront.currentEntitlements()
        // 单键直取修复键值错位（原实现 SELECT * 取首行会把 aiMonthlyUsed 误读成
        // 其他键的值，导致配额误判与红线误放行）；可选链解包避免非 TEXT 值崩溃。
        let month = Self.monthKey()
        let used = try await writer.read { db -> Int in
            let row = try Row.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = 'aiMonthlyUsed'")
            guard let row else { return 0 }
            return Self.parseUsage(row["value"] as String?, for: month)
        }
        return EntitlementState(ownedProducts: owned, aiMonthlyUsed: used)
    }

    public func purchase(_ product: ProductID) async throws -> Bool {
        try await storefront.purchase(product)
    }

    public func restore() async throws -> Set<ProductID> {
        try await storefront.restore()
    }

    public func recordAIUse() async throws {
        try await writer.write { db in
            let month = Self.monthKey()
            let row = try Row.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = 'aiMonthlyUsed'")
            let rawValue: String? = row.map { $0["value"] as String? } ?? nil
            let previous = Self.parseUsage(rawValue, for: month)
            let payload: [String: Any] = ["month": month, "count": previous + 1]
            let data: Data
            do { data = try JSONSerialization.data(withJSONObject: payload) }
            catch { data = Data("{}".utf8) }
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try db.execute(sql: """
                INSERT INTO app_settings (key, value) VALUES ('aiMonthlyUsed', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [json])
        }
    }

    /// 测试/Preview 桩实现
    public actor InMemoryStorefront: StorefrontProviding {
        private var owned: Set<ProductID>
        public init(owned: Set<ProductID> = []) { self.owned = owned }
        public func currentEntitlements() async throws -> Set<ProductID> { owned }
        public func purchase(_ product: ProductID) async throws -> Bool {
            owned.insert(product)
            return true
        }
        public func restore() async throws -> Set<ProductID> { owned }
    }
}
#endif
