import Foundation

// Runtime: runs a checked page and produces a render tree.
// Runtime errors (division by zero, index out of range, deep recursion, numbers too big,
// too much work) are thrown as TernError and never crash the host.

public enum Value: Equatable, CustomStringConvertible {
    case int(Int), float(Double), text(String), bool(Bool), list([Value]), record([String: Value]), none

    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let f): return floatToText(f)
        case .text(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .list(let xs): return "[" + xs.map { $0.description }.joined(separator: ", ") + "]"
        case .record(let r): return "{" + r.keys.sorted().map { "\($0): \(r[$0]!)" }.joined(separator: ", ") + "}"
        case .none: return "null"
        }
    }
    var asInt: Int { if case .int(let i) = self { return i }; return 0 }
    var asFloat: Double { if case .float(let f) = self { return f }; return 0 }
    var asText: String { if case .text(let s) = self { return s }; return "" }
    var asBool: Bool { if case .bool(let b) = self { return b }; return false }
    var asList: [Value] { if case .list(let xs) = self { return xs }; return [] }
}

/// Resolved style properties for one element: size, bold, color, ...
/// Colours, alignments and fonts are plain strings ("#0b57d0", "center", "serif").
public struct Style: Equatable {
    public var props: [String: Value] = [:]
    public init(_ props: [String: Value] = [:]) { self.props = props }
    public subscript(_ k: String) -> Value? {
        get { props[k] }
        set { props[k] = newValue }
    }
    public func int(_ k: String) -> Int? { if case .int(let i)? = props[k] { return i }; return nil }
    public func text(_ k: String) -> String? { if case .text(let s)? = props[k] { return s }; return nil }
    public func flag(_ k: String) -> Bool? { if case .bool(let b)? = props[k] { return b }; return nil }
    public var isEmpty: Bool { props.isEmpty }
}

/// One element of a rendered page. The browser draws these.
/// A table cell as drawn: `kind` is "text", "button" or "link"; a cell may span several columns.
public struct TCell {
    public var text = ""
    public var span = 1
    public var kind = "text"
    public var checked = false
    public var options: [String] = []
    public var placeholder = ""
    public var set: ((String) throws -> Void)? = nil
    public var style = Style()
    public var target: String? = nil
    public var click: (() throws -> Void)? = nil
}
public struct TRow { public var cells: [TCell] = [] }

public struct RNode {
    public enum Kind: String { case heading, text, bullet, para, button, input, checkbox, modal, grid, select, radio, textarea, slider, row, column, table, header, cells, link, image, divider }
    public var kind: Kind
    public var text = ""                         // heading/text/bullet/link text, button label, image src
    public var style = Style()
    public var spans: [(text: String, style: Style)] = []
    public var children: [RNode] = []
    public var header: [String]? = nil
    public var rows: [[String]] = []
    public var cells: [String] = []
    public var name = ""                         // input: the state it edits
    public var value = ""                        // input: current text
    public var checked = false                   // checkbox: ticked or not
    public var options: [String] = []            // select, radio: the choices
    public var number = 0                        // slider: the value
    public var lower = 0                         // slider: the smallest value
    public var upper = 0                         // slider: the largest value
    public var columns = 1                       // grid: how many columns
    public var placeholder = ""
    public var target: String? = nil             // link: where it goes
    public var alt = ""
    public var row: TRow? = nil                  // header/cells line: its cells with spans, buttons and links
    public var resizable = false                 // table: the reader may drag column edges
    public var hrow: TRow? = nil                 // table: the header line
    public var body: [TRow] = []                 // table: the other lines
    public var click: (() throws -> Void)? = nil
    public var set: ((String) throws -> Void)? = nil
    public init(_ kind: Kind) { self.kind = kind }

    public var label: String { text }
    public var src: String { text }
}

private struct ReturnSignal: Error { let value: Value }

private let MAX_CALL_DEPTH = 2000
private let MAX_STEPS = 20_000_000
private let MAX_LIST = 1_000_000
private let MAX_TEXT = 10_000_000

private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

typealias Scopes = [[String: Value]]

public final class Page {
    let prog: Program
    public let title: String
    var fns: [String: FnDecl] = [:]
    var methods: [String: FnDecl] = [:]
    var styles: [String: StyleDecl] = [:]
    var views: [String: ViewDecl] = [:]
    public private(set) var screen: String
    public private(set) var history: [String] = []
    public var state: [String: Value] = [:]
    private var steps = 0
    private var depth = 0

