import Foundation
import Domain
import Protocols

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §5）：按卡 spec 抽取的三轨同一端口 + 逐区域失败切换注册表。
/// T1 Foundation Models（E4）/ T2 llama.cpp 本机 LLM（子项目 F）/ T3 规则（E3）都实现 `CardExtractionEngine`；
/// grounding **不在引擎内**——注册表对每个区域结果统一执行 `ExtractionGrounding.validate`（第二道防线，design §4.6）。
/// 全部产物恒 D 级（BR-003）；零网络；不读 `EntitlementStore`（识别后理解属信任/安全面永久免费）。
/// 结构轮（2026-09-15）：自 Protocols 迁入——编排策略是**实现**而非抽象（P3），
/// Protocols 只保留引擎端口与契约桩；请求/结果值对象已迁入 Domain/ExtractedCard.swift。

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

    public func extract(_ request: ExtractionRequest) async throws -> [ExtractedCard] {
        var cards: [ExtractedCard] = []
        let pageStarted = ContinuousClock.now   // 页预算按整页计（多 spec 共用），durationMs 按卡计
        for spec in request.specs {
            // 审查修复（取消传播）：循环每轮检查取消——此前引擎的 CancellationError
            // 被折叠成 .timeout/.failure 后继续跑剩余区域，用户撤销的导入仍产出
            // 降级卡。取消必须中止整页抽取。
            try Task.checkCancellation()
            let started = ContinuousClock.now
            var card = ExtractedCard(kind: spec.kind, pageIndex: request.pageIndex, shared: [:], rows: [],
                                     provenance: ExtractionProvenance(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                     diagnostics: ExtractionDiagnostics(track: .rules))
            var disabled = Set<ExtractionTrack>()
            var used: [ExtractionTrack] = []

            for region in request.regions {
                try Task.checkCancellation()
                let (merged, contributors) = try await extractRegion(region, spec: spec, request: request,
                                                                     card: &card, disabled: &disabled, used: &used,
                                                                     pageStarted: pageStarted)
                card.shared.merge(merged.shared) { first, _ in first }   // 共享同键：先到先得（表头字段重复印刷）
                card.rows += merged.rows                                  // 行级：全部保留（O-N3 不再丢第二值）
                if !contributors.isEmpty { card.diagnostics.regionTracks[region.id] = contributors }
            }
            applyPrescriptionRowSplit(to: &card)
            card.provenance.track = used.first ?? .rules
            card.diagnostics.track = card.provenance.track
            card.diagnostics.mixedTracks = used.count > 1
            card.provenance.durationMs = Int((ContinuousClock.now - started) / .milliseconds(1))
            cards.append(card)
        }
        return cards
    }

    /// 单区域跨轨抽取：按注册顺序逐轨尝试，含缩范围重试与降级登记。
    /// 返回该区域并集结果与贡献轨列表；`card`/`disabled`/`used` 沿链累计。
    private func extractRegion(_ region: ExtractionRegion, spec: ExtractionSpec,
                               request: ExtractionRequest, card: inout ExtractedCard,
                               disabled: inout Set<ExtractionTrack>, used: inout [ExtractionTrack],
                               pageStarted: ContinuousClock.Instant) async throws
        -> (merged: RegionExtraction, contributors: [ExtractionTrack]) {
        var merged = RegionExtraction(shared: [:], rows: [])
        var contributors: [ExtractionTrack] = []
        var regionDone = false
        for engine in engines where !disabled.contains(engine.track) && !regionDone {
            let generative = engine.track != .rules
            if generative, !request.allowsGenerativeProcessing { degrade(.notAuthorized, in: &card); continue }
            if generative, let budget = request.pageBudget, ContinuousClock.now - pageStarted > budget { degrade(.timeout, in: &card); continue }
            let availability = await engine.availability(for: request)
            guard case .available = availability else {
                if case .unavailable(let reason) = availability { degrade(reason, in: &card) }
                continue
            }
            var attempt = spec
            var retried = false
            while true {
                switch try await run(engine, region: region, spec: attempt, request: request) {
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
        return (merged, contributors)
    }

    /// 首个降级原因登记（design §5.3：已定原因不被后续覆盖）。
    private func degrade(_ reason: DegradedReason, in card: inout ExtractedCard) {
        if card.diagnostics.degradedReason == .none { card.diagnostics.degradedReason = reason }
    }

    /// 处方合体行后拆分（审查修复 2026-09-18 业主实测）：生成轨可能把
    /// 「阿莫西林胶囊 0.5g×24粒 口服 一次2粒 一日三次」整行当 drug_name
    /// 产出（逐字子串，grounding 合法）——行内药名/规格/途径/单次量/
    /// 频次全被埋没。规则轨文法对同文本可拆全键，故对处方卡逐行后
    /// 拆分：仅当 drug_name 混排用法短语时拆；union 语义（已有键不
    /// 覆盖——生成轨逐字值优先，新键补缺；全部产物仍 D 级待确认，
    /// BR-003 不变）。
    private func applyPrescriptionRowSplit(to card: inout ExtractedCard) {
        guard card.kind == "prescription" else { return }
        for rowIndex in card.rows.indices {
            guard let nameGV = card.rows[rowIndex]["drug_name"],
                  RuleExtractor.prescriptionNameNeedsSplit(nameGV.value) else { continue }
            let split = RuleExtractor.splitPrescriptionLine(nameGV.value)
            guard split.count > 1 else { continue }
            var updated = card.rows[rowIndex]
            for (key, value) in split {
                if key == "drug_name" {
                    // 拆出的药名比整行短：以拆出值为准（锚点/置信沿用原值）
                    updated["drug_name"] = GroundedValue(value: value, anchor: nameGV.anchor,
                                                         confidence: nameGV.confidence)
                } else if updated[key] == nil {
                    updated[key] = GroundedValue(value: value, anchor: nameGV.anchor,
                                                 confidence: nameGV.confidence)
                }
            }
            card.rows[rowIndex] = updated
        }
    }

    /// 单区域单轨一次调用：无超时直跑；有超时则与睡眠竞速，先到者胜，随后协作取消另一方（T1 的 `respond` 退出后才释放租约——E4，O-N5）。
    /// 审查修复（取消传播）：引擎子任务的 CancellationError 此前折叠成 .timeout
    /// ——超时竞速的 cancelAll() 会取消引擎子任务，但那是「超时已胜出、结果
    /// 已被采用」的场景（错误无人观察）；真正需要传播的是**调用方取消**——
    /// 此时引擎子任务先完成并抛 CancellationError，必须沿链抛出中止抽取，
    /// 不得当作区域降级继续跑。
    private func run(_ engine: any CardExtractionEngine, region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> Outcome {
        guard let timeout = engine.regionTimeout else {
            do { return .success(try await engine.extract(region: region, spec: spec, request: request)) }
            catch is CancellationError { throw CancellationError() }
            catch { return .failure }
        }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .success(try await engine.extract(region: region, spec: spec, request: request)) }
                catch is CancellationError { throw CancellationError() }
                catch { return .failure }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)   // try?-ok: 睡眠被取消即另一任务已完成，结果不被采用
                return .timeout
            }
            let first = try await group.next() ?? .timeout
            group.cancelAll()
            // 调用方取消：即便引擎子任务的 CancellationError 未被 next() 观察
            // （超时子任务先胜出的竞速路径），此处也强制中止而非继续下区域。
            try Task.checkCancellation()
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
