import Foundation

/// 逐列裁决（round3 §6.1 步骤 4–8）：越语言弃权 → 校准打分 → 对称保护（数字/单位/否定/词条 → 极性）
/// → 否定辖域 → 门槛决策；
/// 再在主轨原字符串上就地应用。纯函数、确定性：只按数组顺序遍历，从不遍历字典或集合。
struct HypothesisFusionDecider {
    let primaryText: String
    let primaryTokens: [HypothesisFusionToken]
    /// 引擎顺序（0 = 主轨）。
    let engineIDs: [String]
    let producibleScripts: [Set<HypothesisFusionScript>]
    let columns: [HypothesisFusionColumn]
    let calibration: HypothesisFusionCalibrationIndex
    let options: HypothesisFusionOptions

    /// 主轨句读：子句边界（另加换行）。顿号、冒号不切——「没有发热、咳嗽」的否定辖域跨顿号。
    static let clauseBreaks: Set<Character> = Set("，。；！？,.;!?．｡")

    /// 一列中的一个候选（同一严格键的票合并；key = nil 即 ∅）。
    struct Candidate {
        var key: String?
        var supporters: [Int] = []
        var calibrated: [Int] = []
        var score: Double = 0
        var surfaces: [(engine: Int, surface: String, weight: Double)] = []
        /// 含数字/单位/否定词/调用方词条的票（→ `.protected`）。
        var isProtected = false
        /// 含临床极性/方位/时序/剂量动作词的票（→ `.polarity`）。
        var hasPolarity = false
        var hasNegation = false
    }

    struct Tally {
        var candidates: [Candidate] = []
        /// 主轨引擎在本列投了票但缺可用校准数据。
        var primaryUncalibrated = false
    }

    struct PendingEdit {
        var kind: HypothesisFusionEdit.Kind
        var range: Range<Int>
        var original: String
        var surface: String
        var supporters: [String]
        var margin: Double
    }

    func decide() -> (edits: [PendingEdit], disputes: [HypothesisFusionDispute]) {
        let slots = insertionSlots()
        let clauseOfToken = Self.clauseIndices(text: primaryText, tokens: primaryTokens)
        let tallies = columns.map { tally($0) }
        var frozen = Set<Int>()
        for (index, tally) in tallies.enumerated() where tally.candidates.contains(where: { $0.hasNegation }) {
            frozen.formUnion(clauses(of: index, slots: slots, clauseOfToken: clauseOfToken))
        }
        var edits: [PendingEdit] = []
        var disputes: [HypothesisFusionDispute] = []
        for (index, column) in columns.enumerated() {
            let tally = tallies[index]
            let primaryKey = column.isInsertion ? nil : column.anchor.key
            let alternatives = tally.candidates.filter { $0.key != primaryKey && isReportable($0, in: column) }
            guard !alternatives.isEmpty else { continue }
            let baseline = tally.candidates.first { $0.key == primaryKey }?.score ?? 0
            let range = column.primaryIndex.map { primaryTokens[$0].utf16Range } ?? insertionPoint(slots[index])
            let reason: HypothesisFusionDispute.Reason
            if tally.candidates.contains(where: { $0.isProtected }) {
                reason = .protected
            } else if tally.candidates.contains(where: { $0.hasPolarity }) {
                reason = .polarity
            } else if !frozen.isDisjoint(with: clauses(of: index, slots: slots, clauseOfToken: clauseOfToken)) {
                reason = .negationScope
            } else if tally.primaryUncalibrated || alternatives.allSatisfy({ $0.calibrated.isEmpty }) {
                reason = .insufficientCalibration
            } else if let best = alternatives.filter({ !$0.calibrated.isEmpty }).sorted(by: Self.outranks).first {
                let margin = best.score - baseline
                let isDeletion = best.key == nil && !column.isInsertion
                let threshold = options.effectiveTau + (isDeletion ? options.effectiveDeletionMargin : 0)
                let backers = Set(best.calibrated.map { engineIDs[$0] }).count
                let enoughEngines = !column.isInsertion || backers >= options.effectiveMinimumInsertionEngines
                if enoughEngines, margin > threshold {
                    guard options.mode == .gatedRewrite else {
                        disputes.append(dispute(column, tally: tally, primaryKey: primaryKey, range: range,
                                                reason: .reviewOnly))
                        continue
                    }
                    let kind: HypothesisFusionEdit.Kind = column.isInsertion ? .insertion
                        : (isDeletion ? .deletion : .substitution)
                    edits.append(PendingEdit(kind: kind, range: range,
                                             original: column.isInsertion ? "" : column.anchor.surface,
                                             surface: isDeletion ? "" : Self.representative(best),
                                             supporters: best.supporters.map { engineIDs[$0] }, margin: margin))
                    continue
                }
                reason = .belowGate
            } else {
                reason = .insufficientCalibration
            }
            disputes.append(dispute(column, tally: tally, primaryKey: primaryKey, range: range, reason: reason))
        }
        return (edits, disputes)
    }

