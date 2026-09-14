import Foundation
import Domain

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §5）：按卡 spec 抽取的三轨同一端口 + 逐区域失败切换注册表。
/// T1 Foundation Models（E4）/ T2 llama.cpp 本机 LLM（子项目 F）/ T3 规则（E3）都实现 `CardExtractionEngine`；
/// grounding **不在引擎内**——注册表对每个区域结果统一执行 `ExtractionGrounding.validate`（第二道防线，design §4.6）。
/// 全部产物恒 D 级（BR-003）；零网络；不读 `EntitlementStore`（识别后理解属信任/安全面永久免费）。

/// 一页一次抽取请求：版面区域 + 候选 spec；`pageBudget` = 单页生成轨总预算（design §5.6，nil = 不限），
/// 耗尽后剩余区域只走规则轨；`allowsGenerativeProcessing == false` 时 T1/T2 一律不调用（授权门，design §5.2）。
public struct ExtractionRequest: Sendable {
    public var pageIndex: Int, lines: [String], regions: [ExtractionRegion], specs: [ExtractionSpec]
    public var allowsGenerativeProcessing: Bool, pageConfidence: Double, pageBudget: Duration?
    public init(pageIndex: Int, lines: [String], regions: [ExtractionRegion], specs: [ExtractionSpec],
                allowsGenerativeProcessing: Bool, pageConfidence: Double, pageBudget: Duration? = nil) {
        self.pageIndex = pageIndex; self.lines = lines; self.regions = regions; self.specs = specs
        self.allowsGenerativeProcessing = allowsGenerativeProcessing; self.pageConfidence = pageConfidence; self.pageBudget = pageBudget
    }
}

/// 单区域原始结果（未 grounding）。
public struct RegionExtraction: Sendable, Equatable {
    public var shared: [String: GroundedValue], rows: [[String: GroundedValue]]
    public init(shared: [String: GroundedValue], rows: [[String: GroundedValue]]) { self.shared = shared; self.rows = rows }
    public var isEmpty: Bool { shared.isEmpty && rows.allSatisfy(\.isEmpty) }
    public var valueCount: Int { shared.count + rows.reduce(0) { $0 + $1.count } }
}

public enum EngineAvailability: Sendable, Equatable { case available, unavailable(DegradedReason) }

public enum ExtractionEngineError: Error, Sendable { case unavailable, modelBusy, schemaMismatch }

/// 三轨同一端口（design §5.1）。`regionTimeout == nil` = 不限（规则轨）。
public protocol CardExtractionEngine: Sendable {
    var track: ExtractionTrack { get }
    var regionTimeout: Duration? { get }
    func availability(for request: ExtractionRequest) async -> EngineAvailability
    func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction
}