    /// Parses, checks and starts a page. Throws TernError for syntax, type or runtime errors.
    public init(_ src: String, assets: AssetInfo? = nil, libraries: [String: String] = [:],
                libraryHint: String = "put it next to the page", saved: String? = nil,
                components: [String: String] = [:]) throws {
        prog = try buildProgram(src, libraries: libraries, hint: libraryHint, componentSources: components)
        try Checker(prog, assets: assets).run()
        title = prog.title ?? "Untitled"
        for v in prog.views { views[v.name] = v }
        for c in prog.components { componentDecls[c.name] = c }
        screen = prog.views.first?.name ?? "home"
        for f in prog.fns { fns[f.name] = f }
        for st in prog.structs { for m in st.methods { methods["\(st.name).\(m.name)"] = m } }
        for s in prog.styles { styles[s.name] = s }
        steps = 0
        for st in prog.structs { structDecls[st.name] = st }
        savedNames = prog.states.filter { $0.saved }.map { $0.name }
        // `saved state` values the host kept from an earlier visit (JSON text); a value that no longer fits the
        // declared type is ignored, so changing a state's type never breaks the page
        let kept = (saved.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        for s in prog.states {
            if s.saved, let raw = kept[s.name], let v = decodeSaved(raw, s.type) { state[s.name] = v; continue }
            var sc: Scopes = [[:]]
            state[s.name] = try eval(s.initial, &sc)
        }
    }

    private var componentDecls: [String: ComponentDecl] = [:]

    public private(set) var savedNames: [String] = []
    private var structDecls: [String: StructDecl] = [:]

    private func decodeSaved(_ raw: Any, _ ty: TType) -> Value? {
        func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
        switch ty {
        case .int:
            guard let n = raw as? NSNumber, !isBool(n), n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 9007199254740992 else { return nil }
            return .int(n.intValue)
        case .float:
            guard let n = raw as? NSNumber, !isBool(n), n.doubleValue.isFinite else { return nil }
            return .float(n.doubleValue)
        case .text:
            guard let s = raw as? String, s.utf16.count <= MAX_TEXT else { return nil }
            return .text(s)
        case .bool:
            guard let n = raw as? NSNumber, isBool(n) else { return nil }
            return .bool(n.boolValue)
        case .color:
            guard let s = raw as? String, s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return nil }
            return .text(s)
        case .align:
            guard let s = raw as? String, ALIGNS.contains(s) else { return nil }
            return .text(s)
        case .font:
            guard let s = raw as? String, FONTS.contains(s) else { return nil }
            return .text(s)
        case .list(let el):
            guard let xs = raw as? [Any], xs.count <= MAX_LIST else { return nil }
            var out: [Value] = []
            for x in xs { guard let v = decodeSaved(x, el) else { return nil }; out.append(v) }
            return .list(out)
        case .structType(let name):
            guard let st = structDecls[name], let obj = raw as? [String: Any] else { return nil }
            let allowed = Set(st.fields.map { $0.name })
            if obj.keys.contains(where: { !allowed.contains($0) }) { return nil }
            var r: [String: Value] = [:]
            for f in st.fields {
                if let x = obj[f.name] {
                    guard let v = decodeSaved(x, f.type) else { return nil }
                    r[f.name] = v
                } else if let def = f.defaultExpr {
                    var sc: Scopes = [[:]]
                    guard let v = try? eval(def, &sc) else { return nil }
                    r[f.name] = v
                } else { return nil }
            }
            return .record(r)
        case .optional(let inner):
            if raw is NSNull { return .none }
            return decodeSaved(raw, inner)
        case .unit: return nil
        }
    }

    private func encodeSaved(_ v: Value) -> Any {
        switch v {
        case .int(let i): return i
        case .float(let d): return d
        case .text(let s): return s
        case .bool(let b): return b
        case .list(let xs): return xs.map { encodeSaved($0) }
        case .record(let r): return r.mapValues { encodeSaved($0) }
        case .none: return NSNull()
        }
    }

    /// The values of the `saved state`s as JSON text for the host to keep, or nil if there are none or they
    /// are over 64 KB (the host should then keep nothing and may tell the person).
    public func savedJSON() -> String? {
        if savedNames.isEmpty { return nil }
        var out: [String: Any] = [:]
        for n in savedNames { if let v = state[n] { out[n] = encodeSaved(v) } }
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), d.count <= 65536 else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public var savedTooBig: Bool { !savedNames.isEmpty && savedJSON() == nil }

    public var screens: [String] { prog.views.map { $0.name } }

    public func goto(_ name: String) {
        if name == screen { return }
        history.append(screen)
        if history.count > 50 { history.removeFirst() }
        screen = name
    }
    public func back() { if let s = history.popLast() { screen = s } }
    /// Jump straight to a page without adding to history (used for addresses like page.tern#menu).
    public func show(_ name: String) -> Bool {
        guard views[name] != nil else { return false }
        screen = name; history = []
        return true
    }

    func rtErr(_ msg: String, _ pos: Pos) -> TernError { TernError(msg, pos, "runtime error") }

    private func tick(_ pos: Pos) throws {
        steps += 1
        if steps > MAX_STEPS { throw rtErr("this page did too much work at once (more than \(MAX_STEPS / 1_000_000) million steps); look for very large loops", pos) }
    }

    func lookup(_ name: String, _ scopes: Scopes, _ pos: Pos) throws -> Value {
        for sc in scopes.reversed() { if let v = sc[name] { return v } }
        if let v = state[name] { return v }
        if let v = CONST_VALUES[name] { return v }
        throw rtErr("'\(name)' is used before it has a value (states are set up in order, top to bottom)", pos)
    }

    func execBlock(_ stmts: [Stmt], _ scopes: inout Scopes) throws {
        scopes.append([:])
        defer { scopes.removeLast() }
        for s in stmts { try exec(s, &scopes) }
    }