    // MARK: 漂移观测

    /// 主轨 × 各副轨的分歧计数（与离线基线同一口径）：可比列 = 两者都未越语言弃权、且至少一方有词元
    /// （主轨列，或该副轨自己的插入列）；分歧 = 两者严格键不同（含 ∅）。与其他副轨是否在场无关。
    func pairObservations() -> [HypothesisFusionPairObservation] {
        guard engineIDs.count > 1 else { return [] }
        var compared = [Int](repeating: 0, count: engineIDs.count)
        var disagreed = [Int](repeating: 0, count: engineIDs.count)
        for column in columns {
            let primaryVote = column.votes[0]
            guard canVote(0, column: column, vote: primaryVote) else { continue }
            for engine in 1..<column.votes.count {
                let vote = column.votes[engine]
                guard canVote(engine, column: column, vote: vote),
                      !column.isInsertion || vote.token != nil else { continue }
                compared[engine] += 1
                if vote.token?.key != primaryVote.token?.key { disagreed[engine] += 1 }
            }
        }
        return (1..<engineIDs.count).map { engine in
            HypothesisFusionPairObservation(primaryEngineID: engineIDs[0], secondaryEngineID: engineIDs[engine],
                                            disagreements: disagreed[engine], columns: compared[engine])
        }
    }

    // MARK: 投票

    /// 越语言弃权（round3 §6.1 步骤 4）：引擎只在「列脚本」与「自己词元的脚本」都属其可产出脚本时投票。
    /// 主轨在自己的词元列上恒投票（列脚本即由它定义）。
    func canVote(_ engine: Int, column: HypothesisFusionColumn, vote: HypothesisFusionVote) -> Bool {
        if engine == 0, !column.isInsertion { return true }
        let scripts = producibleScripts[engine]
        guard scripts.contains(column.anchor.script) else { return false }
        if let token = vote.token { return scripts.contains(token.script) }
        return true
    }

    /// 校准加权（round3 §6.1 步骤 5）：得分 = Σ max(0, log(K·p/(1−p)))；缺校准数据的票不计分（弃权），
    /// 但其候选仍参与保护/否定判定与「待核」展示。
    func tally(_ column: HypothesisFusionColumn) -> Tally {
        var result = Tally()
        for (engine, vote) in column.votes.enumerated() where canVote(engine, column: column, vote: vote) {
            let weight = calibration.reliability(engineID: engineIDs[engine], script: column.anchor.script,
                                                 tokenClass: column.anchor.tokenClass,
                                                 confidence: vote.token?.confidence)?.weight
            if engine == 0, weight == nil { result.primaryUncalibrated = true }
            let key = vote.token?.key
            let slot: Int
            if let existing = result.candidates.firstIndex(where: { $0.key == key }) {
                slot = existing
            } else {
                result.candidates.append(Candidate(key: key))
                slot = result.candidates.count - 1
            }
            result.candidates[slot].supporters.append(engine)
            if let weight {
                result.candidates[slot].calibrated.append(engine)
                result.candidates[slot].score += weight
            }
            if let token = vote.token {
                result.candidates[slot].surfaces.append((engine, token.surface, weight ?? -1))
                switch token.tokenClass {
                case .number, .unit, .negation:
                    result.candidates[slot].isProtected = true
                case .polarity:
                    result.candidates[slot].hasPolarity = true
                case .word:
                    break
                }
                if token.isProtectedTerm { result.candidates[slot].isProtected = true }
                if token.tokenClass == .negation { result.candidates[slot].hasNegation = true }
            }
        }
        return result
    }

