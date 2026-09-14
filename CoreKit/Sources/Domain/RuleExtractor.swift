import Foundation

/// 子项目 E3（2026-09-14 实施计划 Task E3 / design §5.3）：T3 规则轨——**确定性、纯函数、零网络**。
///
/// 输入 = 一个版面区域（`ExtractionRegion`，E2）+ 卡 spec；输出 = 共享字段与逐行字段的 `GroundedValue`，
/// 每个值都是原文行的子串并带 `TextAnchor`（`ExtractionGrounding.validate` 第二道防线必过）。
///
/// 规则族（按优先级）：
/// 1. 共享字段：`标签[:：]值` / 标签独占 cell 而值在下一 cell / 日期类只取日期 token / 叙事续行（紧随的无标签单列行并入，≤6 行）；
///    未命中走 spec 的 `RuleFallback`（区域首个日期 / 含词行取 token / 以科室词结尾的短行）。
/// 2. 行级字段：① 列头映射（`columnHeader` 或首行全为列头标签）；② 行级「标签：值」剥标签后再分类（「用法：每次1片…」）；
///    ③ 合体行按卡类正则族拆分（`classify`）；④ 无行锚（药名）但有用法字段的行并入上一药品行（两行式处方）。
/// 同键第二值一律成新行——绝不丢弃（round2 O-N3）。
/// 剂量 / 数量 / 规格只取原文子串，不换算、不推断（BR-006/007）；异常标志 ↑↓/HL 原文保留不解释（BR-004/012）。
public enum RuleExtractor {
    public static func extract(region: ExtractionRegion, spec: ExtractionSpec, lines: [String])
        -> (shared: [String: GroundedValue], rows: [[String: GroundedValue]]) {
        (sharedFields(region: region, spec: spec, lines: lines),
         spec.row.isEmpty ? [] : rowFields(region: region, spec: spec, lines: lines))
    }

    static func anchor(_ line: Int, row: ExtractionRow, page: Int) -> TextAnchor {
        TextAnchor(pageIndex: page, lineIndex: line, blockId: "b\(line)", rowId: row.id, utf16Range: 0..<0)
    }