    func exec(_ s: Stmt, _ scopes: inout Scopes) throws {
        try tick(s.pos)
        switch s.kind {
        case .letVar(let name, _, let value):
            let v = try eval(value, &scopes)
            scopes[scopes.count - 1][name] = v
        case .assign(let name, let value):
            let v = try eval(value, &scopes)
            for i in stride(from: scopes.count - 1, through: 0, by: -1) where scopes[i][name] != nil {
                scopes[i][name] = v
                return
            }
            state[name] = v
        case .ifElse(let cond, let then, let other):
            try execBlock(try eval(cond, &scopes).asBool ? then : other, &scopes)
        case .forIn(let v, let iter, let body):
            for item in try eval(iter, &scopes).asList {
                scopes.append([v: item])
                defer { scopes.removeLast() }
                try execBlock(body, &scopes)
            }
        case .goto(let name): goto(name)
        case .back: back()
        case .ret(let value):
            throw ReturnSignal(value: try value.map { try eval($0, &scopes) } ?? .none)
        case .expr(let e):
            if case .mcall = e.kind, e.writeBack { try runMutating(e, &scopes) } else { _ = try eval(e, &scopes) }
        case .setPath(let target, let value):
            let v = try eval(value, &scopes)
            let loc = try locate(target, &scopes)
            try writePath(loc, &scopes) { _ in v }
        }
    }

    // ---- changing a field or a method's self. Values are never shared, so a change builds a new value
    // for the whole path and stores it back in the variable the path starts from.
    enum Step { case field(String); case index(Int, Pos) }
    struct Loc { var root: String; var steps: [Step] }

    func locate(_ t: Expr, _ scopes: inout Scopes) throws -> Loc {   // evaluates every list index once
        switch t.kind {
        case .variable(let n): return Loc(root: n, steps: [])
        case .field(let inner, let n):
            var loc = try locate(inner, &scopes); loc.steps.append(.field(n)); return loc
        case .index(let inner, let idx):
            var loc = try locate(inner, &scopes)
            loc.steps.append(.index(try eval(idx, &scopes).asInt, t.pos)); return loc
        default: return Loc(root: "", steps: [])
        }
    }
    func readPath(_ loc: Loc, _ scopes: Scopes, _ pos: Pos) throws -> Value {
        var v = try lookup(loc.root, scopes, pos)
        for st in loc.steps {
            switch st {
            case .field(let n): if case .record(let r) = v { v = r[n] ?? .none }
            case .index(let i, let p):
                let xs = v.asList
                if !(i >= 0 && i < xs.count) { throw rtErr("index \(i) is outside the list (length \(xs.count))", p) }
                v = xs[i]
            }
        }
        return v
    }
    func writePath(_ loc: Loc, _ scopes: inout Scopes, _ f: (Value) -> Value) throws {
        func apply(_ cur: Value, _ k: Int) throws -> Value {
            if k == loc.steps.count { return f(cur) }
            switch loc.steps[k] {
            case .field(let n):
                guard case .record(var r) = cur else { return cur }
                r[n] = try apply(r[n] ?? .none, k + 1)
                return .record(r)
            case .index(let i, let p):
                var xs = cur.asList
                if !(i >= 0 && i < xs.count) { throw rtErr("index \(i) is outside the list (length \(xs.count))", p) }
                xs[i] = try apply(xs[i], k + 1)
                return .list(xs)
            }
        }
        for i in stride(from: scopes.count - 1, through: 0, by: -1) where scopes[i][loc.root] != nil {
            scopes[i][loc.root] = try apply(scopes[i][loc.root]!, 0)
            return
        }
        state[loc.root] = try apply(state[loc.root] ?? .none, 0)
    }
    func runMutating(_ e: Expr, _ scopes: inout Scopes) throws {
        guard case .mcall(let recv, _, let argExprs) = e.kind else { return }
        let loc = try locate(recv, &scopes)
        let cur = try readPath(loc, scopes, e.pos)
        let args = try argExprs.map { try eval($0, &scopes) }
        let out = try runBody(methods[e.method!]!, ["self": cur], args, e, e.method!)
        let newSelf = out.vars["self"] ?? cur
        try writePath(loc, &scopes) { _ in newSelf }
    }
    /// Runs a function or method body; `vars` holds `self` for methods. Returns the result and the final variables.
    func runBody(_ f: FnDecl, _ vars: [String: Value], _ args: [Value], _ e: Expr, _ name: String) throws -> (ret: Value, vars: [String: Value]) {
        depth += 1
        defer { depth -= 1 }
        if depth > MAX_CALL_DEPTH { throw rtErr("\(name)() recursed too deeply", e.pos) }
        var params = vars
        for (p, a) in zip(f.params, args) { params[p.0] = a }
        var frame: Scopes = [[:], params]
        do { try execBlock(f.body, &frame) } catch let r as ReturnSignal { return (r.value, frame[1]) }
        return (.none, frame[1])
    }