/// 有序轨道链 · 能力探测 · 逐区域失败切换 · 缩范围重试 · (row, key) 并集（design §5.3）：
/// - 超时 → 该区域切下一轨（`timedOutRegions += 1`，`degradedReason = .timeout`），已完成区域保留；
/// - 引擎抛错 → 该轨本会话内禁用，后续区域直接下一轨（`.engineError`）；
/// - grounding 产出率（锚定值 / 产出值）< 0.5 → 生成轨同轨**一次**缩范围重试（`spec.narrowed()`）；仍低 → 保留已锚定值，
///   下一轨对该区域补跑，两轨结果并集（`.lowGrounding`）；零产出 → 不重试直接下一轨；
/// - 不可用 / 未授权 / 页预算耗尽 → 跳过该轨并记录首个降级原因。
/// 卡级主轨 = 首个有锚定产出的轨；`mixedTracks` = 多轨均有产出；`regionTracks` 逐区域登记。
public actor CardExtractionRegistry {
    private let engines: [any CardExtractionEngine]
    public init(engines: [any CardExtractionEngine]) { self.engines = engines }

    private enum Outcome { case success(RegionExtraction), timeout, failure }
    /// design §5.3：必填倾向字段锚定率门槛。
    static let groundingThreshold = 0.5

    public func extract(_ request: ExtractionRequest) async -> [ExtractedCard] {
        var cards: [ExtractedCard] = []
        let pageStarted = ContinuousClock.now   // 页预算按整页计（多 spec 共用），durationMs 按卡计
        for spec in request.specs {
            let started = ContinuousClock.now
            var card = ExtractedCard(kind: spec.kind, pageIndex: request.pageIndex, shared: [:], rows: [],
                                     provenance: ExtractionProvenance(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                     diagnostics: ExtractionDiagnostics(track: .rules))
            var disabled = Set<ExtractionTrack>()
            var used: [ExtractionTrack] = []
            func degrade(_ reason: DegradedReason) { if card.diagnostics.degradedReason == .none { card.diagnostics.degradedReason = reason } }

            for region in request.regions {
                var merged = RegionExtraction(shared: [:], rows: [])
                var contributors: [ExtractionTrack] = []
                var regionDone = false
                for engine in engines where !disabled.contains(engine.track) && !regionDone {
                    let generative = engine.track != .rules
                    if generative, !request.allowsGenerativeProcessing { degrade(.notAuthorized); continue }
                    if generative, let budget = request.pageBudget, ContinuousClock.now - pageStarted > budget { degrade(.timeout); continue }
                    let availability = await engine.availability(for: request)
                    guard case .available = availability else {
                        if case .unavailable(let reason) = availability { degrade(reason) }
                        continue
                    }
                    var attempt = spec
                    var retried = false
                    while true {
                        switch await run(engine, region: region, spec: attempt, request: request) {
                        case .timeout:
                            card.diagnostics.timedOutRegions += 1
                            card.diagnostics.degradedReason = .timeout
                        case .failure:
                            disabled.insert(engine.track)
                            card.diagnostics.degradedReason = .engineError
                        case .success(let raw):
                            let probe = ExtractedCard(kind: spec.kind, pageIndex: request.pageIndex, shared: raw.shared, rows: raw.rows,
                                                      provenance: card.provenance, diagnostics: card.diagnostics)
                            let (grounded, dropped) = ExtractionGrounding.validate(probe, spec: attempt, lines: request.lines)
                            card.diagnostics.droppedUngrounded += dropped
                            let result = RegionExtraction(shared: grounded.shared, rows: grounded.rows)
                            let ratio = raw.valueCount == 0 ? 0 : Double(result.valueCount) / Double(raw.valueCount)
                            if ratio < Self.groundingThreshold, raw.valueCount > 0, generative, !retried {
                                attempt = spec.narrowed(); retried = true; card.diagnostics.retries += 1
                                continue   // 同轨缩范围重试一次（design §5.3）
                            }
                            merged = union(merged, result, anchor: spec.rowAnchor)
                            if !result.isEmpty {
                                if !used.contains(engine.track) { used.append(engine.track) }
                                contributors.append(engine.track)
                            }
                            if ratio >= Self.groundingThreshold || !generative {
                                regionDone = true
                            } else if raw.valueCount > 0 {
                                card.diagnostics.degradedReason = .lowGrounding
                            }
                        }
                        break
                    }
                }
                card.shared.merge(merged.shared) { first, _ in first }   // 共享同键：先到先得（表头字段重复印刷）
                card.rows += merged.rows                                  // 行级：全部保留（O-N3 不再丢第二值）
                if !contributors.isEmpty { card.diagnostics.regionTracks[region.id] = contributors }
            }
            card.provenance.track = used.first ?? .rules
            card.diagnostics.track = card.provenance.track
            card.diagnostics.mixedTracks = used.count > 1
            card.provenance.durationMs = Int((ContinuousClock.now - started) / .milliseconds(1))
            cards.append(card)
        }
        return cards
    }

    /// 单区域单轨一次调用：无超时直跑；有超时则与睡眠竞速，先到者胜，随后协作取消另一方（T1 的 `respond` 退出后才释放租约——E4，O-N5）。
    private func run(_ engine: any CardExtractionEngine, region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async -> Outcome {
        guard let timeout = engine.regionTimeout else {
            do { return .success(try await engine.extract(region: region, spec: spec, request: request)) } catch { return .failure }
        }
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .success(try await engine.extract(region: region, spec: spec, request: request)) }
                catch is CancellationError { return .timeout }
                catch { return .failure }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)   // try?-ok: 睡眠被取消即另一任务已完成，结果不被采用
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    /// 两轨并集（design §5.3「按 (row, key) 并集」）：共享先到先得；行按 rowAnchor 值合并（同药名 / 同项目补键不重复成行），
    /// 无锚或锚值未见者追加。
    private func union(_ a: RegionExtraction, _ b: RegionExtraction, anchor: String?) -> RegionExtraction {
        var out = a
        out.shared.merge(b.shared) { first, _ in first }
        for row in b.rows {
            if let anchor, let key = row[anchor]?.value,
               let index = out.rows.firstIndex(where: { $0[anchor]?.value == key }) {
                out.rows[index].merge(row) { first, _ in first }
            } else {
                out.rows.append(row)
            }
        }
        return out
    }
}

/// 契约桩（测试 / Linux）：脚本化区域结果；恒可用。
public struct StubCardExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack, regionTimeout: Duration?
    private let body: @Sendable (ExtractionRegion, ExtractionSpec) async throws -> RegionExtraction
    public init(track: ExtractionTrack, regionTimeout: Duration?,
                _ body: @escaping @Sendable (ExtractionRegion, ExtractionSpec) async throws -> RegionExtraction) {
        self.track = track; self.regionTimeout = regionTimeout; self.body = body
    }
    public func availability(for request: ExtractionRequest) async -> EngineAvailability { .available }
    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        try await body(region, spec)
    }
}