    /// 「标签[:：]值」→ 值；标签独占 cell → ""（值在下一 cell）；标签后紧跟其他字（「诊断证明书」）→ nil（不把标题当标签）。
    static func split(label cell: String, aliases: [String]) -> String? {
        let text = cell.trimmingCharacters(in: .whitespaces)
        for alias in aliases.sorted(by: { $0.count > $1.count }) where !alias.isEmpty && text.hasPrefix(alias) {
            var rest = Substring(text).dropFirst(alias.count).drop(while: \.isWhitespace)
            guard rest.isEmpty || rest.first == ":" || rest.first == "：" else { continue }
            if !rest.isEmpty { rest = rest.dropFirst() }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func dateToken(in text: String) -> String? {
        guard let regex = Patterns.date,
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: 共享字段

    static func sharedFields(region: ExtractionRegion, spec: ExtractionSpec, lines: [String]) -> [String: GroundedValue] {
        var out: [String: GroundedValue] = [:]
        let labelSet = spec.shared.flatMap(\.labelAliases)
        for field in spec.shared {
            search: for (r, row) in region.rows.enumerated() {
                for (c, cell) in row.cells.enumerated() {
                    guard var value = split(label: cell.text, aliases: field.labelAliases) else { continue }
                    var line = cell.lineIndices.first ?? -1
                    if value.isEmpty, c + 1 < row.cells.count {
                        value = row.cells[c + 1].text.trimmingCharacters(in: .whitespaces)
                        line = row.cells[c + 1].lineIndices.first ?? line
                    }
                    if case .date = field.type {
                        guard let token = dateToken(in: value) else { continue }
                        value = token
                    }
                    guard !value.isEmpty, lines.indices.contains(line) else { continue }
                    // 「无 / 否认 / 未见异常」类纯否认叙事不是字段（与资料建议 D4 同口径：不把否认写成事实）。
                    if case .narrative = field.type, ProfileSuggestionExtractor.isNegation(value) { continue }
                    var gv = GroundedValue(value: value, anchor: anchor(line, row: row, page: region.pageIndex), confidence: 0.9)
                    if case .narrative = field.type {
                        // 叙事续行：紧随的无标签单列行并入（≤ 6 行）——现病史多行整段保真（BR-002）。
                        for next in region.rows.dropFirst(r + 1).prefix(6) {
                            guard next.cells.count == 1, split(label: next.text, aliases: labelSet) == nil,
                                  let li = next.lineIndices.first else { break }
                            gv.value += "\n" + next.text
                            gv.continuation.append(anchor(li, row: next, page: region.pageIndex))
                        }
                    }
                    out[field.key] = gv
                    break search
                }
            }
            if out[field.key] == nil, let fallback = field.fallback,
               let gv = apply(fallback, region: region, lines: lines) {
                out[field.key] = gv
            }
        }
        return out
    }

    /// 兜底启发式（原 pageFields 医院/日期/科室直配，改为取**要素 token** 而非整行——round2 O-N6 命名要素归一）。
    static func apply(_ fallback: RuleFallback, region: ExtractionRegion, lines: [String]) -> GroundedValue? {
        for row in region.rows {
            for cell in row.cells {
                guard let li = cell.lineIndices.first, lines.indices.contains(li) else { continue }
                let text = cell.text.trimmingCharacters(in: .whitespaces)
                let value: String?
                switch fallback {
                case .firstDateInRegion:
                    value = dateToken(in: text)
                case .lineContaining(let words):
                    // 只取要素 token：排除裸标签（「医院：」/「医院」）——含关键词但去掉关键词与冒号后仍有实词才算机构名。
                    value = text.split(whereSeparator: \.isWhitespace).map(String.init).first { token in
                        guard token.count <= 40, !token.hasSuffix(":"), !token.hasSuffix("："),
                              let word = words.first(where: token.contains) else { return false }
                        return token.replacingOccurrences(of: word, with: "").trimmingCharacters(in: .whitespaces).count >= 2
                    }
                case .lineEndingWithAny(let words):
                    value = (text.count <= 20 && words.contains(where: text.hasSuffix)) ? text : nil
                }
                if let value, !value.isEmpty {
                    return GroundedValue(value: value, anchor: anchor(li, row: row, page: region.pageIndex), confidence: 0.6)
                }
            }
        }
        return nil
    }

    // MARK: 行级字段

    /// ① 列头映射；② 无列头 → 逐 cell 分类（`classify`）；③ 合体行 → 正则拆分；④ 无行锚但有用法字段 → 并入上一药品行。
    static func rowFields(region: ExtractionRegion, spec: ExtractionSpec, lines: [String]) -> [[String: GroundedValue]] {
        guard let anchorKey = spec.rowAnchor else { return [] }
        var rows = region.rows
        var columns: [Int: String] = [:]
        if let header = region.columnHeader {
            if let mapped = columnMap(header, spec: spec) { columns = mapped }
        } else if let first = rows.first {
            let tokens = first.cells.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
            if let mapped = columnMap(tokens, spec: spec), isPureHeader(tokens, spec: spec) {
                columns = mapped
                rows.removeFirst()
            }
        }
        var out: [[String: GroundedValue]] = []
        for row in rows {
            var fields: [String: GroundedValue] = [:]
            func put(_ key: String, _ value: String, _ cell: ExtractionCell, confidence: Double) {
                let v = value.trimmingCharacters(in: .whitespaces)
                guard fields[key] == nil, !v.isEmpty,
                      let li = cell.lineIndices.first(where: { lines.indices.contains($0) && lines[$0].contains(v) }) ?? cell.lineIndices.first,
                      lines.indices.contains(li) else { return }
                fields[key] = GroundedValue(value: v, anchor: anchor(li, row: row, page: region.pageIndex), confidence: confidence)
            }
            for cell in row.cells {
                // ① 真列表格（iOS 26 表格或几何多列）：单 token cell 直接按列头落键。
                if !columns.isEmpty, let key = columns[cell.columnIndex],
                   cell.text.split(whereSeparator: \.isWhitespace).count == 1 {
                    put(key, cell.text, cell, confidence: 0.9)
                    continue
                }
                // ② 行级「标签：值」：药品标签页 通用名称/规格；「用法：每次1片 每日1次」剥标签后再分类。
                if let field = spec.row.first(where: { split(label: cell.text, aliases: $0.labelAliases).map { !$0.isEmpty } ?? false }),
                   let rest = split(label: cell.text, aliases: field.labelAliases) {
                    let sub = classify(rest, kind: spec.kind)
                    if sub.isEmpty { put(field.key, rest, cell, confidence: 0.9) }
                    else { for (key, value) in sub { put(key, value, cell, confidence: 0.7) } }
                    continue
                }
                // ③ 合体行 / 无列头单元格：按卡类正则族拆分。
                for (key, value) in classify(cell.text, kind: spec.kind) { put(key, value, cell, confidence: 0.7) }
            }
            if fields[anchorKey] != nil {
                out.append(fields)
            } else if !fields.isEmpty, var last = out.popLast() {
                // ④ 两行式处方：用法行无药名 → 并入上一药品行（只补空，不覆盖）。
                for (k, v) in fields where last[k] == nil { last[k] = v }
                out.append(last)
            }
        }
        // 「检验报告单」类只有 raw_label 的标题行不成行（rowMinFields）。
        return out.filter { $0.count >= spec.rowMinFields }
    }

    /// 列头 token → 行字段键；至少映射 2 列且含行锚才算列头。
    static func columnMap(_ header: [String], spec: ExtractionSpec) -> [Int: String]? {
        var map: [Int: String] = [:]
        for (i, cell) in header.enumerated() {
            if let f = spec.row.first(where: { $0.labelAliases.contains(where: { alias in !alias.isEmpty && cell.contains(alias) }) }) {
                map[i] = f.key
            }
        }
        guard map.count >= 2, let anchorKey = spec.rowAnchor, map.values.contains(anchorKey) else { return nil }
        return map
    }

    /// 首行全部 token 都是列头标签（无数值、无单位）才视为列头行——否则是第一条数据行。
    static func isPureHeader(_ tokens: [String], spec: ExtractionSpec) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { token in
            token.rangeOfCharacter(from: .decimalDigits) == nil
                && spec.row.contains { $0.labelAliases.contains(where: { alias in !alias.isEmpty && token.contains(alias) }) }
        }
    }

    // MARK: 合体行分类

    /// cell → (键, 原文子串) 列表；按卡类选用规则族。全部值都是 `text` 的子串（grounding 友好）。
    public static func classify(_ text: String, kind: String) -> [(key: String, value: String)] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        var out: [(key: String, value: String)] = []
        let whole = NSRange(t.startIndex..., in: t)
        @discardableResult
        func cap(_ key: String, _ regex: NSRegularExpression?, group: Int = 0) -> Bool {
            guard let m = regex?.firstMatch(in: t, range: whole), m.numberOfRanges > group,
                  let r = Range(m.range(at: group), in: t) else { return false }
            let value = String(t[r]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            out.append((key, value))
            return true
        }
        switch kind {
        case "prescription":
            if let m = Patterns.drugWithSpec?.firstMatch(in: t, range: whole), let n = Range(m.range(at: 1), in: t) {
                out.append(("drug_name", String(t[n]).trimmingCharacters(in: .whitespaces)))
            }
            cap("spec", Patterns.spec)
            cap("dosage", Patterns.dosage, group: 1)
            cap("frequency", Patterns.frequency)
            cap("route", Patterns.route)
            cap("days", Patterns.days, group: 1)
            cap("quantity", Patterns.quantity, group: 1)
            if out.isEmpty, let m = Patterns.drugName?.firstMatch(in: t, range: whole), let n = Range(m.range(at: 1), in: t) {
                out.append(("drug_name", String(t[n]).trimmingCharacters(in: .whitespaces)))
            }
        case "metric_sample":
            // 合体行「项目 值 单位 范围」复用既有 lab_item 文法（DocumentTypeClassifierFallback）。
            // 行尾 ↑↓/H/L 先剥离再套 lab_item 文法（该文法以 `$` 锚定，尾标志会使整行不命中）；标志随后按原文回填。
            let flag = trailingFlag(t)
            let body = flag.map { String(t.dropLast($0.count)).trimmingCharacters(in: .whitespaces) } ?? t
            let drafts = DocumentTypeClassifierFallback.guessFields(line: body)
            if let lab = drafts.first(where: { $0.key == "lab_item" }) {
                let (name, number) = UnderstandingCodeResolution.splitReading(lab.value)
                out.append(("raw_label", name))
                if let number { out.append(("value", number)) }
                if let u = lab.unit { out.append(("unit", u)) }
                if let ref = drafts.first(where: { $0.key == "reference_range" }) { out.append(("reference_range", ref.value)) }
                if let flag { out.append(("abnormal_flag", flag)) }
            } else if let m = Patterns.labQualitative?.firstMatch(in: t, range: whole),
                      let n = Range(m.range(at: 1), in: t), let v = Range(m.range(at: 2), in: t) {
                // 「项目 阴性」「项目 <0.5 g/L」定性/比较符结果：原文保留，不猜数（BR-003）。
                out.append(("raw_label", String(t[n]).trimmingCharacters(in: .whitespaces)))
                out.append(("value", String(t[v]).trimmingCharacters(in: .whitespaces)))
                if m.numberOfRanges > 3, let u = Range(m.range(at: 3), in: t) {
                    let unit = String(t[u]).trimmingCharacters(in: .whitespaces)
                    if !unit.isEmpty { out.append(("unit", unit)) }
                }
                if let flag = trailingFlag(t) { out.append(("abnormal_flag", flag)) }
            } else if cap("value", Patterns.labValue) || cap("reference_range", Patterns.referenceRange)
                        || cap("unit", Patterns.unit) || cap("abnormal_flag", Patterns.flag) {
                // 真列表格的单元格：单值直接落键。
            } else if Patterns.labelText?.firstMatch(in: t, range: whole) != nil {
                out.append(("raw_label", t))
            }
        case "claim_item":
            if let m = Patterns.itemWithAmount?.firstMatch(in: t, range: whole),
               let n = Range(m.range(at: 1), in: t), let a = Range(m.range(at: 2), in: t) {
                out.append(("item_name", String(t[n]).trimmingCharacters(in: .whitespaces)))
                out.append(("item_amount", String(t[a])))
            } else if !cap("item_amount", Patterns.amount, group: 1),
                      Patterns.labelText?.firstMatch(in: t, range: whole) != nil {
                out.append(("item_name", t))
            }
        default:
            break
        }
        return out
    }

    /// 行尾异常标志（↑↓/H/L）：只取原文，不解释（BR-004/012）。
    static func trailingFlag(_ text: String) -> String? {
        guard let last = text.split(whereSeparator: \.isWhitespace).last else { return nil }
        let token = String(last)
        guard let regex = Patterns.flag, regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil else { return nil }
        return token
    }

    /// 编译期静态文法（一次编译）。返回 Optional：构造失败 = 该规则永不命中，不崩溃、不猜。
    enum Patterns {
        static func rx(_ p: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p, options: [.caseInsensitive])   // try?-ok: 静态字面量文法，构造失败即规则不命中而非崩溃
        }
        static let date = rx(#"(?<!\d)\d{4}\s*[-/年.]\s*\d{1,2}\s*[-/月.]\s*\d{1,2}(?:\s*日)?"#)
        static let spec = rx(#"\d+(?:\.\d+)?\s*(?:mg|g|ml|mL|μg|ug|IU|%)(?:\s*[/:*×xX]\s*\d+(?:\.\d+)?\s*(?:片|粒|支|袋|瓶|ml|mL|g|mg)?)*"#)
        static let dosage = rx(#"(?:每次|每晚|每早|晨起|一次)\s*(\d+(?:\.\d+)?\s*(?:mg|g|ml|mL|μg|ug|IU|片|粒|支|袋|滴|喷|噴|贴|貼|丸|包|单位|單位))"#)
        static let frequency = rx(#"(?:每日|每天|一日|隔日|每周|每週|每\d+小时|每\d+小時)\s*[\d一二三四两兩]*\s*次|每晚|睡前|晨起|饭前|飯前|饭后|飯後|必要时|必要時|\b(?:qd|bid|tid|qid|qn|prn|q\d+h)\b"#)
        static let route = rx(#"口服|外用|静脉滴注|靜脈滴注|静滴|靜滴|静脉注射|靜脈注射|肌肉注射|肌注|皮下注射|舌下含服|含服|吸入|滴眼|滴鼻|外涂|外塗|直肠给药|\b(?:po|iv|im|sc|ih)\b"#)
        static let days = rx(#"(\d+)\s*(?:天|日|d\b)"#)
        static let quantity = rx(#"(?<![\d.])(\d+\s*(?:盒|瓶|袋|包|板|管|条|條|支(?!装)))(?!\d)"#)   // 只认包装量词；片/粒属剂量
        static let drugWithSpec = rx(#"^(?:\d+[.、]\s*)?([一-龥A-Za-z][一-龥A-Za-z0-9（）()·\-]{1,39})\s+\d+(?:\.\d+)?\s*(?:mg|g|ml|mL|μg|ug|IU|%)"#)
        static let drugName = rx(#"^(?!.*(?:用法|用量|规格|規格|数量|數量|名称|名稱|医院|醫院|医生|醫生|日期|诊断|診斷|处方|處方))(?:\d+[.、]\s*)?([一-龥A-Za-z][一-龥A-Za-z0-9（）()·\-]{1,39})$"#)
        static let labValue = rx(#"^[<>≤≥]?\s*\d+(?:\.\d+)?$|^(?:阴性|陰性|阳性|陽性|弱阳性|弱陽性|正常|未检出|未檢出|negative|positive|[+\-]{1,3})$"#)
        static let labQualitative = rx(#"^([一-龥A-Za-z][一-龥A-Za-z0-9\-/·()（）]{0,39})(?:[:：]\s*|\s+)([<>≤≥]\s*\d+(?:\.\d+)?|阴性|陰性|阳性|陽性|弱阳性|弱陽性|正常|未检出|未檢出|negative|positive|[+\-]{1,3})(?:\s+((?:10\^\d+/)?[a-zA-Zμµ%][a-zA-Zμµ/%·^0-9]*))?(?:\s+[↑↓HL])?$"#)
        static let referenceRange = rx(#"^\d+(?:\.\d+)?\s*[-–~～]\s*\d+(?:\.\d+)?$|^[<>≤≥]\s*\d+(?:\.\d+)?$"#)
        static let unit = rx(#"^(?:10\^\d+/)?[a-zA-Zμµ%][a-zA-Zμµ/%·^0-9]*$"#)
        static let flag = rx(#"^(?:[↑↓HL]|偏高|偏低)$"#)
        static let labelText = rx(#"^[一-龥A-Za-z][一-龥A-Za-z0-9\-/·()（）%]{1,39}$"#)
        static let amount = rx(#"^[¥￥]?\s*(\d+(?:\.\d{1,2})?)$"#)
        static let itemWithAmount = rx(#"^(.+?)\s+[¥￥]?(\d+(?:\.\d{1,2})?)$"#)   // 合体费用行「西药费 98.50」
    }
}

/// 续表建议（round2 O-N4）：多页表格的续页只得到**建议**（`continuationHint`），不写 shared、不自动借用；
/// E5 以低置信草稿呈现，须逐项确认（BR-003）。
public enum ContinuationRules {
    static let carried = ["hospital", "department", "doctor"]

    public static func apply(_ cards: [ExtractedCard], specs: (String) -> ExtractionSpec?) -> [ExtractedCard] {
        var out = cards.sorted { ($0.pageIndex, $0.kind) < ($1.pageIndex, $1.kind) }
        for i in out.indices where !out[i].rows.isEmpty {
            guard let spec = specs(out[i].kind) else { continue }
            let missing = spec.shared
                .filter { $0.isRequired || carried.contains($0.key) }
                .map(\.key)
                .filter { out[i].shared[$0] == nil }
            guard !missing.isEmpty,
                  let previous = out[..<i].last(where: { $0.kind == out[i].kind && $0.pageIndex < out[i].pageIndex && !$0.shared.isEmpty })
            else { continue }
            for key in missing {
                if let v = previous.shared[key] { out[i].continuationHint[key] = v }
            }
        }
        return out
    }
}