    /// 插入列只报「受保护/极性」或 ≥2 个不同引擎支持的候选——单引擎多出的普通词元（语气词、音译余字）
    /// 直接丢弃、不进待核。采纳门槛另见 `effectiveMinimumInsertionEngines`（可调严，严于 2 时落为 belowGate）。
    func isReportable(_ candidate: Candidate, in column: HypothesisFusionColumn) -> Bool {
        guard column.isInsertion else { return true }
        let distinct = Set(candidate.supporters.map { engineIDs[$0] }).count
        return candidate.isProtected || candidate.hasPolarity || distinct >= Self.reportableInsertionEngines
    }

    /// 插入候选进入待核所需的最少不同引擎数（round3 §6.1 步骤 6「插入须 ≥2 个引擎支持」）。
    static let reportableInsertionEngines = 2

    /// 全序：得分高者先；再按计分引擎数；再「有内容」先于 ∅；最后按键的 UTF-8 字节序。
    static func outranks(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.calibrated.count != rhs.calibrated.count { return lhs.calibrated.count > rhs.calibrated.count }
        switch (lhs.key, rhs.key) {
        case let (left?, right?):
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        case (.some, .none):
            return true
        case (.none, _):
            return false
        }
    }

    /// 候选的代表写法：权重最高的支持者原样词元（平局取引擎顺序在前者）。
    static func representative(_ candidate: Candidate) -> String {
        var best: (engine: Int, surface: String, weight: Double)?
        for entry in candidate.surfaces {
            if let current = best, entry.weight <= current.weight { continue }
            best = entry
        }
        return best?.surface ?? ""
    }

    func dispute(_ column: HypothesisFusionColumn, tally: Tally, primaryKey: String?, range: Range<Int>,
                 reason: HypothesisFusionDispute.Reason) -> HypothesisFusionDispute {
        var candidates: [HypothesisFusionDispute.Candidate] = []
        if let primary = tally.candidates.first(where: { $0.key == primaryKey }) {
            candidates.append(HypothesisFusionDispute.Candidate(
                surface: column.isInsertion ? nil : column.anchor.surface,
                engineIDs: primary.supporters.map { engineIDs[$0] }, score: primary.score, isPrimary: true))
        }
        for candidate in tally.candidates.filter({ $0.key != primaryKey }).sorted(by: Self.outranks) {
            candidates.append(HypothesisFusionDispute.Candidate(
                surface: candidate.key == nil ? nil : Self.representative(candidate),
                engineIDs: candidate.supporters.map { engineIDs[$0] }, score: candidate.score, isPrimary: false))
        }
        return HypothesisFusionDispute(utf16Range: range,
                                       primarySurface: column.isInsertion ? nil : column.anchor.surface,
                                       candidates: candidates, reason: reason)
    }
}

// MARK: - 位置：插入点与子句（否定辖域）

extension HypothesisFusionDecider {
    /// 每列所在的主轨槽位：主轨列 = 自身下标；插入列 = 其前最近的主轨词元下标（-1 = 句首之前）。
    func insertionSlots() -> [Int] {
        var slots: [Int] = []
        slots.reserveCapacity(columns.count)
        var last = -1
        for column in columns {
            if let index = column.primaryIndex { last = index }
            slots.append(last)
        }
        return slots
    }

