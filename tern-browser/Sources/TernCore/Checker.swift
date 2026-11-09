// Type checker. Every page is checked completely before it runs.

private let LAYOUT: [String] = ["margin", "grow", "maxwidth", "minwidth"]   // size and spacing words most blocks accept
private let TEXT_PROPS: [String] = ["size", "bold", "italic", "underline", "strike", "color", "background", "align", "font", "padding", "radius", "border", "style"] + LAYOUT
let ALL_PROPS: [String] = ["size", "bold", "italic", "underline", "strike", "color", "background", "align", "font", "padding", "radius", "border", "width", "height", "alt", "gap"] + LAYOUT
let ALLOWED: [String: Set<String>] = [
    "heading": Set(TEXT_PROPS), "text": Set(TEXT_PROPS), "bullet": Set(TEXT_PROPS), "para": Set(TEXT_PROPS),
    "span": ["size", "bold", "italic", "underline", "strike", "color", "background", "font", "style"],
    "link": ["size", "bold", "italic", "strike", "color", "font", "style"],
    "button": ["size", "bold", "italic", "color", "background", "font", "padding", "radius", "border", "width", "style", "margin", "grow", "disabled"],
    "row": Set(["background", "padding", "radius", "border", "width", "style", "gap", "align"] + LAYOUT),
    "column": Set(["background", "padding", "radius", "border", "width", "style", "gap", "align"] + LAYOUT),
    "grid": Set(["background", "padding", "radius", "border", "width", "style", "gap"] + LAYOUT),
    "image": Set(["width", "height", "radius", "border", "align", "alt", "style"] + LAYOUT),
    "select": Set(["size", "color", "font", "width", "style", "disabled"] + LAYOUT),
    "radio": ["size", "color", "font", "style", "margin", "disabled"],
    "input": Set(["width", "disabled"] + LAYOUT),
    "textarea": Set(["width", "height", "size", "font", "disabled"] + LAYOUT),
    "slider": Set(["width", "color", "disabled"] + LAYOUT),
    "modal": ["width", "background", "padding", "radius", "border", "style"],
    "checkbox": ["size", "bold", "italic", "color", "font", "style", "disabled"],
    "table": Set(["height", "padding", "size", "color", "background", "border", "font", "style"] + LAYOUT),
    "cellrow": ["size", "bold", "italic", "underline", "strike", "color", "background", "align", "font", "style"],
]
private let PROP_TYPES: [String: TType] = [
    "size": .int, "padding": .int, "radius": .int, "width": .int, "height": .int, "gap": .int, "margin": .int, "grow": .int, "maxwidth": .int, "minwidth": .int, "color": .color, "background": .color,
    "border": .color, "align": .align, "font": .font, "alt": .text,
]
public let BUILTINS: [String: Int] = [
    "toText": 1, "len": 1, "append": 2, "removeAt": 2, "range": 1, "trim": 1, "upper": 1, "lower": 1,
    "contains": 2, "join": 2, "rgb": 3, "setAt": 3, "slice": 3, "sort": 1, "sortOrder": 1, "reverse": 1,
    "toFloat": 1, "round": 1, "floor": 1, "ceil": 1, "fixed": 2, "sqrt": 1, "toIntOr": 2, "toFloatOr": 2,
    "has": 1, "valueOr": 2, "unwrap": 1,
]

func alwaysReturns(_ stmts: [Stmt]) -> Bool {
    for s in stmts {
        if case .ret = s.kind { return true }
        if case .ifElse(_, let then, let other) = s.kind, !other.isEmpty, alwaysReturns(then), alwaysReturns(other) { return true }
    }
    return false
}

/// What the host knows about images, so literal image names can be checked.
public struct AssetInfo {
    public var names: [String]
    public var hint: String   // how to add one, shown in the error
    public init(names: [String], hint: String = "put the image file next to the page, or use a web address") {
        self.names = names; self.hint = hint
    }
}

