// Syntax tree. Expressions are classes because the checker annotates them
// (opType on binary operators, argType on toText calls) and the runtime reads those.

public final class Expr {
    indirect enum Kind {
        case int(Int), float(Double), str(String), bool(Bool), color(String), null
        case variable(String)
        case list([Expr])
        case unary(String, Expr)
        case binary(String, Expr, Expr)
        case index(Expr, Expr)
        case call(String, [Expr])
        case construct(String, [(String, Expr, Pos)])
        case field(Expr, String)
        case with(Expr, [(String, Expr, Pos)])
        case mcall(Expr, String, [Expr])     // receiver.method(args)
        case action([Stmt])                   // action { ... } literal (closure)
    }
    let kind: Kind
    let pos: Pos
    var opType: TType? = nil    // set by the checker on binary operators
    var argType: TType? = nil   // set by the checker on toText(...)
    var method: String? = nil   // set by the checker on method calls: "Item.take"
    var writeBack = false       // set by the checker when a method call may change its receiver
    var actionField = false     // set by the checker on mcall when invoking an Action-typed field
    init(_ kind: Kind, _ pos: Pos) { self.kind = kind; self.pos = pos }
}

indirect enum StmtKind {
    case letVar(String, TType?, Expr)
    case assign(String, Expr)
    case ifElse(Expr, [Stmt], [Stmt])
    case forIn(String, Expr, [Stmt])
    case goto(String)
    case back
    case ret(Expr?)
    case expr(Expr)
    case setPath(Expr, Expr)    // item.qty = 3
}
struct Stmt { let kind: StmtKind; let pos: Pos }

/// A style modifier: `size 20`, `bold when on`, `style loud calm`.
struct Mod {
    let name: String
    let value: Expr?
    let when: Expr?
    let styleNames: [(String, Pos)]
    let pos: Pos
}

/// One table cell: Text, a button or a link ("text", "button", "link"), possibly spanning several columns.
struct Cell {
    let kind: String
    let e: Expr
    var cond: Expr? = nil                       // checkbox: the Bool shown; input/select: the Text place
    var opts: Expr? = nil                       // select: the list of options
    var mods: [Mod]
    let action: [Stmt]?
    let target: Expr?
    var span = 1
    var spanPos: Pos
    let pos: Pos
}
struct Span { let e: Expr; let mods: [Mod]; let pos: Pos }

indirect enum ViewKind {
    case textual(String, Expr, [Mod])          // heading, text, bullet
    case para([Mod], [Span])
    case button(Expr, [Mod], [Stmt])
    case input(Expr, Expr?, [Mod])               // a Text state, or a place inside one; placeholder; style words
    case every(Expr, Expr?, [Stmt])              // milliseconds, optional condition, action
    case area(Expr, Expr?, [Mod])                // textarea: a Text place, placeholder, style words
    case slider(Expr, Expr, Expr, [Mod])         // an Int place, low, high, style words
    case choice(String, Expr, Expr, Expr?, [Mod])  // "select" or "radio": Text place, options, placeholder, style words
    case grid(Expr, [Mod], [ViewItem])           // columns, style words, children
    case modal(Expr, [Mod], [Stmt]?, [ViewItem])   // shown while the Bool is true; close action
    case checkbox(Expr, Expr?, [Mod], [Stmt]?)   // checked value, label, style, action
    case box(String, [Mod], [ViewItem])        // row, column
    case table([Mod], Bool, [ViewItem])      // style words, resizable columns, lines
    case cells(Bool, [Cell])                   // header (true) or cells (false)
    case vif(Expr, [ViewItem], [ViewItem])
    case vfor(String, Expr, [ViewItem])
    case component(String, [(String, Expr, Pos)])  // render a component by name with named props
    case link(Expr, Expr?, [Stmt]?, [Mod])
    case image(Expr, [Mod])
    case divider
}
struct ViewItem { let kind: ViewKind; let pos: Pos }

struct StructField { let name: String; let type: TType; var defaultExpr: Expr?; let pos: Pos }
struct StructDecl { let name: String; let namePos: Pos; let fields: [StructField]; let methods: [FnDecl]; let pos: Pos }
struct ComponentDecl { let name: String; let propName: String; let propType: TType; let body: [ViewItem]; let pos: Pos }
struct StateDecl { let name: String; let type: TType; let initial: Expr; let pos: Pos; var saved = false }
struct FnDecl { let name: String; let params: [(String, TType, Pos)]; let ret: TType; let body: [Stmt]; let pos: Pos }
struct StyleDecl { let name: String; let mods: [Mod]; let pos: Pos }
struct ViewDecl { let name: String; let body: [ViewItem]; let pos: Pos }
struct ComponentImport { let name: String; let file: String; let pos: Pos }

struct Program {
    let title: String?
    let imports: [ComponentImport]
    let structs: [StructDecl]
    let components: [ComponentDecl]
    let states: [StateDecl]
    let fns: [FnDecl]
    let styles: [StyleDecl]
    let views: [ViewDecl]
}