    /// 插入点：紧跟前一主轨词元之后（句首之前 = 首词元起点；主轨无词元 = 0）。
    func insertionPoint(_ slot: Int) -> Range<Int> {
        let offset = slot >= 0 ? primaryTokens[slot].utf16Range.upperBound
            : (primaryTokens.first?.utf16Range.lowerBound ?? 0)
        return offset..<offset
    }

    /// 列所属子句；跨子句边界的插入列同属两侧子句（保守：两侧任一有否定即冻结）。
    func clauses(of index: Int, slots: [Int], clauseOfToken: [Int]) -> Set<Int> {
        if let primaryIndex = columns[index].primaryIndex { return [clauseOfToken[primaryIndex]] }
        let slot = slots[index]
        var result = Set<Int>()
        if slot >= 0 { result.insert(clauseOfToken[slot]) }
        if slot + 1 < clauseOfToken.count { result.insert(clauseOfToken[slot + 1]) }
        if result.isEmpty { result.insert(0) }
        return result
    }

    /// 主轨词元的子句编号：相邻词元间的分隔串含句读（，。；！？,.;!? 等）或换行即换子句。
    static func clauseIndices(text: String, tokens: [HypothesisFusionToken]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(tokens.count)
        var clause = 0
        var previousEnd: Int?
        for token in tokens {
            if let previousEnd, token.utf16Range.lowerBound > previousEnd,
               slice(text, from: previousEnd, to: token.utf16Range.lowerBound)
                .contains(where: { clauseBreaks.contains($0) || $0.isNewline }) {
                clause += 1
            }
            result.append(clause)
            previousEnd = token.utf16Range.upperBound
        }
        return result
    }
}

// MARK: - 就地替换（round3 §6.1 步骤 8）

extension HypothesisFusionDecider {
    /// 在主轨原字符串上按 UTF-16 区间就地应用修改：区间之外的每个字节原样拷贝。
    /// 插入的拉丁/数字词元与两侧拉丁/数字字符相邻时补一个空格，避免粘连成新词（「have chest pain」）。
    static func apply(_ pending: [PendingEdit], to text: String) -> (text: String, edits: [HypothesisFusionEdit]) {
        guard !pending.isEmpty else { return (text, []) }
        let length = text.utf16.count
        var output = ""
        var cursor = 0
        var applied: [HypothesisFusionEdit] = []
        for edit in pending {
            if edit.range.lowerBound > cursor { output += slice(text, from: cursor, to: edit.range.lowerBound) }
            var replacement = edit.surface
            if edit.kind == .insertion, let first = replacement.first, let last = replacement.last {
                if let previous = output.last, isWordCharacter(previous), isWordCharacter(first) {
                    replacement = " " + replacement
                }
                if edit.range.upperBound < length, isWordCharacter(character(in: text, at: edit.range.upperBound)),
                   isWordCharacter(last) {
                    replacement += " "
                }
            }
            output += replacement
            cursor = max(cursor, edit.range.upperBound)
            applied.append(HypothesisFusionEdit(kind: edit.kind, utf16Range: edit.range, original: edit.original,
                                                replacement: replacement, supportingEngineIDs: edit.supporters,
                                                margin: edit.margin))
        }
        if cursor < length { output += slice(text, from: cursor, to: length) }
        return (output, applied)
    }

    static func slice(_ text: String, from lower: Int, to upper: Int) -> String {
        let start = String.Index(utf16Offset: lower, in: text)
        let end = String.Index(utf16Offset: upper, in: text)
        return String(text[start..<end])
    }

    static func character(in text: String, at offset: Int) -> Character {
        text[String.Index(utf16Offset: offset, in: text)]
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        if character.isASCII { return character.isLetter || character.isNumber }
        let folded = HypothesisFusionLexicon.nfkc(character)
        return HypothesisFusionLexicon.isLatinWord(folded)
            || folded.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
    }
}
