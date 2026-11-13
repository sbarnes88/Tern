// Tern 0.3: errors, types and the built-in constants.

public struct Pos: Equatable, CustomStringConvertible {
    public var line: Int
    public var col: Int
    public init(_ line: Int, _ col: Int) { self.line = line; self.col = col }
    public var description: String { "\(line):\(col)" }
}

public struct TernError: Error, CustomStringConvertible {
    public var msg: String
    public let pos: Pos
    public let phase: String   // "syntax error", "type error" or "runtime error"
    public var file: String? = nil   // set when the error is inside a library file, like "shop.ternlib"
    public init(_ msg: String, _ pos: Pos, _ phase: String) { self.msg = msg; self.pos = pos; self.phase = phase }
    public var description: String { "\(phase)\(file.map { " in \($0)" } ?? "") at line \(pos.line), column \(pos.col): \(msg)" }
}

public indirect enum TType: Equatable, CustomStringConvertible {
    case int, float, text, bool, unit, color, align, font
    case list(TType)
    case structType(String)
    case optional(TType)
    case action

    public var description: String {
        switch self {
        case .int: return "Int"
        case .float: return "Float"
        case .text: return "Text"
        case .bool: return "Bool"
        case .unit: return "Unit"
        case .color: return "Color"
        case .align: return "Align"
        case .font: return "Font"
        case .list(let t): return "List<\(t)>"
        case .structType(let n): return n
        case .optional(let t): return "\(t)?"
        case .action: return "Action"
        }
    }
    public var isList: Bool { if case .list = self { return true }; return false }
    public var element: TType? { if case .list(let t) = self { return t }; return nil }
    public var unwrapped: TType { if case .optional(let t) = self { return t.unwrapped }; return self }
    public var isOptional: Bool { if case .optional = self { return true }; return false }
}

let BASE_TYPES: [String: TType] = [
    "Int": .int, "Float": .float, "Text": .text, "Bool": .bool, "Color": .color, "Align": .align, "Font": .font, "Action": .action,
]

/// Named colours, in the order the guide lists them.
public let COLORS: [(name: String, hex: String)] = [
    ("black", "#000000"), ("white", "#ffffff"), ("gray", "#6e7781"), ("red", "#d1242f"), ("green", "#1a7f37"),
    ("blue", "#0b57d0"), ("orange", "#bc4c00"), ("purple", "#8250df"), ("yellow", "#bf8700"), ("pink", "#bf3989"),
]
public let ALIGNS = ["left", "center", "right", "spread"]
public let FONTS = ["sans", "serif", "mono", "display", "hand", "rounded"]

let CONST_TYPES: [String: TType] = {
    var d: [String: TType] = [:]
    for c in COLORS { d[c.name] = .color }
    for a in ALIGNS { d[a] = .align }
    for f in FONTS { d[f] = .font }
    return d
}()
let CONST_VALUES: [String: Value] = {
    var d: [String: Value] = [:]
    for c in COLORS { d[c.name] = .text(c.hex) }
    for a in ALIGNS { d[a] = .text(a) }
    for f in FONTS { d[f] = .text(f) }
    return d
}()

public let TERN_VERSION = "0.3"