final class Checker {
    let prog: Program
    let assets: AssetInfo?
    var structs: [String: StructDecl] = [:]
    var methods: [String: (params: [TType], ret: TType)] = [:]
    var curMethod: FnDecl? = nil
    var stmtCall: Expr? = nil
    var states: [String: TType] = [:]
    var fns: [String: ([TType], TType)] = [:]
    var styles: [String: StyleDecl] = [:]
    var views: [String: ViewDecl] = [:]
    var scopes: [[String: TType]] = []
    var ret: TType? = nil
    var tbl: (cols: Int?, header: Bool)? = nil
    var nest = 0          // how many row, column or modal bodies we are inside

    init(_ prog: Program, assets: AssetInfo?) { self.prog = prog; self.assets = assets }

    func err(_ msg: String, _ pos: Pos) -> TernError { TernError(msg, pos, "type error") }

    func lookup(_ name: String) -> TType? {
        for sc in scopes.reversed() { if let t = sc[name] { return t } }
        if let t = states[name] { return t }
        return CONST_TYPES[name]
    }
    func declare(_ name: String, _ ty: TType, _ pos: Pos) throws {
        if scopes[scopes.count - 1][name] != nil { throw err("'\(name)' is already defined here", pos) }
        scopes[scopes.count - 1][name] = ty
    }

    func run() throws {
        let p = prog
        for st in p.structs {
            if BASE_TYPES[st.name] != nil || st.name == "List" { throw err("'\(st.name)' is a built-in type name; pick another name for the struct", st.namePos) }
            if structs[st.name] != nil { throw err("struct '\(st.name)' is defined twice", st.namePos) }
            if st.fields.isEmpty { throw err("struct '\(st.name)' needs at least one field", st.pos) }
            var seen = Set<String>()
            for (fname, _, fpos) in st.fields {
                if seen.contains(fname) || fname == "__proto__" {
                    throw err("field '\(fname)' is \(fname == "__proto__" ? "not allowed" : "defined twice") in struct \(st.name)", fpos)
                }
                seen.insert(fname)
            }
            structs[st.name] = st
            for m in st.methods {
                let key = "\(st.name).\(m.name)"
                if seen.contains(m.name) || methods[key] != nil {
                    throw err("'\(m.name)' is defined twice in struct \(st.name) (a method cannot share a name with a field)", m.pos)
                }
                methods[key] = (m.params.map { $0.1 }, m.ret)
            }
        }
        for st in p.structs {
            func reach(_ t0: TType, _ path: [String]) throws {
                var t = t0
                while let el = t.element { t = el }
                guard case .structType(let n) = t, let decl = structs[n] else { return }
                if path.contains(n) {
                    throw err("struct \(st.name) contains itself (\((path + [n]).joined(separator: " -> "))); a struct cannot hold itself, even inside a list", st.namePos)
                }
                for f in decl.fields { try reach(f.1, path + [n]) }
            }
            try reach(.structType(st.name), [])
        }
        for s in p.states {
            if states[s.name] != nil || fns[s.name] != nil { throw err("'\(s.name)' is defined twice", s.pos) }
            states[s.name] = s.type
        }
        for f in p.fns {
            if states[f.name] != nil || fns[f.name] != nil || BUILTINS[f.name] != nil {
                throw err("'\(f.name)' is defined twice or is a built-in name", f.pos)
            }
            fns[f.name] = (f.params.map { $0.1 }, f.ret)
        }
        for s in p.styles {
            if styles[s.name] != nil { throw err("style '\(s.name)' is defined twice", s.pos) }
            styles[s.name] = s
        }
        for v in p.views {
            if views[v.name] != nil {
                let other = v.name == "home" ? "about" : v.name + "2"
                throw err("there are two pages called '\(v.name)'; give each view its own name, like: view \(other) { ... }", v.pos)
            }
            views[v.name] = v
        }
        scopes = [[:]]
        for s in p.states { try expectType(s.initial, s.type, "state '\(s.name)'") }
        for s in p.styles {
            for m in s.mods {
                if m.name == "style" { throw err("a style cannot use another style", m.pos) }
                try checkMods([m], "text", anyKind: true)
            }
        }
        for f in p.fns {
            scopes = [[:]]
            for (name, ty, pos) in f.params { try declare(name, ty, pos) }
            ret = f.ret
            try block(f.body)
            if f.ret != .unit && !alwaysReturns(f.body) { throw err("function '\(f.name)' must return \(f.ret) on every path", f.pos) }
        }
        for st in p.structs {
            for m in st.methods {
                scopes = [["self": .structType(st.name)], [:]]
                for (name, ty, pos) in m.params { try declare(name, ty, pos) }
                ret = m.ret; curMethod = m
                try block(m.body)
                curMethod = nil
                if m.ret != .unit && !alwaysReturns(m.body) { throw err("method '\(m.name)' must return \(m.ret) on every path", m.pos) }
            }
        }
        for v in p.views { ret = nil; scopes = [[:]]; try view(v.body) }
    }