    func eval(_ e: Expr, _ scopes: inout Scopes) throws -> Value {
        try tick(e.pos)
        switch e.kind {
        case .int(let v): return .int(v)
        case .float(let v): return .float(v)
        case .str(let v): return .text(v)
        case .bool(let v): return .bool(v)
        case .color(let v): return .text(v)
        case .null: return .none
        case .variable(let name): return try lookup(name, scopes, e.pos)
        case .list(let items): return .list(try items.map { try eval($0, &scopes) })
        case .unary(let op, let inner):
            let v = try eval(inner, &scopes)
            if op == "!" { return .bool(!v.asBool) }
            switch v {
            case .int(let i):
                let (r, o) = Int(0).subtractingReportingOverflow(i)
                if o { throw tooBig(e) }
                return .int(r)
            case .float(let f): return .float(-f)
            default: return v
            }
        case .index(let list, let idx):
            let lst = try eval(list, &scopes).asList, i = try eval(idx, &scopes).asInt
            if !(i >= 0 && i < lst.count) { return .none }
            return lst[i]
        case .binary(let op, let l, let r):
            return try binop(e, op, l, r, &scopes)
        case .call(let name, let args):
            return try call(e, name, args, &scopes)
        case .mcall(let recv, _, let argExprs):
            let selfVal = try eval(recv, &scopes)
            let args = try argExprs.map { try eval($0, &scopes) }
            return try runBody(methods[e.method!]!, ["self": selfVal], args, e, e.method!).ret
        case .construct(let name, let fields):
            var o: [String: Value] = [:]
            var given = Set<String>()
            for (n, v, _) in fields { o[n] = try eval(v, &scopes); given.insert(n) }
            if let st = structDecls[name] ?? structDecls[name] { // fill defaults
                for f in st.fields where !given.contains(f.name) {
                    if let def = f.defaultExpr { o[f.name] = try eval(def, &scopes) }
                }
            }
            return .record(o)
        case .field(let inner, let name):
            if case .record(let r) = try eval(inner, &scopes) { return r[name] ?? .none }
            return .none
        case .with(let inner, let updates):
            guard case .record(var r) = try eval(inner, &scopes) else { return .none }
            for (n, v, _) in updates { r[n] = try eval(v, &scopes) }
            return .record(r)
        }
    }

    private func tooBig(_ e: Expr) -> TernError { rtErr("this number is too big for an Int", e.pos) }

    func binop(_ e: Expr, _ op: String, _ l: Expr, _ r: Expr, _ scopes: inout Scopes) throws -> Value {
        if op == "&&" { return .bool(try eval(l, &scopes).asBool && eval(r, &scopes).asBool) }
        if op == "||" { return .bool(try eval(l, &scopes).asBool || eval(r, &scopes).asBool) }
        let a = try eval(l, &scopes), b = try eval(r, &scopes)
        switch op {
        case "==": return .bool(a == b)
        case "!=": return .bool(a != b)
        default: break
        }
        switch (a, b) {
        case (.text(let x), .text(let y)):
            if x.utf16.count + y.utf16.count > MAX_TEXT { throw rtErr("this text is too long", e.pos) }
            return .text(x + y)
        case (.list(let x), .list(let y)):
            if x.count + y.count > MAX_LIST { throw rtErr("this list is too long (over \(MAX_LIST) items)", e.pos) }
            return .list(x + y)
        case (.int(let x), .int(let y)):
            switch op {
            case "+": let (v, o) = x.addingReportingOverflow(y); if o { throw tooBig(e) }; return .int(v)
            case "-": let (v, o) = x.subtractingReportingOverflow(y); if o { throw tooBig(e) }; return .int(v)
            case "*": let (v, o) = x.multipliedReportingOverflow(by: y); if o { throw tooBig(e) }; return .int(v)
            case "/":
                if y == 0 { throw rtErr("division by zero", e.pos) }
                let (q, o) = x.dividedReportingOverflow(by: y); if o { throw tooBig(e) }
                return .int((x % y != 0 && ((x < 0) != (y < 0))) ? q - 1 : q)   // rounds down
            case "%":
                if y == 0 { throw rtErr("division by zero", e.pos) }
                let (m, _) = x.remainderReportingOverflow(dividingBy: y)
                return .int((m + y) % y)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: break
            }
        case (.float(let x), .float(let y)):
            switch op {
            case "+": return .float(x + y)
            case "-": return .float(x - y)
            case "*": return .float(x * y)
            case "/":
                if y == 0 { throw rtErr("division by zero", e.pos) }
                return .float(x / y)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: break
            }
        default: break
        }
        throw rtErr("'\(op)' cannot be used here", e.pos)
    }

    private func toInt(_ d: Double, _ e: Expr) throws -> Int {
        guard d.isFinite, d >= -9.2e18, d <= 9.2e18 else { throw rtErr("this number is too big for an Int", e.pos) }
        return Int(d)
    }

