// 순서를 지키는 JSON 한 줄 쓰기(기록·측정용). JSONEncoder는 키 순서를 섞고,
// JSONSerialization은 실수를 1.0920000000000001처럼 찍어서 직접 쓴다. 실수는 Swift의 최단 표기.
import Foundation

indirect enum OrderedJSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into o: inout String) {
        switch self {
        case .string(let s): Self.quote(s, into: &o)
        case .int(let i): o += String(i)
        case .double(let d): o += d.isFinite ? String(d) : "null"
        case .bool(let b): o += b ? "true" : "false"
        case .null: o += "null"
        case .array(let items):
            o += "["
            for (i, v) in items.enumerated() {
                if i > 0 { o += "," }
                v.write(into: &o)
            }
            o += "]"
        case .object(let fields):
            o += "{"
            for (i, (k, v)) in fields.enumerated() {
                if i > 0 { o += "," }
                Self.quote(k, into: &o)
                o += ":"
                v.write(into: &o)
            }
            o += "}"
        }
    }

    private static func quote(_ s: String, into o: inout String) {
        o += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if u.value < 0x20 {
                    o += String(format: "\\u%04x", u.value)
                } else {
                    o.unicodeScalars.append(u)
                }
            }
        }
        o += "\""
    }
}