    func checkMods(_ mods: [Mod], _ kind: String, anyKind: Bool = false) throws {
        let allowed: Set<String> = anyKind ? Set(ALL_PROPS + ["style"]) : ALLOWED[kind]!
        for m in mods {
            if !allowed.contains(m.name) {
                let article = "aeiou".contains(kind.first!) ? "an" : "a"
                throw err("\(article) \(kind) cannot have '\(m.name)'", m.pos)
            }
            if m.name == "style" {
                for (n, pos) in m.styleNames where styles[n] == nil {
                    throw err("unknown style '\(n)' (declare it with: style \(n) { ... })", pos)
                }
            } else if FLAGS.contains(m.name) {
                if let w = m.when { try expectType(w, .bool, "'\(m.name) when'") }
            } else {
                try expectType(m.value!, PROP_TYPES[m.name]!, "'\(m.name)'")
            }
        }
    }

    func block(_ stmts: [Stmt]) throws {
        scopes.append([:])
        defer { scopes.removeLast() }
        for s in stmts { try stmt(s) }
    }
    func stmt(_ s: Stmt) throws {
        switch s.kind {
        case .letVar(let name, let ty, let value):
            let t: TType
            if let ty = ty { try expectType(value, ty, "'\(name)'"); t = ty } else { t = try expr(value) }
            try declare(name, t, s.pos)
        case .assign(let name, let value):
            guard let ty = lookup(name) else { throw err("unknown variable '\(name)'", s.pos) }
            if states[name] == nil && CONST_TYPES[name] != nil && !scopes.contains(where: { $0[name] != nil }) {
                throw err("'\(name)' is built in and cannot be changed", s.pos)
            }
            try expectType(value, ty, "'\(name)'")
        case .ifElse(let cond, let then, let other):
            try expectType(cond, .bool, "an if condition"); try block(then); try block(other)
        case .forIn(let v, let iter, let body):
            let ity = try expr(iter)
            guard let el = ity.element else { throw err("can only loop over a List, not \(ity)", iter.pos) }
            scopes.append([v: el, "\0" + v: .bool]); defer { scopes.removeLast() }
            try block(body)
        case .goto(let name):
            if views[name] == nil { throw err("there is no page called '\(name)' (pages are declared with: view \(name) { ... })", s.pos) }
        case .back: break
        case .ret(let value):
            guard let r = ret else { throw err("'return' can only be used inside a function", s.pos) }
            if let v = value { try expectType(v, r, "the returned value") }
            else if r != .unit { throw err("this function must return \(r)", s.pos) }
        case .setPath(let target, let value):
            let ty = try expr(target)
            try checkPath(target, s.pos)
            var fname = ""
            if case .field(_, let n) = target.kind { fname = n }
            try expectType(value, ty, "the field '\(fname)'")
        case .expr(let e):
            switch e.kind {
            case .call, .mcall: break
            default: throw err("this expression does nothing; use a call or an assignment", s.pos)
            }
            stmtCall = e
            _ = try expr(e)
        }
    }