    func call(_ e: Expr, _ name: String, _ argExprs: [Expr], _ scopes: inout Scopes) throws -> Value {
        let args = try argExprs.map { try eval($0, &scopes) }
        if let f = fns[name] {
            return try runBody(f, [:], args, e, name).ret
        }
        func outside(_ i: Int, _ n: Int) -> TernError { rtErr("index \(i) is outside the list (length \(n))", e.pos) }
        switch name {
        case "toText":
            if case .float(let f) = args[0] { return .text(floatToText(f)) }
            return .text(args[0].description)
        case "toFloat": return .float(Double(args[0].asInt))
        case "round": return .int(try toInt(roundHalfUp(args[0].asFloat), e))
        case "floor": return .int(try toInt(args[0].asFloat.rounded(.down), e))
        case "ceil": return .int(try toInt(args[0].asFloat.rounded(.up), e))
        case "sqrt":
            let x = args[0].asFloat
            if x < 0 { throw rtErr("cannot take the square root of a negative number", e.pos) }
            return .float(x.squareRoot())
        case "fixed": return .text(fixedDecimals(args[0].asFloat, clamp(args[1].asInt, 0, 12)))
        case "toIntOr":
            let t = args[0].asText.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = t.hasPrefix("-") ? t.dropFirst() : Substring(t)
            if !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(t) { return .int(v) }
            return args[1]
        case "toFloatOr":
            let t = args[0].asText.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = t.hasPrefix("-") ? String(t.dropFirst()) : t
            let isDigit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
            let pieces = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let whole = pieces[0], frac = pieces.count > 1 ? pieces[1] : ""
            let ok = whole.allSatisfy(isDigit) && frac.allSatisfy(isDigit) &&
                (pieces.count == 1 ? !whole.isEmpty : (!whole.isEmpty || !frac.isEmpty))
            if !ok { return args[1] }
            if whole.isEmpty { body = "0" + body }
            if body.hasSuffix(".") { body += "0" }
            guard let v = Double(body) else { return args[1] }
            return .float(t.hasPrefix("-") ? -v : v)
        case "len":
            if case .text(let s) = args[0] { return .int(s.utf16.count) }
            return .int(args[0].asList.count)
        case "append":
            let xs = args[0].asList
            if xs.count >= MAX_LIST { throw rtErr("this list is too long (over \(MAX_LIST) items)", e.pos) }
            return .list(xs + [args[1]])
        case "removeAt":
            var xs = args[0].asList; let i = args[1].asInt
            if !(i >= 0 && i < xs.count) { throw outside(i, xs.count) }
            xs.remove(at: i); return .list(xs)
        case "setAt":
            var xs = args[0].asList; let i = args[1].asInt
            if !(i >= 0 && i < xs.count) { throw outside(i, xs.count) }
            xs[i] = args[2]; return .list(xs)
        case "slice":
            let xs = args[0].asList
            let a = clamp(args[1].asInt, 0, xs.count), b = clamp(args[2].asInt, 0, xs.count)
            return .list(b > a ? Array(xs[a..<b]) : [])
        case "reverse": return .list(args[0].asList.reversed())
        case "sort", "sortOrder":
            let xs = args[0].asList
            func less(_ x: Value, _ y: Value) -> Bool {   // Text compares by UTF-16 code unit, like the playground
                switch (x, y) {
                case (.int(let a), .int(let b)): return a < b
                case (.float(let a), .float(let b)): return a < b
                case (.text(let a), .text(let b)): return a.utf16.lexicographicallyPrecedes(b.utf16)
                default: return false
                }
            }
            let idx = xs.indices.sorted { i, j in less(xs[i], xs[j]) || (!less(xs[j], xs[i]) && i < j) }
            return name == "sort" ? .list(idx.map { xs[$0] }) : .list(idx.map { .int($0) })
        case "range": return .list((0..<clamp(args[0].asInt, 0, 10000)).map { .int($0) })
        case "trim": return .text(args[0].asText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "upper": return .text(args[0].asText.uppercased())
        case "lower": return .text(args[0].asText.lowercased())
        case "contains":
            let s = args[0].asText, sub = args[1].asText
            return .bool(sub.isEmpty || s.range(of: sub, options: .literal) != nil)
        case "join": return .text(args[0].asList.map { $0.asText }.joined(separator: args[1].asText))
        case "rgb": return .text("#" + args.map { String(format: "%02x", clamp($0.asInt, 0, 255)) }.joined())
        case "has": return .bool(args[0] != .none)
        case "unwrap":
            if args[0] == .none { throw rtErr("unwrap() was called on null (no value)", e.pos) }
            return args[0]
        case "valueOr": return args[0] == .none ? args[1] : args[0]
        default: throw rtErr("unknown function '\(name)'", e.pos)
        }
    }

    func inputNode(_ target: Expr, _ placeholder: Expr?, _ scopes: inout Scopes, mods: [Mod] = [], kind: String = "input", numeric: Bool = false) throws -> RNode {
        var n = RNode(.input)
        if case .variable(let name) = target.kind { n.name = name }
        let loc = try locate(target, &scopes)
        let cur = try readPath(loc, scopes, target.pos)
        if numeric { n.number = cur.asInt } else { n.value = cur.asText }
        n.placeholder = try placeholder.map { try eval($0, &scopes).asText } ?? ""
        n.style = try resolve(mods, kind, &scopes)
        let snap = scopes
        n.set = { [unowned self] v in
            var sc = snap
            let l = try self.locate(target, &sc)
            try self.writePath(l, &sc) { _ in numeric ? .int(Int(v) ?? 0) : .text(v) }
        }
        lock(&n)
        return n
    }
    /// A disabled control does nothing when it is tapped or edited, whatever the host does.
    func lock(_ n: inout RNode) {
        guard n.style.flag("disabled") == true else { return }
        if n.click != nil { n.click = {} }
        if n.set != nil { n.set = { _ in } }
    }
    func checkboxNode(_ cond: Expr, _ label: Expr?, _ mods: [Mod], _ act: [Stmt]?, _ scopes: inout Scopes) throws -> RNode {
        var n = RNode(.checkbox)
        n.text = try label.map { try eval($0, &scopes).asText } ?? ""
        n.checked = try eval(cond, &scopes).asBool
        n.style = try resolve(mods, "checkbox", &scopes)
        if let act = act { n.click = action(act, scopes) }
        else if case .variable(let name) = cond.kind {
            n.click = { [unowned self] in self.state[name] = .bool(!(self.state[name]?.asBool ?? false)) }
        }
        lock(&n)
        return n
    }

    // ---- style resolution
    func applyMod(_ out: inout Style, _ m: Mod, _ scopes: inout Scopes) throws {
        if FLAGS.contains(m.name) {
            out[m.name] = .bool(try m.when.map { try eval($0, &scopes).asBool } ?? true)
            return
        }
        let v = try eval(m.value!, &scopes)
        switch m.name {
        case "size": out["size"] = .int(clamp(v.asInt, 6, 96))
        case "padding", "gap", "margin": out[m.name] = .int(clamp(v.asInt, 0, 64))
        case "grow": out["grow"] = .int(clamp(v.asInt, 0, 12))
        case "radius": out["radius"] = .int(clamp(v.asInt, 0, 999))
        case "width", "height", "maxwidth", "minwidth": out[m.name] = .int(clamp(v.asInt, 1, 2000))
        default: out[m.name] = v
        }
    }
    func resolve(_ mods: [Mod], _ kind: String, _ scopes: inout Scopes) throws -> Style {
        var out = Style()
        let allowed = ALLOWED[kind]!
        for m in mods {
            if m.name == "style" {
                for (n, _) in m.styleNames {
                    for sm in styles[n]!.mods where allowed.contains(sm.name) {
                        var empty: Scopes = [[:]]
                        try applyMod(&out, sm, &empty)
                    }
                }
            } else { try applyMod(&out, m, &scopes) }
        }
        return out
    }

    // ---- render tree
    /// A repeating action set up with `every`. The host runs `tick` every `ms` milliseconds while the timer stays in
    /// `Page.timers` (refreshed by each `render()`). At least 100 ms apart, at most 4 at once, and a timer whose
    /// action fails 3 times in a row stops.
    public struct PageTimer { public let key: String; public let ms: Int; public let tick: () throws -> Void }
    public private(set) var timers: [PageTimer] = []
    private var timerSeq = 0
    private var faults: [String: Int] = [:]

    private func timerNode(_ ms: Expr, _ when: Expr?, _ action: [Stmt], _ pos: Pos, _ scopes: inout Scopes) throws -> PageTimer? {
        if let w = when, !(try eval(w, &scopes).asBool) { return nil }
        let n = timerSeq; timerSeq += 1
        if n >= 4 { return nil }
        let key = "\(pos.line):\(pos.col)#\(n)"
        if (faults[key] ?? 0) >= 3 { return nil }
        let snap = scopes
        let interval = clamp(try eval(ms, &scopes).asInt, 100, 3_600_000)
        return PageTimer(key: key, ms: interval, tick: { [unowned self] in
            self.steps = 0; self.depth = 0
            var sc = snap
            do { try self.execBlock(action, &sc); self.faults[key] = 0 }
            catch var e as TernError {
                self.faults[key, default: 0] += 1
                if self.faults[key]! >= 3 { e.msg += " (this timer has stopped after 3 errors in a row)" }
                throw e
            }
        })
    }

    public func render() throws -> [RNode] {
        timerSeq = 0; timers = []
        steps = 0
        var out: [RNode] = []
        var scopes: Scopes = [[:]]
        try view(views[screen]!.body, &scopes, &out)
        return out
    }

    /// Runs a button or link action with fresh limits.
    private func action(_ stmts: [Stmt], _ snap: Scopes) -> () throws -> Void {
        return { [unowned self] in
            self.steps = 0
            self.depth = 0
            var sc = snap
            try self.execBlock(stmts, &sc)
        }
    }

    func view(_ items: [ViewItem], _ scopes: inout Scopes, _ out: inout [RNode]) throws {
        for it in items {
            try tick(it.pos)
            switch it.kind {
            case .textual(let kind, let e, let mods):
                var n = RNode(RNode.Kind(rawValue: kind)!)
                n.text = try eval(e, &scopes).asText
                n.style = try resolve(mods, kind, &scopes)
                out.append(n)
            case .para(let mods, let spans):
                var n = RNode(.para)
                n.style = try resolve(mods, "para", &scopes)
                var inherit = n.style; inherit["align"] = nil
                for sp in spans {
                    let text = try eval(sp.e, &scopes).asText
                    var st = inherit
                    for (k, v) in try resolve(sp.mods, "span", &scopes).props { st[k] = v }
                    n.spans.append((text, st))
                }
                out.append(n)
            case .button(let label, let mods, let act):
                var n = RNode(.button)
                n.text = try eval(label, &scopes).asText
                n.style = try resolve(mods, "button", &scopes)
                n.click = action(act, scopes)
                lock(&n)
                out.append(n)
            case .checkbox(let cond, let label, let mods, let act):
                out.append(try checkboxNode(cond, label, mods, act, &scopes))
            case .choice(let kind, let target, let options, let ph, let mods):
                var n = try inputNode(target, ph, &scopes, mods: mods, kind: kind)
                n.kind = kind == "select" ? .select : .radio
                n.options = try eval(options, &scopes).asList.map { $0.asText }
                out.append(n)
            case .grid(let cols, let mods, let body):
                var n = RNode(.grid)
                n.columns = clamp(try eval(cols, &scopes).asInt, 1, 12)
                try view(body, &scopes, &n.children)
                n.style = try resolve(mods, "grid", &scopes)
                out.append(n)
            case .modal(let cond, let mods, let act, let body):
                if !(try eval(cond, &scopes).asBool) { break }   // a closed modal draws nothing
                var n = RNode(.modal)
                try view(body, &scopes, &n.children)
                n.style = try resolve(mods, "modal", &scopes)
                if let act = act { n.click = action(act, scopes) }
                else if case .variable(let name) = cond.kind {
                    n.click = { [unowned self] in self.state[name] = .bool(false) }
                }
                out.append(n)
            case .input(let target, let ph, let mods):
                out.append(try inputNode(target, ph, &scopes, mods: mods))
            case .every(let ms, let when, let action):
                if let t = try timerNode(ms, when, action, it.pos, &scopes) { timers.append(t) }
            case .area(let target, let ph, let mods):
                var n = try inputNode(target, ph, &scopes, mods: mods, kind: "textarea")
                n.kind = .textarea
                out.append(n)
            case .slider(let target, let lo, let hi, let mods):
                var n = try inputNode(target, nil, &scopes, mods: mods, kind: "slider", numeric: true)
                n.kind = .slider
                n.lower = try eval(lo, &scopes).asInt; n.upper = try eval(hi, &scopes).asInt
                if n.upper < n.lower { throw rtErr("this slider ends (\(n.upper)) before it starts (\(n.lower))", target.pos) }
                n.number = clamp(n.number, n.lower, n.upper)
                out.append(n)
            case .box(let kind, let mods, let body):
                var n = RNode(kind == "row" ? .row : .column)
                try view(body, &scopes, &n.children)
                n.style = try resolve(mods, kind, &scopes)
                out.append(n)
            case .table(let mods, let resizable, let body):
                var kids: [RNode] = []
                try view(body, &scopes, &kids)
                var n = RNode(.table)
                n.resizable = resizable
                n.style = try resolve(mods, "table", &scopes)
                n.header = kids.first(where: { $0.kind == .header })?.cells
                let lines = kids.filter { $0.kind == .cells }
                n.rows = lines.map { $0.cells }
                n.hrow = kids.first(where: { $0.kind == .header })?.row
                n.body = lines.compactMap { $0.row }
                out.append(n)
            case .cells(let isHeader, let cells):
                var n = RNode(isHeader ? .header : .cells)
                var row = TRow()
                for c in cells {
                    var tc = TCell()
                    if c.kind == "select" {
                        let sel = try inputNode(c.cond!, c.e, &scopes)
                        tc.text = sel.value; tc.span = c.span; tc.kind = "select"; tc.placeholder = sel.placeholder; tc.set = sel.set
                        tc.options = try eval(c.opts!, &scopes).asList.map { $0.asText }
                        row.cells.append(tc)
                        n.cells.append("[select: " + (sel.value.isEmpty ? sel.placeholder : sel.value) + "]")
                        if c.span > 1 { n.cells += Array(repeating: "", count: c.span - 1) }
                        continue
                    }
                    if c.kind == "input" {
                        let inp = try inputNode(c.cond!, c.e, &scopes)
                        tc.text = inp.value; tc.span = c.span; tc.kind = "input"; tc.placeholder = inp.placeholder; tc.set = inp.set
                        row.cells.append(tc)
                        n.cells.append("[_" + inp.value + "_]")
                        if c.span > 1 { n.cells += Array(repeating: "", count: c.span - 1) }
                        continue
                    }
                    if c.kind == "checkbox" {
                        let cb = try checkboxNode(c.cond!, c.e, c.mods, c.action, &scopes)
                        tc.text = cb.text; tc.span = c.span; tc.kind = "checkbox"; tc.checked = cb.checked
                        tc.style = cb.style; tc.click = cb.click
                        row.cells.append(tc)
                        n.cells.append((cb.checked ? "[x] " : "[ ] ") + cb.text)
                        if c.span > 1 { n.cells += Array(repeating: "", count: c.span - 1) }
                        continue
                    }
                    tc.text = try eval(c.e, &scopes).asText
                    tc.span = c.span; tc.kind = c.kind
                    tc.style = try resolve(c.mods, c.kind == "text" ? "cellrow" : c.kind, &scopes)
                    tc.target = try c.target.map { try eval($0, &scopes).asText }
                    if let a = c.action { tc.click = action(a, scopes) }
                    if tc.style.flag("disabled") == true, tc.click != nil { tc.click = {} }
                    row.cells.append(tc)
                    n.cells.append(tc.text)
                    if c.span > 1 { n.cells += Array(repeating: "", count: c.span - 1) }
                }
                n.row = row
                out.append(n)
            case .vif(let cond, let then, let other):
                try view(try eval(cond, &scopes).asBool ? then : other, &scopes, &out)
            case .vfor(let v, let iter, let body):
                for item in try eval(iter, &scopes).asList {
                    scopes.append([v: item])
                    defer { scopes.removeLast() }
                    try view(body, &scopes, &out)
                }
            case .component(let name, let args):
                if let c = componentDecls[name] {
                    var props: [String: Value] = [:]
                    var given = Set<String>()
                    for (fname, val, _) in args { props[fname] = try eval(val, &scopes); given.insert(fname) }
                    if case .structType(let sn) = c.propType, let st = structDecls[sn] {
                        for f in st.fields where !given.contains(f.name) {
                            if let def = f.defaultExpr { props[f.name] = try eval(def, &scopes) }
                        }
                    }
                    scopes.append([c.propName: .record(props)])
                    defer { scopes.removeLast() }
                    try view(c.body, &scopes, &out)
                }
            case .link(let label, let target, let act, let mods):
                var n = RNode(.link)
                n.text = try eval(label, &scopes).asText
                n.target = try target.map { try eval($0, &scopes).asText }
                if let act = act { n.click = action(act, scopes) }
                n.style = try resolve(mods, "link", &scopes)
                out.append(n)
            case .image(let e, let mods):
                var n = RNode(.image)
                var st = try resolve(mods, "image", &scopes)
                n.alt = st.text("alt") ?? ""
                st["alt"] = nil
                n.style = st
                n.text = try eval(e, &scopes).asText
                out.append(n)
            case .divider:
                out.append(RNode(.divider))
            }
        }
    }
}

// ---------------------------------------------------------------- plain-text view
public func renderText(_ nodes: [RNode], _ indent: Int = 0) -> [String] {
    let pad = String(repeating: "  ", count: indent)
    var lines: [String] = []
    func mark(_ txt: String, _ st: Style) -> String {
        var t = txt
        if st.flag("bold") == true { t = "**\(t)**" }
        if st.flag("italic") == true { t = "_\(t)_" }
        return t
    }
    func padEnd(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.utf16.count)) }
    for n in nodes {
        switch n.kind {
        case .heading: lines.append(pad + n.text.uppercased())
        case .text: lines.append(pad + mark(n.text, n.style))
        case .bullet: lines.append("\(pad)* \(mark(n.text, n.style))")
        case .para: lines.append(pad + n.spans.map { mark($0.text, $0.style) }.joined())
        case .button: lines.append("\(pad)[ \(n.text) ]")
        case .checkbox: lines.append("\(pad)[\(n.checked ? "x" : " ")] \(n.text)")
        case .input:
            let shown = !n.value.isEmpty ? n.value : (n.placeholder.isEmpty ? "" : "(\(n.placeholder))")
            lines.append("\(pad)[_\(shown)_]")
        case .link: lines.append("\(pad)\(n.text) -> \(n.target ?? "(action)")")
        case .image: lines.append("\(pad)[image: \(n.text)]")
        case .divider: lines.append(pad + String(repeating: "-", count: 40))
        case .table:
            let rows = (n.header.map { [$0] } ?? []) + n.rows
            let widths = rows.first.map { first in first.indices.map { c in rows.map { $0[c].utf16.count }.max() ?? 0 } } ?? []
            for (i, r) in rows.enumerated() {
                lines.append(pad + "| " + r.enumerated().map { padEnd($0.element, widths[$0.offset]) }.joined(separator: " | ") + " |")
                if i == 0 && n.header != nil { lines.append(pad + "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|") }
            }
        case .textarea: lines.append("\(pad)[textarea: \((n.value.isEmpty ? n.placeholder : n.value).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")]")
        case .slider: lines.append("\(pad)[slider: \(n.number) in \(n.lower)..\(n.upper)]")
        case .select: lines.append("\(pad)[select: \(n.value.isEmpty ? n.placeholder : n.value)]")
        case .radio: for o in n.options { lines.append("\(pad)(\(o == n.value ? "x" : " ")) \(o)") }
        case .grid:
            lines.append("\(pad)<grid \(n.columns)>"); lines.append(contentsOf: renderText(n.children, indent + 1))
        case .modal:
            lines.append("\(pad)[modal]"); lines.append(contentsOf: renderText(n.children, indent + 1)); lines.append("\(pad)[/modal]")
        case .row, .column:
            lines.append("\(pad)<\(n.kind.rawValue)>")
            lines.append(contentsOf: renderText(n.children, indent + 1))
        case .header, .cells: break
        }
    }
    return lines
}

// ---------------------------------------------------------------- big stack
/// Runs engine work on a thread with a large stack, so deep (but legal) pages
/// cannot overflow the main thread's stack. Blocks until done.
public func onBigStack<T>(_ body: @escaping () throws -> T) throws -> T {
    var result: Result<T, Error>!
    let done = DispatchSemaphore(value: 0)
    let t = Thread {
        result = Result { try body() }
        done.signal()
    }
    t.stackSize = 512 << 20
    t.start()
    done.wait()
    return try result.get()
}
