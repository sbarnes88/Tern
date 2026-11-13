// Parser: tokens to a syntax tree.

let FLAGS: Set<String> = ["bold", "italic", "underline", "strike", "disabled"]
let VALUE_MODS: Set<String> = ["size", "color", "background", "align", "padding", "font", "radius", "border", "width", "height", "alt", "gap", "margin", "grow", "maxwidth", "minwidth"]
private let BIN_LEVELS: [[String]] = [["||"], ["&&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]
private let MAX_NESTING = 200

private func syntax(_ msg: String, _ pos: Pos) -> TernError { TernError(msg, pos, "syntax error") }

struct Parser {
    let t: [Token]
    var i = 0
    var depth = 0
    var structNames: Set<String> = []
    var ownFns: Set<String> = []
    let lib: Bool
    let prefix: String
    let libs: [String: LibInfo]

    /// lib: parsing a .ternlib file; prefix: "shop." added to the names it declares; libs: libraries a page uses.
    init(_ toks: [Token], lib: Bool = false, prefix: String = "", libs: [String: LibInfo] = [:]) {
        t = toks; self.lib = lib; self.prefix = prefix; self.libs = libs
        for k in 0..<max(0, toks.count - 1) where toks[k].kind == .kw && toks[k + 1].kind == .id {
            if toks[k].val == "struct" { structNames.insert(toks[k + 1].val) }
            if toks[k].val == "fn" { ownFns.insert(toks[k + 1].val) }
        }
        for (m, info) in libs { for st in info.structs { structNames.insert("\(m).\(st)") } }
    }
    func notModule(_ tok: Token) throws -> Token {
        if libs[tok.val] != nil { throw syntax("'\(tok.val)' is the name of a library you use; pick another name", tok.pos) }
        return tok
    }

    func peek(_ k: Int = 0) -> Token { t[min(i + k, t.count - 1)] }
    mutating func next() -> Token { let tok = peek(); i += 1; return tok }
    func isTok(_ val: String, _ k: Int = 0) -> Bool {
        let tok = peek(k)
        return (tok.kind == .kw || tok.kind == .op) && tok.val == val
    }
    mutating func accept(_ val: String) -> Bool { if isTok(val) { i += 1; return true }; return false }
    @discardableResult mutating func expect(_ val: String) throws -> Token {
        if !isTok(val) { let tok = peek(); throw syntax("expected '\(val)' but found '\(tok.val)'", tok.pos) }
        return next()
    }
    mutating func ident(_ what: String = "a name") throws -> Token {
        let tok = peek()
        if tok.kind != .id { throw syntax("expected \(what) but found '\(tok.val)'", tok.pos) }
        return next()
    }
    mutating func nextKind(_ kind: Token.Kind, _ what: String) throws -> Token {
        let tok = peek()
        if tok.kind != kind { throw syntax("expected \(what) but found '\(tok.val)'", tok.pos) }
        return next()
    }
    /// Guards against pages nested so deeply they would exhaust the stack.
    mutating func enter() throws {
        depth += 1
        if depth > MAX_NESTING { throw syntax("this is nested too deeply (more than \(MAX_NESTING) levels)", peek().pos) }
    }

    mutating func componentDecl() throws -> ComponentDecl {
        let pos = next().pos
        let nameTok = try ident("a component name")
        try expect("(")
        let pName = try ident("a parameter name").val
        try expect(":")
        let pType = try type()
        try expect(")")
        return ComponentDecl(name: prefix + nameTok.val, propName: pName, propType: pType, body: try viewBlock(), pos: pos)
    }

    mutating func componentImport() throws -> ComponentImport {
        let pos = peek().pos
        try expect("component")
        let name = try ident("a component name").val
        var file = name + ".tern"
        if peek().kind == .id && peek().val == "from" {
            _ = next()
            file = try nextKind(.str, "a component file name in quotes").val
        } else if peek().kind == .str {
            file = next().val
        }
        return ComponentImport(name: name, file: file, pos: pos)
    }

    mutating func program() throws -> Program {
        var title: String? = nil
        var imports: [ComponentImport] = [], structs: [StructDecl] = [], components: [ComponentDecl] = []
        var states: [StateDecl] = [], fns: [FnDecl] = [], styles: [StyleDecl] = [], views: [ViewDecl] = []
        if lib && isTok("page") { throw syntax("a library has no page title; it holds only struct and fn", peek().pos) }
        if accept("page") { title = try nextKind(.str, "a page title in quotes").val }
        while peek().kind != .eof {
            let tok = peek()
            if lib && (isTok("state") || isTok("view") || isTok("style") || isTok("component") || isTok("import") || isTok("use")) {
                throw syntax(isTok("use") ? "a library cannot use other libraries yet" : "a library holds only struct and fn; keep '\(tok.val)' in the page", tok.pos)
            }
            if isTok("use") { _ = next(); _ = try nextKind(.str, "a library file name in quotes, like \"shop.ternlib\"") }
            else if isTok("import") { _ = next(); imports.append(try componentImport()) }
            else if isTok("struct") { structs.append(try structDecl()) }
            else if isTok("component") { components.append(try componentDecl()) }
            else if isTok("saved") && isTok("state", 1) { _ = next(); var d = try stateDecl(); d.saved = true; states.append(d) }
            else if isTok("state") { states.append(try stateDecl()) }
            else if isTok("fn") { fns.append(try fnDecl()) }
            else if isTok("style") { styles.append(try styleDecl()) }
            else if isTok("view") {
                _ = next()
                let name = peek().kind == .id ? next().val : "home"
                views.append(ViewDecl(name: name, body: try viewBlock(), pos: tok.pos))
            } else { throw syntax("expected 'use', 'import', 'struct', 'component', 'state', 'fn', 'style' or 'view' but found '\(tok.val)'", tok.pos) }
        }
        if views.isEmpty && !lib && components.isEmpty { throw syntax("page has no view", peek().pos) }
        return Program(title: title, imports: imports, structs: structs, components: components, states: states, fns: fns, styles: styles, views: views)
    }

    mutating func type() throws -> TType {
        let tok = try ident("a type")
        var base: TType
        if let b = BASE_TYPES[tok.val] { base = b }
        else if let info = libs[tok.val], isTok(".") {
            _ = next(); let m = try ident("a struct name")
            if !info.structs.contains(m.val) { throw syntax("library \(tok.val) has no struct '\(m.val)'", m.pos) }
            base = .structType("\(tok.val).\(m.val)")
        } else if structNames.contains(tok.val) { base = .structType(prefix + tok.val) }
        else if tok.val == "List" {
            try expect("<"); let inner = try type(); try expect(">")
            base = .list(inner)
        } else {
            throw syntax("unknown type '\(tok.val)' (try Int, Text, Bool, Color, Align, List<...> or a struct you declared)", tok.pos)
        }
        while accept("?") { base = .optional(base) }
        return base
    }
    mutating func structDecl() throws -> StructDecl {
        let pos = next().pos
        let nameTok = try ident("a struct name")
        try expect("{")
        var fields: [StructField] = []
        var methods: [FnDecl] = []
        while !isTok("}") {
            let ft = peek()
            if isTok("fn") { methods.append(try fnDecl(method: true)); continue }
            if ft.kind == .kw { throw syntax("'\(ft.val)' is a reserved word and cannot be a field name; try another, like \(ft.val)Value", ft.pos) }
            if ft.kind == .eof { throw syntax("missing '}'", ft.pos) }
            let f = try ident("a field name"); try expect(":")
            let ty = try type()
            let def: Expr? = accept("=") ? try expr() : nil
            fields.append(StructField(name: f.val, type: ty, defaultExpr: def, pos: f.pos))
            _ = accept(",")
        }
        try expect("}")
        return StructDecl(name: prefix + nameTok.val, namePos: nameTok.pos, fields: fields, methods: methods, pos: pos)
    }
    mutating func stateDecl() throws -> StateDecl {
        let pos = next().pos
        let name = try notModule(try ident("a state name")).val
        try expect(":"); let ty = try type(); try expect("=")
        return StateDecl(name: name, type: ty, initial: try expr(), pos: pos)
    }
    mutating func styleDecl() throws -> StyleDecl {
        let pos = next().pos
        let name = try ident("a style name").val
        try expect("{")
        let ms = try mods()
        try expect("}")
        return StyleDecl(name: name, mods: ms, pos: pos)
    }
    mutating func fnDecl(method: Bool = false) throws -> FnDecl {
        let pos = next().pos
        let nameTok = try notModule(try ident(method ? "a method name" : "a function name"))
        if !method && lib && BUILTINS[nameTok.val] != nil { throw syntax("'\(nameTok.val)' is a built-in name; pick another name for this function", nameTok.pos) }
        let name = method ? nameTok.val : prefix + nameTok.val
        try expect("(")
        var params: [(String, TType, Pos)] = []
        while !isTok(")") {
            let p = try notModule(try ident("a parameter name")); try expect(":")
            params.append((p.val, try type(), p.pos))
            if !accept(",") { break }
        }
        try expect(")")
        let ret: TType = accept(":") ? try type() : .unit
        return FnDecl(name: name, params: params, ret: ret, body: try block(), pos: pos)
    }

    // ---- modifiers: size 20 bold color red style note ...
    mutating func mods() throws -> [Mod] {
        var out: [Mod] = []
        while true {
            let tok = peek()
            if tok.kind != .kw { break }
            if FLAGS.contains(tok.val) {
                _ = next()
                let when: Expr? = accept("when") ? try expr() : nil
                out.append(Mod(name: tok.val, value: nil, when: when, styleNames: [], pos: tok.pos))
            } else if VALUE_MODS.contains(tok.val) {
                _ = next()
                out.append(Mod(name: tok.val, value: try expr(), when: nil, styleNames: [], pos: tok.pos))
            } else if tok.val == "style" {
                _ = next()
                var names = [try ident("a style name")]
                while peek().kind == .id { names.append(next()) }
                out.append(Mod(name: "style", value: nil, when: nil, styleNames: names.map { ($0.val, $0.pos) }, pos: tok.pos))
            } else { break }
        }
        return out
    }

    // ---- statements
    mutating func block() throws -> [Stmt] {
        try enter(); defer { depth -= 1 }
        try expect("{")
        var out: [Stmt] = []
        while !isTok("}") {
            if peek().kind == .eof { throw syntax("missing '}'", peek().pos) }
            out.append(try stmt())
        }
        try expect("}")
        return out
    }
    mutating func stmt() throws -> Stmt {
        let tok = peek()
        if accept("let") {
            let name = try notModule(try ident("a variable name")).val
            let ty: TType? = accept(":") ? try type() : nil
            try expect("=")
            return Stmt(kind: .letVar(name, ty, try expr()), pos: tok.pos)
        }
        if accept("if") {
            let cond = try expr(), then = try block()
            var other: [Stmt] = []
            if accept("else") { other = isTok("if") ? [try stmt()] : try block() }
            return Stmt(kind: .ifElse(cond, then, other), pos: tok.pos)
        }
        if accept("for") || accept("foreach") {
            let v = try notModule(try ident("a loop variable")).val; try expect("in")
            let iter = try expr()
            return Stmt(kind: .forIn(v, iter, try block()), pos: tok.pos)
        }
        if accept("goto") { return Stmt(kind: .goto(try ident("the name of a page").val), pos: tok.pos) }
        if accept("back") { return Stmt(kind: .back, pos: tok.pos) }
        if accept("return") {
            if isTok("}") { return Stmt(kind: .ret(nil), pos: tok.pos) }
            return Stmt(kind: .ret(try expr()), pos: tok.pos)
        }
        if tok.kind == .id && isTok("=", 1) {
            _ = next(); _ = next()
            return Stmt(kind: .assign(tok.val, try expr()), pos: tok.pos)
        }
        let e = try expr()
        if isTok("=") {
            let eq = next()
            if case .index = e.kind { throw syntax("a list is changed with setAt, like: xs = setAt(xs, i, value)", eq.pos) }
            guard case .field = e.kind else { throw syntax("you can change a variable or a field, like: x = 1 or item.qty = 2", eq.pos) }
            return Stmt(kind: .setPath(e, try expr()), pos: tok.pos)
        }
        return Stmt(kind: .expr(e), pos: tok.pos)
    }

    // ---- expressions
    mutating func expr() throws -> Expr {
        try enter(); defer { depth -= 1 }
        return try binary(0)
    }
    mutating func binary(_ lvl: Int) throws -> Expr {
        if lvl == BIN_LEVELS.count { return try unary() }
        var left = try binary(lvl + 1)
        while peek().kind == .op && BIN_LEVELS[lvl].contains(peek().val) {
            let op = next()
            left = Expr(.binary(op.val, left, try binary(lvl + 1)), op.pos)
        }
        return left
    }
    mutating func unary() throws -> Expr {
        let tok = peek()
        if tok.kind == .op && (tok.val == "!" || tok.val == "-") {
            _ = next()
            try enter(); defer { depth -= 1 }
            return Expr(.unary(tok.val, try unary()), tok.pos)
        }
        return try postfix()
    }
    mutating func postfix() throws -> Expr {
        var e = try primary()
        while true {
            if case .variable(let modName) = e.kind, let info = libs[modName], isTok("."), peek(1).kind == .id {
                _ = next()
                let m = next()
                if !info.fns.contains(m.val) && !info.structs.contains(m.val) {
                    let have = (info.fns.sorted() + info.structs.sorted()).joined(separator: ", ")
                    throw syntax("library \(modName) has no '\(m.val)' (it has: \(have.isEmpty ? "nothing" : have))", m.pos)
                }
                e = Expr(.variable("\(modName).\(m.val)"), e.pos)
            } else if isTok("("), case .variable(let name) = e.kind, structNames.contains(name) {
                _ = next()
                var fields: [(String, Expr, Pos)] = []
                while !isTok(")") {
                    let f = peek()
                    if !(f.kind == .id && isTok(":", 1)) {
                        throw syntax("\(name)(...) needs named fields, like \(name)(field: value, ...)", f.pos)
                    }
                    _ = next(); _ = next()
                    fields.append((f.val, try expr(), f.pos))
                    if !accept(",") { break }
                }
                try expect(")")
                e = Expr(.construct(lib ? prefix + name : name, fields), e.pos)
            } else if isTok("("), case .variable(let name) = e.kind {
                _ = next()
                var args: [Expr] = []
                while !isTok(")") { args.append(try expr()); if !accept(",") { break } }
                try expect(")")
                e = Expr(.call(lib && ownFns.contains(name) ? prefix + name : name, args), e.pos)
            } else if isTok("[") {
                let pos = next().pos
                let idx = try expr(); try expect("]")
                e = Expr(.index(e, idx), pos)
            } else if isTok(".") {
                let pos = next().pos
                let nm = try ident("a field or method name").val
                if isTok("(") {
                    _ = next()
                    var args: [Expr] = []
                    while !isTok(")") { args.append(try expr()); if !accept(",") { break } }
                    try expect(")")
                    e = Expr(.mcall(e, nm, args), pos)
                } else {
                    e = Expr(.field(e, nm), pos)
                }
            } else if isTok("with") {
                let pos = next().pos
                var updates: [(String, Expr, Pos)] = []
                while true {
                    let f = try ident("a field name"); try expect(":")
                    updates.append((f.val, try expr(), f.pos))
                    if isTok(",") && peek(1).kind == .id && isTok(":", 2) { _ = next() } else { break }
                }
                e = Expr(.with(e, updates), pos)
            } else { return e }
        }
    }
    mutating func primary() throws -> Expr {
        let tok = next()
        switch tok.kind {
        case .int: return Expr(.int(tok.int), tok.pos)
        case .str: return Expr(.str(tok.val), tok.pos)
        case .hex: return Expr(.color(tok.val), tok.pos)
        case .float: return Expr(.float(tok.float), tok.pos)
        case .id: return Expr(.variable(tok.val), tok.pos)
        case .kw where tok.val == "self": return Expr(.variable("self"), tok.pos)
        case .kw where tok.val == "true" || tok.val == "false": return Expr(.bool(tok.val == "true"), tok.pos)
        case .kw where tok.val == "null": return Expr(.null, tok.pos)
        case .op where tok.val == "[":
            var items: [Expr] = []
            while !isTok("]") { items.append(try expr()); if !accept(",") { break } }
            try expect("]")
            return Expr(.list(items), tok.pos)
        case .op where tok.val == "(":
            let e = try expr(); try expect(")")
            return e
        default:
            throw syntax("expected an expression but found '\(tok.val)'", tok.pos)
        }
    }

    // ---- view
    mutating func viewBlock() throws -> [ViewItem] {
        try enter(); defer { depth -= 1 }
        try expect("{")
        var out: [ViewItem] = []
        while !isTok("}") {
            if peek().kind == .eof { throw syntax("missing '}'", peek().pos) }
            out.append(try viewItem())
        }
        try expect("}")
        return out
    }
    mutating func componentArgs() throws -> [(String, Expr, Pos)] {
        var args: [(String, Expr, Pos)] = []
        while !isTok(")") {
            let f = peek()
            if !(f.kind == .id && isTok(":", 1)) {
                throw syntax("a component needs named properties, like Card(title: \"Hi\")", f.pos)
            }
            _ = next(); _ = next()
            args.append((f.val, try expr(), f.pos))
            if !accept(",") { break }
        }
        try expect(")")
        return args
    }

    mutating func viewItem() throws -> ViewItem {
        // component invocation: Name(prop: value, ...)
        if peek().kind == .id && isTok("(", 1) {
            let tok = next()
            _ = next() // (
            return ViewItem(kind: .component(tok.val, try componentArgs()), pos: tok.pos)
        }
        let tok = next()
        let k = tok.kind == .kw ? tok.val : ""
        switch k {
        case "heading", "text", "bullet":
            let e = try expr()
            return ViewItem(kind: .textual(k, e, try mods()), pos: tok.pos)
        case "button":
            let label = try expr(), ms = try mods()
            try expect("->")
            let action = isTok("{") ? try block() : [try stmt()]
            return ViewItem(kind: .button(label, ms, action), pos: tok.pos)
        case "grid":   // grid <columns> [style words] { ... }
            let cols = try expr(), ms = try mods()
            return ViewItem(kind: .grid(cols, ms, try viewBlock()), pos: tok.pos)
        case "modal":   // modal <Bool> [style words] [-> action] { ... }
            let e = try expr(), ms = try mods()
            let action: [Stmt]? = accept("->") ? (isTok("{") ? try block() : [try stmt()]) : nil
            return ViewItem(kind: .modal(e, ms, action, try viewBlock()), pos: tok.pos)
        case "checkbox":
            let p = try checkboxParts()
            return ViewItem(kind: .checkbox(p.0, p.1, p.2, p.3), pos: tok.pos)
        case "input":
            let target = try expr()   // a Text state, or a place inside one: names[i]  people[i].name
            switch target.kind {
            case .variable, .field, .index: break
            default: throw syntax("input edits a Text state, like: input name   or a place inside one, like: input names[i]", target.pos)
            }
            let ph: Expr? = accept("placeholder") ? try expr() : nil
            return ViewItem(kind: .input(target, ph, try mods()), pos: tok.pos)
        case "every":   // every <milliseconds> [when <Bool>] -> action
            let ms = try expr(), when: Expr? = accept("when") ? try expr() : nil
            try expect("->")
            return ViewItem(kind: .every(ms, when, isTok("{") ? try block() : [try stmt()]), pos: tok.pos)
        case "textarea":   // textarea <Text place> [placeholder "x"] [style words]
            let target = try expr()
            switch target.kind {
            case .variable, .field, .index: break
            default: throw syntax("textarea edits a Text state, like: textarea notes   or a place inside one, like: textarea items[i]", target.pos)
            }
            let ph: Expr? = accept("placeholder") ? try expr() : nil
            return ViewItem(kind: .area(target, ph, try mods()), pos: tok.pos)
        case "slider":   // slider <Int place> in <low> to <high> [style words]
            let target = try expr()
            switch target.kind {
            case .variable, .field, .index: break
            default: throw syntax("slider edits an Int state, like: slider volume in 0 to 100   or a place inside one, like: slider levels[i] in 0 to 10", target.pos)
            }
            try expect("in"); let lo = try expr(); try expect("to"); let hi = try expr()
            return ViewItem(kind: .slider(target, lo, hi, try mods()), pos: tok.pos)
        case "select", "radio":   // select <Text place> in <List<Text>> [placeholder "x"] [style words]
            let target = try expr()
            switch target.kind {
            case .variable, .field, .index: break
            default: throw syntax("\(k) edits a Text state, like: \(k) choice in options   or a place inside one, like: \(k) items[i] in options", target.pos)
            }
            try expect("in")
            let options = try expr()
            let ph: Expr? = k == "select" && accept("placeholder") ? try expr() : nil
            return ViewItem(kind: .choice(k, target, options, ph, try mods()), pos: tok.pos)
        case "row", "column":
            let ms = try mods()
            return ViewItem(kind: .box(k, ms, try viewBlock()), pos: tok.pos)
        case "para":
            let ms = try mods()
            try expect("{")
            var spans: [Span] = []
            while !isTok("}") {
                let s = peek()
                if !accept("span") { throw syntax("inside para, write: span \"text\"  (found '\(s.val)')", s.pos) }
                let e = try expr()
                spans.append(Span(e: e, mods: try mods(), pos: s.pos))
            }
            try expect("}")
            return ViewItem(kind: .para(ms, spans), pos: tok.pos)
        case "table":
            var ms: [Mod] = [], resizable = false
            while true {   // 'resizable' and the style words may come in any order
                let m = try mods(); ms += m
                if accept("resizable") { resizable = true; continue }
                if m.isEmpty { break }
            }
            return ViewItem(kind: .table(ms, resizable, try tableBlock()), pos: tok.pos)
        case "if":
            let cond = try expr(), then = try viewBlock()
            var other: [ViewItem] = []
            if accept("else") { other = isTok("if") ? [try viewItem()] : try viewBlock() }
            return ViewItem(kind: .vif(cond, then, other), pos: tok.pos)
        case "for", "foreach":
            let v = try notModule(try ident("a loop variable")).val; try expect("in")
            let iter = try expr()
            return ViewItem(kind: .vfor(v, iter, try viewBlock()), pos: tok.pos)
        case "link":
            let label = try expr()
            let ms = try mods()
            if accept("->") {
                let action = isTok("{") ? try block() : [try stmt()]
                return ViewItem(kind: .link(label, nil, action, ms), pos: tok.pos)
            }
            try expect("to")
            let target = try expr()
            return ViewItem(kind: .link(label, target, nil, ms + (try mods())), pos: tok.pos)
        case "image":
            let e = try expr()
            return ViewItem(kind: .image(e, try mods()), pos: tok.pos)
        case "divider":
            return ViewItem(kind: .divider, pos: tok.pos)
        default:
            throw syntax("expected a view element (text, heading, button, ...) but found '\(tok.val)'", tok.pos)
        }
    }
    mutating func tableBlock() throws -> [ViewItem] {
        try enter(); defer { depth -= 1 }
        try expect("{")
        var out: [ViewItem] = []
        while !isTok("}") {
            if peek().kind == .eof { throw syntax("missing '}'", peek().pos) }
            out.append(try tableItem())
        }
        try expect("}")
        return out
    }
    /// checkbox <Bool> ["label"] [style words] [-> action]
    mutating func checkboxParts() throws -> (Expr, Expr?, [Mod], [Stmt]?) {
        let e = try expr(), nx = peek()
        let label: Expr? = (nx.kind == .str || nx.kind == .id || isTok("(")) ? try expr() : nil
        let ms = try mods()
        let action: [Stmt]? = accept("->") ? (isTok("{") ? try block() : [try stmt()]) : nil
        return (e, label, ms, action)
    }
    /// One cell: a Text value, or a button or link, with style words and `span N` in either order.
    mutating func cell() throws -> Cell {
        let tok = peek()
        var c: Cell
        if accept("button") {
            let e = try expr(), ms = try mods()
            try expect("->")
            c = Cell(kind: "button", e: e, mods: ms, action: isTok("{") ? try block() : [try stmt()], target: nil, spanPos: tok.pos, pos: tok.pos)
        } else if accept("select") {
            let place = try expr(); try expect("in")
            let opts = try expr()
            let ph: Expr = accept("placeholder") ? try expr() : Expr(.str(""), tok.pos)
            c = Cell(kind: "select", e: ph, cond: place, opts: opts, mods: [], action: nil, target: nil, spanPos: tok.pos, pos: tok.pos)
        } else if accept("input") {
            let place = try expr()
            let ph: Expr = accept("placeholder") ? try expr() : Expr(.str(""), tok.pos)
            c = Cell(kind: "input", e: ph, cond: place, mods: [], action: nil, target: nil, spanPos: tok.pos, pos: tok.pos)
        } else if accept("checkbox") {
            let p = try checkboxParts()
            c = Cell(kind: "checkbox", e: p.1 ?? Expr(.str(""), tok.pos), cond: p.0, mods: p.2, action: p.3, target: nil, spanPos: tok.pos, pos: tok.pos)
        } else if accept("link") {
            let e = try expr()
            var ms = try mods()
            if accept("->") {
                c = Cell(kind: "link", e: e, mods: ms, action: isTok("{") ? try block() : [try stmt()], target: nil, spanPos: tok.pos, pos: tok.pos)
            } else {
                try expect("to")
                let target = try expr()
                ms += try mods()
                c = Cell(kind: "link", e: e, mods: ms, action: nil, target: target, spanPos: tok.pos, pos: tok.pos)
            }
        } else {
            c = Cell(kind: "text", e: try expr(), mods: [], action: nil, target: nil, spanPos: tok.pos, pos: tok.pos)
        }
        while true {
            if c.kind == "text" { let m = try mods(); if !m.isEmpty { c.mods += m; continue } }
            if !accept("span") { break }
            let n = next()
            if n.kind != .int { throw syntax("write the number of columns after 'span', like: span 2", n.pos) }
            c.span = n.int; c.spanPos = n.pos
        }
        return c
    }
    mutating func tableItem() throws -> ViewItem {
        let tok = next()
        let k = tok.kind == .kw ? tok.val : ""
        switch k {
        case "header", "cells":
            var cells = [try cell()]
            while accept(",") { cells.append(try cell()) }
            return ViewItem(kind: .cells(k == "header", cells), pos: tok.pos)
        case "if":
            let cond = try expr(), then = try tableBlock()
            var other: [ViewItem] = []
            if accept("else") { other = isTok("if") ? [try tableItem()] : try tableBlock() }
            return ViewItem(kind: .vif(cond, then, other), pos: tok.pos)
        case "for", "foreach":
            let v = try notModule(try ident("a loop variable")).val; try expect("in")
            let iter = try expr()
            return ViewItem(kind: .vfor(v, iter, try tableBlock()), pos: tok.pos)
        default:
            throw syntax("inside a table you can use 'header', 'cells', 'if', 'for' and 'foreach' (found '\(tok.val)')", tok.pos)
        }
    }
}

func parse(_ src: String) throws -> Program {
    var p = Parser(try tokenize(src))
    return try p.program()
}

/// What a page can reach in a library: its function and struct names (without the "shop." prefix).
struct LibInfo { let fns: Set<String>; let structs: Set<String> }

func buildLibraries(_ src: String, libraries: [String: String], hint: String) throws -> ([String: LibInfo], [Program]) {
    let toks = try tokenize(src)
    var infos: [String: LibInfo] = [:]
    var libProgs: [Program] = []
    for k in 0..<max(0, toks.count - 1) where toks[k].kind == .kw && toks[k].val == "use" && toks[k + 1].kind == .str {
        let file = toks[k + 1].val, pos = toks[k].pos
        guard file.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\.ternlib$", options: .regularExpression) != nil else {
            throw TernError("a library is named like use \"shop.ternlib\" (a file next to this page, with no folders)", pos, "syntax error")
        }
        let name = String(file.dropLast(".ternlib".count))
        if infos[name] != nil { throw TernError("library \(file) is used twice", pos, "syntax error") }
        if KEYWORDS.contains(name) || BUILTINS[name] != nil || BASE_TYPES[name] != nil {
            throw TernError("'\(name)' cannot be a library name; rename the file", pos, "syntax error")
        }
        guard let lsrc = libraries[name] else { throw TernError("library \(file) was not found (\(hint))", pos, "library error") }
        do {
            var lp = Parser(try tokenize(lsrc), lib: true, prefix: name + ".")
            let prog = try lp.program()
            try Checker(prog, assets: nil).run()
            let cut = name.count + 1
            infos[name] = LibInfo(fns: Set(prog.fns.map { String($0.name.dropFirst(cut)) }),
                                  structs: Set(prog.structs.map { String($0.name.dropFirst(cut)) }))
            libProgs.append(prog)
        } catch var e as TernError { e.file = file; throw e }
    }
    return (infos, libProgs)
}

/// Reads a page and the libraries it names with `use "shop.ternlib"`. Each library is parsed and checked on its
/// own first (so its errors name its file); then its structs and functions join the page under the prefix `shop.`.
/// Components imported with `import component` are resolved from componentSources (keyed by file name) when provided.
func buildProgram(_ src: String, libraries: [String: String] = [:], hint: String = "put it next to the page",
                  componentSources: [String: String] = [:], _seen: Set<String> = []) throws -> Program {
    let (infos, libProgs) = try buildLibraries(src, libraries: libraries, hint: hint)
    var p = Parser(try tokenize(src), libs: infos)
    let main = try p.program()
    var compStructs: [StructDecl] = [], compDecls: [ComponentDecl] = [], compFns: [FnDecl] = []
    for imp in main.imports {
        guard let csrc = componentSources[imp.file] ?? componentSources[imp.name + ".tern"] ?? componentSources[imp.name] else {
            throw TernError("component \(imp.file) was not found (\(hint))", imp.pos, "import error")
        }
        let key = imp.file
        if _seen.contains(key) { throw TernError("component \(imp.file) is imported in a cycle", imp.pos, "import error") }
        var seen = _seen; seen.insert(key)
        do {
            let cprog = try buildProgram(csrc, libraries: libraries, hint: hint, componentSources: componentSources, _seen: seen)
            let wanted = cprog.components.filter { $0.name == imp.name }
            if wanted.isEmpty { throw TernError("component \(imp.file) does not define '\(imp.name)'", imp.pos, "import error") }
            compStructs += cprog.structs
            compDecls += wanted
            compFns += cprog.fns
        } catch var e as TernError { if e.file == nil { e.file = imp.file }; throw e }
    }
    func dedup<T>(_ items: [T], _ key: (T) -> String) -> [T] {
        var seen = Set<String>(), out: [T] = []
        for it in items { let k = key(it); if !seen.contains(k) { seen.insert(k); out.append(it) } }
        return out
    }
    return Program(title: main.title, imports: main.imports,
                   structs: dedup(libProgs.flatMap { $0.structs } + compStructs, { $0.name }) + main.structs,
                   components: dedup(compDecls, { $0.name }) + main.components,
                   states: main.states,
                   fns: dedup(libProgs.flatMap { $0.fns } + compFns, { $0.name }) + main.fns,
                   styles: main.styles, views: main.views)
}