    func pathText(_ t: Expr) -> String {
        switch t.kind {
        case .variable(let n): return n
        case .field(let inner, let n): return "\(pathText(inner)).\(n)"
        case .index(let inner, _): return "\(pathText(inner))[...]"
        default: return "it"
        }
    }
    /// A path like x, x.f, xs[0].f can be changed if it starts at a variable we may change.
    func checkPath(_ t: Expr, _ pos: Pos) throws {
        switch t.kind {
        case .field(let inner, _): return try checkPath(inner, pos)
        case .index(let inner, _): return try checkPath(inner, pos)
        case .variable(let name):
            if name == "self" {
                if let m = curMethod, m.ret != .unit {
                    throw err("method '\(m.name)' returns a value, so it cannot change self; return a changed copy with 'with', or make it return nothing", pos)
                }
                return
            }
            for sc in scopes.reversed() where sc[name] != nil {
                if sc["\0" + name] != nil {
                    throw err("'\(name)' is a copy of a list item, so changing it would be lost; change the list instead, like: xs[0].field = value", pos)
                }
                return
            }
            if states[name] != nil { return }
            throw err("'\(name)' cannot be changed", pos)
        default:
            throw err("only a variable (or a field of one) can be changed, not a computed value", pos)
        }
    }

    func typesCompatible(_ got: TType, _ want: TType) -> Bool {
        if got == want { return true }
        if case .optional(let inner) = want {
            if got == .optional(inner) { return true }
            if typesCompatible(got, inner) { return true }   // T -> T?
        }
        return false
    }
    func expectType(_ e: Expr, _ want: TType, _ what: String) throws {
        let got = try expr(e, want)
        if !typesCompatible(got, want) {
            let hint = want == .text && (got == .int || got == .bool) ? " (use toText(...) to convert \(got) to Text)" : ""
            if case .optional(_) = got, !want.isOptional {
                throw err("\(what) needs \(want) but this is \(got) (use valueOr(..., a fallback) or unwrap(...) to use the value when it is there)", e.pos)
            }
            throw err("\(what) needs \(want) but this is \(got)\(hint)", e.pos)
        }
    }

