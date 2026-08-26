import Foundation

/// FR13.3 导出管线 CSV 编码（§5.7 V3.20）：RFC 4180 + UTF-8 BOM（Excel 兼容）+ 分包 manifest。
public enum CSVWriter {
    /// 转义规则：含逗号/引号/换行的字段加引号包裹，内部引号翻倍
    public static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// 表头 + 行；行内换行统一 \r\n（RFC 4180）
    public static func document(headers: [String], rows: [[String]]) -> String {
        var lines = [row(headers)]
        lines.append(contentsOf: rows.map(row))
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 BOM 前缀（Excel 中文兼容）
    public static var bom: Data { Data([0xEF, 0xBB, 0xBF]) }

    public static func encode(headers: [String], rows: [[String]]) -> Data {
        var data = bom
        data.append(Data(document(headers: headers, rows: rows).utf8))
        return data
    }

    /// 分包：超 maxRows 时按 manifest 拆多文件（FR13.3 分包 manifest）
    public struct SplitPart: Sendable, Equatable {
        public var name: String
        public var rows: [[String]]
        public init(name: String, rows: [[String]]) { self.name = name; self.rows = rows }
    }

    public static func split(baseName: String, headers: [String], rows: [[String]],
                             maxRows: Int) -> [SplitPart] {
        guard rows.count > maxRows else {
            return [SplitPart(name: "\(baseName).csv", rows: rows)]
        }
        var parts: [SplitPart] = []
        var index = 1
        var start = 0
        while start < rows.count {
            let end = min(start + maxRows, rows.count)
            parts.append(SplitPart(name: "\(baseName)-part\(index).csv",
                                   rows: Array(rows[start..<end])))
            index += 1
            start = end
        }
        return parts
    }
}