    func expr(_ e: Expr, _ expected: TType? = nil) throws -> TType {
        switch e.kind {
        case .int: return .int
        case .str: return .text
        case .bool: return .bool
        case .color: return .color
        case .float: return .float
        case .null:
            if case .optional(let inner)? = expected { return .optional(inner) }
            throw err("cannot tell what kind of value null is here; add a type, e.g. let x: Int? = null", e.pos)
        case .variable(let name):
            guard let ty = lookup(name) else {
                if name == "self" { throw err("'self' only exists inside a struct's methods", e.pos) }
                if let st = structs[name] {
                    throw err("'\(name)' is a struct; create one like \(name)(\(st.fields.map { $0.0 + ": ..." }.joined(separator: ", ")))", e.pos)
                }
                if fns[name] != nil || BUILTINS[name] != nil { throw err("'\(name)' is a function; call it like \(name)(...)", e.pos) }
                throw err("unknown name '\(name)'", e.pos)
            }
            return ty
        case .list(let items):
            guard let firstItem = items.first else {
                if let ex = expected, ex.isList { return ex }
                throw err("cannot tell what an empty list holds; add a type, e.g. let xs: List<Int> = []", e.pos)
            }
            let first = try expr(firstItem, expected?.element)
            for it in items.dropFirst() { try expectType(it, first, "every list item") }
            return .list(first)
        case .unary(let op, let inner):
            if op == "!" { try expectType(inner, .bool, "'!'"); return .bool }
            let t = try expr(inner)
            if t != .int && t != .float { throw err("unary '-' needs Int or Float but this is \(t)", inner.pos) }
            return t
        case .binary(let op, let l, let r):
            return try binary(e, op, l, r)
        case .index(let list, let idx):
            let lt = try expr(list)
            guard let el = lt.element else { throw err("can only index a List, not \(lt)", e.pos) }
            try expectType(idx, .int, "a list index")
            return .optional(el)
        case .call(let name, let args):
            return try call(e, name, args, expected)
        case .construct(let name, let fields):
            let st = structs[name]!
            var given = Set<String>()
            for (fname, val, fpos) in fields {
                guard let f = st.fields.first(where: { $0.0 == fname }) else {
                    throw err("\(name) has no field '\(fname)' (its fields are \(st.fields.map { $0.0 }.joined(separator: ", ")))", fpos)
                }
                if given.contains(fname) { throw err("field '\(fname)' is given twice", fpos) }
                given.insert(fname)
                try expectType(val, f.1, "field '\(fname)' of \(name)")
            }
            let missing = st.fields.filter { !given.contains($0.0) }
            if !missing.isEmpty { throw err("\(name) needs \(missing.map { "\($0.0): \($0.1)" }.joined(separator: ", "))", e.pos) }
            return .structType(name)
        case .mcall(let recv, let name, let args):
            let isStmt = stmtCall === e; stmtCall = nil
            let t = try expr(recv)
            guard case .structType(let sn) = t, let st = structs[sn] else { throw err("only a struct has methods, but this is \(t)", e.pos) }
            guard let m = methods["\(sn).\(name)"] else {
                let isField = st.fields.contains { $0.0 == name }
                let have = st.methods.map { $0.name }.joined(separator: ", ")
                throw err("\(sn) has no method '\(name)'" + (isField ? " (it is a field; leave off the brackets)" : " (its methods are \(have.isEmpty ? "none" : have))"), e.pos)
            }
            if args.count != m.params.count { throw err("\(name)() takes \(m.params.count) argument(s) but got \(args.count)", e.pos) }
            for (a, p) in zip(args, m.params) { try expectType(a, p, "an argument of \(name)()") }
            e.method = "\(sn).\(name)"
            if m.ret != .unit { return m.ret }
            if !isStmt { throw err("\(name)() may change \(pathText(recv)), so use it as its own statement, like: \(pathText(recv)).\(name)(...)", e.pos) }
            try checkPath(recv, e.pos)
            e.writeBack = true
            return .unit
        case .field(let inner, let name):
            let t = try expr(inner)
            guard case .structType(let sn) = t, let st = structs[sn] else { throw err("only a struct has fields, but this is \(t)", e.pos) }
            guard let f = st.fields.first(where: { $0.0 == name }) else {
                throw err("\(sn) has no field '\(name)' (its fields are \(st.fields.map { $0.0 }.joined(separator: ", ")))", e.pos)
            }
            return f.1
        case .with(let inner, let updates):
            let t = try expr(inner)
            guard case .structType(let sn) = t, let st = structs[sn] else { throw err("'with' needs a struct on its left, but this is \(t)", e.pos) }
            var seen = Set<String>()
            for (fname, val, fpos) in updates {
                guard let f = st.fields.first(where: { $0.0 == fname }) else {
                    throw err("\(sn) has no field '\(fname)' (its fields are \(st.fields.map { $0.0 }.joined(separator: ", ")))", fpos)
                }
                if seen.contains(fname) { throw err("field '\(fname)' is changed twice", fpos) }
                seen.insert(fname)
                try expectType(val, f.1, "field '\(fname)' of \(sn)")
            }
            return t
        }
    }

    func binary(_ e: Expr, _ op: String, _ l: Expr, _ r: Expr) throws -> TType {
        if op == "&&" || op == "||" {
            try expectType(l, .bool, "'\(op)'"); try expectType(r, .bool, "'\(op)'"); return .bool
        }
        func exprCtx(_ x: Expr, _ hint: TType?) throws -> TType {
            if case .null = x.kind, let h = hint, h.isOptional { return h }
            if case .null = x.kind, let h = hint { return .optional(h) }
            return try expr(x, hint)
        }
        let lt = try expr(l)
        let rt = try exprCtx(r, lt.isOptional ? lt : (lt != .bool && lt != .int && lt != .float && lt != .text && lt != .color && lt != .align && lt != .font ? nil : nil))
        let lt2: TType
        let rt2: TType
        if case .null = l.kind, rt.isOptional { lt2 = rt; rt2 = rt } else { lt2 = lt; rt2 = rt }
        if op == "==" || op == "!=" {
            if lt2 != rt2 && !(typesCompatible(lt2, rt2) || typesCompatible(rt2, lt2)) {
                throw err("cannot compare \(lt2) with \(rt2)", e.pos)
            }
            return .bool
        }
        if op == "+" && lt2 == .text && rt2 == .text { return .text }
        if op == "+" && lt2.isList && lt2 == rt2 { return lt2 }
        e.opType = lt2
        let comparison = ["<", ">", "<=", ">="].contains(op)
        if (lt2 == .float || rt2 == .float) && lt2 != rt2 && (lt2 == .int || rt2 == .int) {
            throw err("'\(op)' cannot mix Int and Float (use toFloat(...) to turn an Int into a Float)", e.pos)
        }
        if lt2 == .float && rt2 == .float {
            if op == "%" { throw err("'%' only works on Int", e.pos) }
            return comparison ? .bool : .float
        }
        if lt2 != .int || rt2 != .int {
            let hint = op == "+" && (lt2 == .text || rt2 == .text) ? " (use toText(...) to join numbers into Text)" : ""
            throw err("'\(op)' cannot be used on \(lt2) and \(rt2)\(hint)", e.pos)
        }
        return comparison ? .bool : .int
    }

    func call(_ e: Expr, _ name: String, _ args: [Expr], _ expected: TType?) throws -> TType {
        if let (params, r) = fns[name] {
            if args.count != params.count { throw err("\(name)() takes \(params.count) argument(s) but got \(args.count)", e.pos) }
            for (a, p) in zip(args, params) { try expectType(a, p, "an argument of \(name)()") }
            return r
        }
        if BUILTINS[name] != nil { return try builtin(e, name, args, expected) }
        throw err("unknown function '\(name)'", e.pos)
    }

    func builtin(_ e: Expr, _ name: String, _ args: [Expr], _ expected: TType?) throws -> TType {
        let n = BUILTINS[name]!
        if args.count != n { throw err("\(name)() takes \(n) argument(s) but got \(args.count)", e.pos) }
        switch name {
        case "toText":
            let t = try expr(args[0])
            if t != .int && t != .float && t != .bool && t != .text { throw err("toText() works on Int, Float, Bool and Text, not \(t)", e.pos) }
            e.argType = t
            return .text
        case "len":
            let t = try expr(args[0])
            if t != .text && !t.isList { throw err("len() works on Text and List, not \(t)", e.pos) }
            return .int
        case "append":
            let lt = try expr(args[0], expected)
            guard let el = lt.element else { throw err("append() needs a List first, not \(lt)", args[0].pos) }
            try expectType(args[1], el, "the appended item"); return lt
        case "removeAt":
            let lt = try expr(args[0])
            if !lt.isList { throw err("removeAt() needs a List first, not \(lt)", args[0].pos) }
            try expectType(args[1], .int, "the index"); return lt
        case "setAt":
            let lt = try expr(args[0], expected)
            guard let el = lt.element else { throw err("setAt() needs a List first, not \(lt)", args[0].pos) }
            try expectType(args[1], .int, "the index"); try expectType(args[2], el, "the new value"); return lt
        case "slice":
            let lt = try expr(args[0], expected)
            if !lt.isList { throw err("slice() needs a List first, not \(lt)", args[0].pos) }
            try expectType(args[1], .int, "the start"); try expectType(args[2], .int, "the end"); return lt
        case "reverse":
            let lt = try expr(args[0], expected)
            if !lt.isList { throw err("reverse() needs a List, not \(lt)", args[0].pos) }
            return lt
        case "sort", "sortOrder":
            let lt = try expr(args[0])
            guard let el = lt.element, el == .int || el == .float || el == .text else {
                throw err("\(name)() needs a List of Int, Float or Text, not \(lt)", args[0].pos)
            }
            return name == "sort" ? lt : .list(.int)
        case "toFloat": try expectType(args[0], .int, "toFloat()"); return .float
        case "round", "floor", "ceil": try expectType(args[0], .float, "\(name)()"); return .int
        case "sqrt": try expectType(args[0], .float, "sqrt()"); return .float
        case "fixed": try expectType(args[0], .float, "fixed()"); try expectType(args[1], .int, "the number of decimals"); return .text
        case "toIntOr": try expectType(args[0], .text, "toIntOr()"); try expectType(args[1], .int, "the fallback"); return .int
        case "toFloatOr": try expectType(args[0], .text, "toFloatOr()"); try expectType(args[1], .float, "the fallback"); return .float
        case "has":
            let t = try expr(args[0])
            guard case .optional(_) = t else { throw err("has() needs an optional value (like the result of xs[i]), not \(t)", args[0].pos) }
            return .bool
        case "unwrap":
            let t = try expr(args[0])
            guard case .optional(let inner) = t else { throw err("unwrap() needs an optional value, not \(t)", args[0].pos) }
            return inner
        case "valueOr":
            let t = try expr(args[0])
            guard case .optional(let inner) = t else { throw err("valueOr() needs an optional value first, not \(t)", args[0].pos) }
            try expectType(args[1], inner, "the fallback"); return inner
        case "range": try expectType(args[0], .int, "range()"); return .list(.int)
        case "trim", "upper", "lower": try expectType(args[0], .text, "\(name)()"); return .text
        case "contains": try expectType(args[0], .text, "contains()"); try expectType(args[1], .text, "contains()"); return .bool
        case "join": try expectType(args[0], .list(.text), "join()"); try expectType(args[1], .text, "join()"); return .text
        case "rgb": for a in args { try expectType(a, .int, "rgb()") }; return .color
        default: throw err("unknown function '\(name)'", e.pos)
        }
    }

    func checkInput(_ t: Expr, _ placeholder: Expr?, _ what: String = "input", _ want: TType = .text) throws {
        if case .variable(let name) = t.kind {
            guard let ty = states[name] else { throw err("'\(name)' is not a state; declare it with: state \(name): \(want) = \(want == .text ? "\"\"" : "0")", t.pos) }
            if ty != want { throw err("\(what) can only edit \(want) state, but '\(name)' is \(ty)", t.pos) }
        } else {
            switch t.kind {
            case .field, .index: break
            default: throw err("\(what) edits a \(want) state, or a place inside one like names[i]", t.pos)
            }
            let ty = try expr(t)
            if ty != want { throw err("\(what) can only edit \(want), but this is \(ty)", t.pos) }
            try checkPath(t, t.pos)
        }
        if let ph = placeholder { try expectType(ph, .text, "a placeholder") }
    }
    func checkChoice(_ kind: String, _ target: Expr, _ options: Expr, _ placeholder: Expr?, _ mods: [Mod]) throws {
        try checkInput(target, placeholder, kind)
        try expectType(options, .list(.text), "the options of a \(kind)")
        try checkMods(mods, kind)
    }
    func checkbox(_ cond: Expr, _ label: Expr?, _ mods: [Mod], _ action: [Stmt]?, _ pos: Pos) throws {
        try expectType(cond, .bool, "a checkbox")
        if let l = label { try expectType(l, .text, "a checkbox label") }
        try checkMods(mods, "checkbox")
        if let a = action { ret = nil; try block(a); return }
        var isState = false
        if case .variable(let n) = cond.kind, states[n] != nil, !scopes.contains(where: { $0[n] != nil }) { isState = true }
        if !isState { throw err("a checkbox with no -> must name a Bool state, like: checkbox done \"Finished\"  (or add an action: checkbox flags[i] \"x\" -> ...)", cond.pos) }
    }
    // ---- view
    func view(_ items: [ViewItem]) throws {
        for it in items {
            switch it.kind {
            case .textual(let kind, let e, let mods):
                try expectType(e, .text, "'\(kind)'"); try checkMods(mods, kind)
            case .para(let mods, let spans):
                try checkMods(mods, "para")
                for sp in spans { try expectType(sp.e, .text, "'span'"); try checkMods(sp.mods, "span") }
            case .button(let label, let mods, let action):
                try expectType(label, .text, "a button label"); try checkMods(mods, "button")
                ret = nil; try block(action)
            case .checkbox(let cond, let label, let mods, let action):
                try checkbox(cond, label, mods, action, it.pos)
            case .input(let target, let ph, let mods):
                try checkInput(target, ph); try checkMods(mods, "input")
            case .every(let ms, let when, let action):
                try expectType(ms, .int, "the time between ticks (in milliseconds)")
                if let w = when { try expectType(w, .bool, "'every ... when'") }
                ret = nil; try block(action)
            case .area(let target, let ph, let mods):
                try checkInput(target, ph, "textarea"); try checkMods(mods, "textarea")
            case .slider(let target, let lo, let hi, let mods):
                try checkInput(target, nil, "slider", .int)
                try expectType(lo, .int, "the slider start"); try expectType(hi, .int, "the slider end")
                try checkMods(mods, "slider")
            case .box(let kind, let mods, let body):
                try checkMods(mods, kind); nest += 1; defer { nest -= 1 }; try view(body)
            case .choice(let kind, let target, let options, let ph, let mods):
                try checkChoice(kind, target, options, ph, mods)
            case .grid(let cols, let mods, let body):
                try expectType(cols, .int, "the number of grid columns"); try checkMods(mods, "grid")
                nest += 1; defer { nest -= 1 }
                try view(body)
            case .modal(let cond, let mods, let action, let body):
                if nest > 0 { throw err("a modal must be directly in the view, not inside a row, a column or another modal", it.pos) }
                try expectType(cond, .bool, "a modal")
                try checkMods(mods, "modal")
                if let a = action { ret = nil; try block(a) }
                else {
                    var isState = false
                    if case .variable(let n) = cond.kind, states[n] != nil, !scopes.contains(where: { $0[n] != nil }) { isState = true }
                    if !isState { throw err("a modal with no -> must name a Bool state, like: modal open { ... }  (or add an action: modal step > 0 -> step = 0 { ... })", cond.pos) }
                }
                nest += 1; defer { nest -= 1 }
                try view(body)
            case .table(let mods, _, let body):
                try checkMods(mods, "table")
                let save = tbl; tbl = (nil, false)
                defer { tbl = save }
                try view(body)
            case .cells(let isHeader, let cells):
                var n = 0
                for c in cells {
                    if c.kind == "select" { try checkInput(c.cond!, c.e, "select"); try expectType(c.opts!, .list(.text), "the options of a select") }
                    else if c.kind == "input" { try checkInput(c.cond!, c.e) }
                    else if c.kind == "checkbox" { try checkbox(c.cond!, c.e, [], c.action, c.pos) }
                    else { try expectType(c.e, .text, c.kind == "text" ? "a table cell" : "a \(c.kind) label") }
                    if c.span < 1 { throw err("a cell must span at least 1 column", c.spanPos) }
                    if !c.mods.isEmpty { try checkMods(c.mods, c.kind == "text" ? "cellrow" : c.kind) }
                    if let t = c.target { try expectType(t, .text, "a link target") }
                    if let a = c.action { ret = nil; try block(a) }
                    n += c.span
                }
                if isHeader {
                    if tbl!.header || tbl!.cols != nil { throw err("a table can have one header, and it must come first", it.pos) }
                    tbl!.header = true
                }
                if let cols = tbl!.cols {
                    if cols != n { throw err("this row has \(n) cell(s) but the table has \(cols) column(s)", it.pos) }
                } else { tbl!.cols = n }
            case .vif(let cond, let then, let other):
                try expectType(cond, .bool, "an if condition")
                try scoped(then); try scoped(other)
            case .vfor(let v, let iter, let body):
                let ity = try expr(iter)
                guard let el = ity.element else { throw err("can only loop over a List, not \(ity)", iter.pos) }
                scopes.append([v: el, "\0" + v: .bool]); defer { scopes.removeLast() }
                try view(body)
            case .link(let label, let target, let action, let mods):
                try expectType(label, .text, "a link label")
                if let t = target { try expectType(t, .text, "a link target") }
                try checkMods(mods, "link")
                if let a = action { ret = nil; try block(a) }
            case .image(let e, let mods):
                try expectType(e, .text, "'image'")
                try checkMods(mods, "image")
                if let assets = assets, case .str(let v) = e.kind {
                    let web = v.hasPrefix("http:") || v.hasPrefix("https:") || v.hasPrefix("data:")
                    if !web && !assets.names.contains(v) {
                        let list = assets.names.isEmpty ? "none" : assets.names.joined(separator: ", ")
                        throw err("no image called \"\(v)\" (\(assets.hint)). Available: \(list)", e.pos)
                    }
                }
            case .divider: break
            }
        }
    }
    func scoped(_ items: [ViewItem]) throws {
        scopes.append([:]); defer { scopes.removeLast() }
        try view(items)
    }
}
