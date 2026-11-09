import Foundation
import TernCore

// Engine tests, ported from playground/tests.js so both implementations agree.
// Run: swift run TernTests

let examplesDir: URL = {
    if let d = ProcessInfo.processInfo.environment["TERN_EXAMPLES"] { return URL(fileURLWithPath: d) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Pages/examples").standardized
}()
func ex(_ id: String) -> String {
    try! String(contentsOf: examplesDir.appendingPathComponent(id + ".tern"), encoding: .utf8)
}
let exampleIds = (try! FileManager.default.contentsOfDirectory(atPath: examplesDir.path))
    .filter { $0.hasSuffix(".tern") }.map { String($0.dropLast(5)) }.sorted()

func exampleLibs() -> [String: String] {
    var out: [String: String] = [:]
    for f in (try? FileManager.default.contentsOfDirectory(atPath: examplesDir.path)) ?? [] where f.hasSuffix(".ternlib") {
        out[String(f.dropLast(8))] = try? String(contentsOf: examplesDir.appendingPathComponent(f), encoding: .utf8)
    }
    return out
}

struct Fail: Error, CustomStringConvertible { let description: String }
func check(_ cond: Bool, _ msg: @autoclosure () -> String = "assertion failed", line: Int = #line) throws {
    if !cond { throw Fail(description: "line \(line): \(msg())") }
}
func eq<T: Equatable>(_ a: T, _ b: T, line: Int = #line) throws {
    if a != b { throw Fail(description: "line \(line): \(a) != \(b)") }
}

var passed = 0, failed = 0
func test(_ name: String, _ body: @escaping () throws -> Void) {
    do { try onBigStack { try body() }; passed += 1 } catch { failed += 1; print("FAIL", name, "\n   ", error) }
}

func load(_ src: String, assets: [String]? = nil) throws -> Page {
    try Page(src, assets: assets.map { AssetInfo(names: $0) })
}
func page(_ body: String, _ decls: String = "") throws -> Page { try load("page \"t\"\n\(decls)\nview {\n\(body)\n}") }
func text(_ p: Page) throws -> String { renderText(try p.render()).joined(separator: "\n") }
func errOf(_ src: String, assets: [String]? = nil) throws -> TernError {
    do { _ = try load(src, assets: assets) } catch let e as TernError { return e }
    throw Fail(description: "expected an error")
}
func search(_ nodes: [RNode], _ pred: (RNode) -> Bool) -> RNode? {
    for n in nodes {
        if pred(n) { return n }
        if let r = search(n.children, pred) { return r }
    }
    return nil
}
func click(_ p: Page, _ label: String, _ times: Int = 1) throws {
    for _ in 0..<times {
        guard let b = search(try p.render(), { $0.kind == .button && $0.label == label }) else { throw Fail(description: "no button \(label)") }
        try b.click!()
    }
}
func type(_ p: Page, _ name: String, _ v: String) throws {
    guard let i = search(try p.render(), { $0.kind == .input && $0.name == name }) else { throw Fail(description: "no input \(name)") }
    try i.set!(v)
}
@discardableResult
func expectErr(_ src: String, _ phase: String, _ needle: String, line: Int = #line) throws -> TernError {
    let e = try errOf(src)
    try check(e.phase == phase, "phase of: \(e)", line: line)
    try check(e.msg.contains(needle), "message \"\(e.msg)\" should include \"\(needle)\"", line: line)
    return e
}
func throwsTern(_ body: () throws -> Void, _ pred: (TernError) -> Bool = { _ in true }, line: Int = #line) throws {
    do { try body() } catch let e as TernError {
        try check(pred(e), "unexpected error: \(e)", line: line); return
    }
    throw Fail(description: "line \(line): expected a TernError")
}
func st(_ d: [String: Any]) -> Style {
    var s = Style()
    for (k, v) in d {
        switch v {
        case let i as Int: s[k] = .int(i)
        case let b as Bool: s[k] = .bool(b)
        case let t as String: s[k] = .text(t)
        default: fatalError()
        }
    }
    return s
}
func txt1(_ body: String, _ decls: String = "") throws -> String { try page(body, decls).render()[0].text }

// ---- carried over from 0.1
test("text + int") { let e = try expectErr("state n: Int = 1\nview { text \"a\" + n }", "type error", "toText"); try eq(e.pos.line, 2) }
test("wrong state init") { try expectErr("state n: Int = \"x\"\nview { }", "type error", "needs Int") }
test("assign wrong type") { try expectErr("state n: Int = 1\nview { button \"b\" -> n = \"no\" }", "type error", "needs Int") }
test("unknown name") { try expectErr("view { text missing }", "type error", "unknown name") }
test("if needs bool") { try expectErr("view { if 1 { text \"x\" } }", "type error", "needs Bool") }
test("missing return") { try expectErr("fn f(): Int { }\nview { }", "type error", "must return Int") }
test("return wrong type") { try expectErr("fn f(): Int { return \"s\" }\nview { }", "type error", "needs Int") }
test("arg count/type") {
    try expectErr("fn f(a: Int) { }\nview { button \"b\" -> f() }", "type error", "takes 1")
    try expectErr("fn f(a: Int) { }\nview { button \"b\" -> f(\"x\") }", "type error", "needs Int")
}
test("empty list needs type") { try expectErr("view { for x in [] { text \"hi\" } }", "type error", "empty list") }
test("foreach is an alias for for") {
    try expectErr("view { foreach x in [] { text \"hi\" } }", "type error", "empty list")
    let p = try page("foreach i in range(3) { button toText(i) -> total = total + i }\ntext toText(total)", "state total: Int = 0")
    try click(p, "2")
    try eq(try p.render().last!.text, "2")
}
test("mixed list") { try expectErr("state xs: List<Int> = [1, \"a\"]\nview { }", "type error", "needs Int") }
test("input needs Text state") { try expectErr("state n: Int = 0\nview { input n }", "type error", "Text state") }
test("compare different types") { try expectErr("view { if 1 == \"a\" { text \"x\" } }", "type error", "cannot compare") }
test("syntax errors") {
    try expectErr("view { text \"unterminated }", "syntax error", "unterminated")
    try expectErr("view { text }", "syntax error", "expression")
    try expectErr("state x: Double = 1\nview { }", "syntax error", "unknown type")
    try expectErr("text \"a\"", "syntax error", "expected")
    try expectErr("page \"x\"", "syntax error", "no view")
}
test("expression statement") { try expectErr("view { button \"b\" -> 1 + 2 }", "type error", "does nothing") }

test("counter clicks") {
    let p = try load(ex("counter"))
    try check(try text(p).contains("Count: 0"))
    try click(p, "+", 2)
    try check(try text(p).contains("Count: 2") && text(p).contains("Even."))
    try click(p, "Step 5"); try click(p, "-")
    try check(try text(p).contains("Count: -3") && text(p).contains("Below zero."))
    try click(p, "Reset")
    try check(try text(p).contains("Count: 0"))
}
test("todo add/remove") {
    let p = try load(ex("todo"))
    try type(p, "draft", "  buy milk "); try click(p, "Add")
    let t = try text(p)
    try check(t.contains("3. buy milk") && t.contains("3 item(s)"), t)
    try eq(p.state["draft"]!, .text(""))
    try click(p, "Done", 3)
    try check(try text(p).contains("All done!"))
}
test("welcome greeting") {
    let p = try load(ex("welcome"))
    try check(try text(p).contains("Type your name"))
    try type(p, "name", "Sam")
    try check(try text(p).contains("Hello, Sam!"))
}
test("quiz run") {
    let p = try load(ex("quiz"))
    try type(p, "guess", "4"); try click(p, "Submit")
    try type(p, "guess", "paris"); try click(p, "Submit")
    try type(p, "guess", "no"); try click(p, "Submit")
    let t = try text(p)
    try check(t.contains("Score: 2 out of 3") && t.contains("The answer was yes."), t)
    try click(p, "Play again")
    try check(try text(p).contains("Question 1"))
}
test("functions, recursion, scopes") {
    let p = try page("text toText(fact(5))", "fn fact(n: Int): Int { if n <= 1 { return 1 } return n * fact(n - 1) }")
    try eq(try p.render()[0].text, "120")
}
test("closures capture loop var") {
    let p = try page("for i in range(3) { button toText(i) -> total = total + i * 10 }\ntext toText(total)", "state total: Int = 0")
    try click(p, "2"); try click(p, "1")
    try eq(try p.render().last!.text, "30")
}
test("runtime errors") {
    var p = try page("button \"go\" -> n = 1 / zero\ntext toText(n)", "state n: Int = 0\nstate zero: Int = 0")
    try throwsTern({ try click(p, "go") }, { $0.phase == "runtime error" && $0.msg.contains("division by zero") })
    p = try page("button \"go\" -> n = xs[5]", "state n: Int = 0\nstate xs: List<Int> = [1]")
    try throwsTern({ try click(p, "go") })
}
test("deep recursion reported, not crashed") {
    let p = try page("button \"go\" -> n = f(1)", "state n: Int = 0\nfn f(x: Int): Int { return f(x + 1) }")
    try throwsTern({ try click(p, "go") }, { $0.msg.contains("recursed") })
}
test("int division floors, modulo is non-negative") {
    try eq(try txt1("text toText(7 / 2) + \" \" + toText(7 % 2) + \" \" + toText(-3 + 1) + \" \" + toText(-7 / 2)"), "3 1 -2 -4")
}
test("builtins") {
    try eq(try txt1("text upper(\"a\\tb\") + join([\"x\", \"y\"], \",\") + toText(contains(\"hello\", \"ell\"))"), "A\tBx,ytrue")
    try eq(try txt1("text toText(setAt([1, 2, 3], 1, 9)[1])"), "9")
}
test("else-if chain") {
    try eq(try txt1("if n == 1 { text \"one\" } else if n == 2 { text \"two\" } else { text \"many\" }", "state n: Int = 2"), "two")
}

// ---- new in 0.2: styles
test("size/bold/italic/color on text") {
    let n = try page("text \"hi\" size 20 bold italic underline color red").render()[0]
    try eq(n.style, st(["size": 20, "bold": true, "italic": true, "underline": true, "color": "#d1242f"]))
}
test("hex colours incl. shorthand, rgb()") {
    let n = try page("text \"a\" color #fff background #0B57D0\ntext \"b\" color rgb(1, 300, -5)").render()
    try eq(n[0].style.text("color"), "#ffffff"); try eq(n[0].style.text("background"), "#0b57d0")
    try eq(n[1].style.text("color"), "#01ff00")
}
test("flags with when") {
    let r = try page("text \"a\" bold when on\ntext \"b\" bold when !on", "state on: Bool = true").render()
    try eq(r[0].style.flag("bold"), true); try eq(r[1].style.flag("bold"), false)
}
test("dynamic size, clamped") {
    let p = try page("text \"a\" size n", "state n: Int = 500")
    try eq(try p.render()[0].style.int("size"), 96)
    p.state["n"] = .int(1); try eq(try p.render()[0].style.int("size"), 6)
}
test("named styles + explicit override") {
    let r = try page("text \"a\" style loud size 10\ntext \"b\" size 10 style loud", "style loud { size 30 bold color red }").render()
    try eq(r[0].style.int("size"), 10); try eq(r[0].style.flag("bold"), true)
    try eq(r[1].style.int("size"), 30)
}
test("multiple styles in order") {
    let p = try page("text \"a\" style a b", "style a { color red bold }\nstyle b { color blue }")
    try eq(try p.render()[0].style, st(["color": "#0b57d0", "bold": true]))
}
test("style props that do not apply are ignored") {
    let r = try page("button \"go\" style s -> n = 1\nrow style s { text \"x\" }", "state n: Int = 0\nstyle s { align center size 30 background red padding 9 }").render()
    try eq(r[0].style, st(["size": 30, "background": "#d1242f", "padding": 9]))
    try eq(r[1].style, st(["align": "center", "background": "#d1242f", "padding": 9]))   // a row now takes align (its items)
}
test("style errors") {
    try expectErr("view { button \"b\" align center -> n = 1 }\nstate n: Int = 0", "type error", "a button cannot have 'align'")
    try expectErr("view { text \"x\" size \"big\" }", "type error", "needs Int")
    try expectErr("view { text \"x\" color 5 }", "type error", "needs Color")
    try expectErr("view { text \"x\" align red }", "type error", "needs Align")
    try expectErr("view { text \"x\" style nope }", "type error", "unknown style 'nope'")
    try expectErr("style a { bold }\nstyle b { style a }\nview { }", "type error", "cannot use another style")
    try expectErr("style a { bold }\nstyle a { italic }\nview { }", "type error", "defined twice")
    try expectErr("view { row size 3 { text \"x\" } }", "type error", "a row cannot have 'size'")
    try expectErr("style s { size \"x\" }\nview { }", "type error", "needs Int")
    try expectErr("view { text \"x\" bold when 1 }", "type error", "needs Bool")
}
test("Color and Align are real types") {
    let p = try page("text \"a\" color tint align side", "state tint: Color = purple\nstate side: Align = center")
    try eq(try p.render()[0].style, st(["color": "#8250df", "align": "center"]))
    try expectErr("state c: Color = \"red\"\nview { }", "type error", "needs Color")
    try expectErr("state c: Color = red\nview { button \"b\" -> red = blue }", "type error", "built in")
    try expectErr("view { text \"x\" + red }", "type error", "cannot be used")
    try eq(try page("text \"x\"\nif red == #d1242f { text \"same\" }").render()[1].text, "same")
}
test("hex literal must be 3 or 6 digits") { try expectErr("view { text \"x\" color #12 }", "syntax error", "unexpected character") }

// ---- new in 0.2: para, bullet, table
test("para spans inherit paragraph style") {
    let n = try page("para size 18 color blue { span \"a \" span \"b\" bold span \"c\" color red }").render()[0]
    try eq(n.spans.map { $0.text }, ["a ", "b", "c"])
    try eq(n.spans[0].style, st(["size": 18, "color": "#0b57d0"]))
    try eq(n.spans[1].style, st(["size": 18, "color": "#0b57d0", "bold": true]))
    try eq(n.spans[2].style.text("color"), "#d1242f")
}
test("para only accepts spans") { try expectErr("view { para { text \"x\" } }", "syntax error", "span") }
test("bullet") { try eq(try page("bullet \"a\" bold").render()[0].kind, .bullet) }
test("table renders header and rows") {
    let p = try load(ex("table"))
    let tb = try p.render().first { $0.kind == .table }!
    try eq(tb.header!, ["Item", "Price", "Qty", "Subtotal"])
    try eq(tb.rows[0], ["Tea", "$3", "2", "$6"])
    try check(try text(p).contains("Total: $25"))
    try click(p, "+ Tea")
    try eq(try p.render().first { $0.kind == .table }!.rows[0], ["Tea", "$3", "3", "$9"])
}
test("table without header, with if") {
    let tb = try page("table { cells \"a\", \"b\"\n if on { cells \"c\", \"d\" } else { cells \"e\", \"f\" } }", "state on: Bool = false").render()[0]
    try check(tb.header == nil); try eq(tb.rows, [["a", "b"], ["e", "f"]])
}
test("table column count and order errors") {
    try expectErr("view { table { header \"a\", \"b\"\n cells \"x\" } }", "type error", "1 cell(s) but the table has 2")
    try expectErr("view { table { cells \"x\"\n header \"x\" } }", "type error", "header")
    try expectErr("view { table { header 1, \"b\" } }", "type error", "needs Text")
    try expectErr("view { table { text \"x\" } }", "syntax error", "inside a table")
}
test("table height gives a scrolling box; other properties are errors") {
    let tb = try page("table height 120 { header \"a\", \"b\"\n cells \"x\", \"y\" }").render()[0]
    try eq(tb.style.int("height"), 120); try eq(tb.rows, [["x", "y"]])
    try check(try page("table { cells \"x\" }").render()[0].style.int("height") == nil)
    _ = try expectErr("view { table width 100 { cells \"x\" } }", "type error", "a table cannot have 'width'")
    _ = try expectErr("view { table height \"tall\" { cells \"x\" } }", "type error", "needs Int")
}
test("table cells can be buttons and links, and can span columns") {
    let p = try page("""
table padding 3 background #eef {
  header button "Sort" -> n = n + 1, "Name" bold, "Info"
  cells "Total" span 2, link "go" to "other.tern"
  for i in range(2) { cells "x", button "+" -> n = n + 10, toText(i) color red }
}
""", "state n: Int = 0")
    let tb = try p.render()[0]
    try eq(tb.style.int("padding"), 3)
    try eq(tb.header!, ["Sort", "Name", "Info"])
    try eq(tb.rows[0], ["Total", "", "go"])
    try eq(tb.body[0].cells[0].span, 2)
    try eq(tb.body[0].cells[1].kind, "link"); try eq(tb.body[0].cells[1].target, "other.tern")
    try eq(tb.body[1].cells[2].style.text("color"), "#d1242f"); try eq(tb.hrow!.cells[1].style.flag("bold"), true)
    try tb.hrow!.cells[0].click!(); try tb.body[2].cells[1].click!()
    try eq(p.state["n"]!, .int(11))
    _ = try expectErr("view { table { header \"a\", \"b\"\n cells \"x\" span 3 } }", "type error", "3 cell(s) but the table has 2")
    _ = try expectErr("view { table { cells \"x\" span 0 } }", "type error", "at least 1")
    _ = try expectErr("view { table { cells \"x\" span two } }", "syntax error", "after 'span'")
    _ = try expectErr("view { table { cells button 1 -> n = 1 } }", "type error", "needs Text")
    _ = try expectErr("view { table { cells \"x\" height 4 } }", "type error", "cannot have 'height'")
}
test("slice, sort, sortOrder and reverse") {
    let p = try page("text toText(len(a))", """
state a: List<Int> = [5, 3, 9, 3]
state t: List<Text> = ["pear", "Apple", "fig"]
state f: List<Float> = [2.5, 1.5]
state r: List<Int> = sortOrder(a)
state s: List<Int> = slice(a, 1, 3)
state big: List<Int> = slice(a, 2, 99)
state none: List<Int> = slice(a, 3, 1)
state neg: List<Int> = slice(a, -5, 2)
state so: List<Int> = sort(a)
state rv: List<Int> = reverse(a)
state tt: List<Text> = sort(t)
state ff: List<Float> = sort(f)
""")
    func ints(_ k: String) -> Value { p.state[k]! }
    func L(_ xs: [Int]) -> Value { .list(xs.map { .int($0) }) }
    try eq(ints("r"), L([1, 3, 0, 2]))
    try eq(ints("s"), L([3, 9])); try eq(ints("big"), L([9, 3])); try eq(ints("none"), L([])); try eq(ints("neg"), L([5, 3]))
    try eq(ints("so"), L([3, 3, 5, 9])); try eq(ints("rv"), L([3, 9, 3, 5])); try eq(ints("a"), L([5, 3, 9, 3]))
    try eq(p.state["tt"]!, .list([.text("Apple"), .text("fig"), .text("pear")]))
    try eq(p.state["ff"]!, .list([.float(1.5), .float(2.5)]))
    _ = try expectErr("state b: List<Bool> = [true]\nview { text toText(len(sort(b))) }", "type error", "List of Int, Float or Text")
    _ = try expectErr("view { text toText(len(slice([1], \"a\", 2))) }", "type error", "needs Int")
    _ = try expectErr("view { text toText(len(slice(3, 0, 1))) }", "type error", "needs a List")
}
test("checkbox edits a Bool state, or runs an action") {
    let p = try page("""
checkbox on "Notify me" bold
checkbox flags[1] "Second" -> flags = setAt(flags, 1, !flags[1])
table { cells checkbox flags[0] "cell" -> flags = setAt(flags, 0, !flags[0]), "x" }
""", "state on: Bool = false\nstate flags: List<Bool> = [false, false]")
    var r = try p.render()
    try eq(r[0].kind, .checkbox); try eq(r[0].text, "Notify me"); try eq(r[0].checked, false); try eq(r[0].style.flag("bold"), true)
    try r[0].click!(); try r[1].click!(); try r[2].body[0].cells[0].click!()
    r = try p.render()
    try eq(r[0].checked, true); try eq(r[1].checked, true)
    try eq(r[2].body[0].cells[0].checked, true); try eq(r[2].body[0].cells[0].kind, "checkbox")
    try check(try text(p).contains("[x] Notify me"))
    _ = try expectErr("state n: Int = 0\nview { checkbox n \"x\" }", "type error", "needs Bool")
    _ = try expectErr("state on: Bool = false\nview { checkbox !on \"x\" }", "type error", "must name a Bool state")
    _ = try expectErr("state on: Bool = false\nview { checkbox on \"x\" width 4 }", "type error", "cannot have 'width'")
}
test("data table example sorts both ways and pages without repeating") {
    let p = try load(ex("datatable"))
    func table() throws -> RNode { try p.render().first { $0.kind == .table }! }
    func names() throws -> [String] { try table().rows.map { $0[1] }.filter { !$0.isEmpty && !$0.hasPrefix("Picked") } }
    func head(_ i: Int) throws { try table().hrow!.cells[i].click!() }
    func btn(_ l: String) throws { try click(p, l) }
    try eq(try names(), ["Cupcake", "Donut", "Eclair", "Froyo"])
    try head(2); try eq(try names(), ["Froyo", "Ice cream", "Eclair", "Cupcake"])
    try head(2); try eq(try names(), ["KitKat", "Donut", "Honeycomb", "Jelly bean"])
    try check(try table().hrow!.cells[2].text.contains("\u{25BC}"))
    try head(3); try eq(try names(), ["Jelly bean", "Honeycomb", "Cupcake", "Froyo"])
    func labels() throws -> [String] { try p.render().first { $0.kind == .row }!.children.map { $0.text }.filter { !$0.isEmpty } }
    try check(!(try labels().contains("Previous")) && (try labels().contains("Next")))
    try btn("Next"); try btn("Next"); try eq(try names(), ["KitKat"])
    try check((try labels().contains("Previous")) && !(try labels().contains("Next")))
    try btn("Previous"); try btn("Previous"); try eq(try names(), ["Jelly bean", "Honeycomb", "Cupcake", "Froyo"])
}
test("text boxes edit list items and struct fields, also inside tables") {
    let p = try page("""
for i in range(len(names)) { input names[i] placeholder "name" }
for i in range(len(people)) { input people[i].name }
table { for i in range(len(names)) { cells input names[i], toText(i) } }
""", """
state names: List<Text> = ["a", "b"]
struct P { name: Text  age: Int }
state people: List<P> = [P(name: "x", age: 1)]
""")
    func inputs(_ r: [RNode]) -> [String] { r.filter { $0.kind == .input }.map { $0.value } }
    var r = try p.render()
    try eq(inputs(r), ["a", "b", "x"])
    try r[1].set!("B!"); try r[2].set!("Xavier")
    r = try p.render()
    try eq(inputs(r), ["a", "B!", "Xavier"])
    let tb = r.first { $0.kind == .table }!
    try eq(tb.body[1].cells[0].kind, "input"); try eq(tb.body[1].cells[0].text, "B!")
    try tb.body[0].cells[0].set!("first")
    try eq(p.state["names"]!, .list([.text("first"), .text("B!")]))
    try check(try text(p).contains("[_first_]"))
    _ = try expectErr("state n: List<Int> = [1]\nview { input n[0] }", "type error", "input can only edit Text")
    _ = try expectErr("state n: List<Text> = [\"a\"]\nview { for s in n { input s } }", "type error", "is not a state")
    _ = try expectErr("struct P { name: Text }\nstate ps: List<P> = [P(name: \"a\")]\nview { for p in ps { input p.name } }", "type error", "copy of a list item")
    _ = try expectErr("view { input 5 }", "syntax error", "input edits a Text state")
}
test("table resizable, in any order with style words") {
    try check(try page("table { cells \"a\" }").render()[0].resizable == false)
    for head in ["resizable", "resizable height 100", "height 100 resizable", "padding 4 resizable height 90"] {
        try check(try page("table \(head) { cells \"a\" }").render()[0].resizable, "resizable: \(head)")
    }
    _ = try expectErr("state resizable: Int = 1\nview { text \"x\" }", "syntax error", "resizable")
}
test("modal draws only while its Bool is true, and closes itself or runs its action") {
    let p = try page("""
button "Open" -> open = true
modal open width 300 radius 4 {
  heading "Sure?"
  button "Yes" -> { n = n + 1 open = false }
}
modal n > 5 -> n = 0 { text "Big" }
""", "state open: Bool = false\nstate n: Int = 0")
    func kinds(_ r: [RNode]) -> [RNode.Kind] { r.map { $0.kind } }
    var r = try p.render()
    try eq(kinds(r), [.button])
    try r[0].click!(); r = try p.render()
    try eq(kinds(r), [.button, .modal])
    try eq(r[1].style.int("width"), 300); try eq(r[1].style.int("radius"), 4)
    try eq(kinds(r[1].children), [.heading, .button])
    try check(try text(p).contains("[modal]") && text(p).contains("[/modal]"))
    try r[1].click!(); r = try p.render()                          // closing a bare-state modal sets it false
    try eq(p.state["open"]!, .bool(false)); try eq(kinds(r), [.button])
    try r[0].click!(); try p.render()[1].children[1].click!(); try eq(p.state["n"]!, .int(1))
    p.state["n"] = .int(9); r = try p.render()                     // an expression modal closes with its action
    try eq(r.last!.kind, .modal); try r.last!.click!()
    try eq(p.state["n"]!, .int(0))
    _ = try expectErr("state o: Bool = false\nview { row { modal o { text \"x\" } } }", "type error", "directly in the view")
    _ = try expectErr("state o: Bool = false\nview { modal o { modal o { text \"x\" } } }", "type error", "directly in the view")
    _ = try expectErr("state n: Int = 0\nview { modal n { text \"x\" } }", "type error", "needs Bool")
    _ = try expectErr("state o: Bool = false\nview { modal !o { text \"x\" } }", "type error", "must name a Bool state")
    _ = try expectErr("state o: Bool = false\nview { modal o height 4 { text \"x\" } }", "type error", "cannot have 'height'")
}
test("layout: gap, margin, grow, widths, align and grid") {
    let p = try page("""
row gap 20 align spread margin 4 { text "a" grow 2 maxwidth 300 minwidth 50
  button "b" grow 1 margin 2 -> n = 1 }
column gap 0 align center maxwidth 500 { text "c" margin 6 grow 1 }
grid 3 gap 12 padding 8 { text "1"
  text "2" }
grid n { text "x" }
text "t" margin 100 grow 99 maxwidth 5000
""", "state n: Int = 99")
    let r = try p.render()
    try eq(r[0].style, st(["gap": 20, "align": "spread", "margin": 4]))
    try eq(r[0].children[0].style, st(["grow": 2, "maxwidth": 300, "minwidth": 50]))
    try eq(r[0].children[1].style, st(["grow": 1, "margin": 2]))
    try eq(r[1].style, st(["gap": 0, "align": "center", "maxwidth": 500]))
    try eq(r[2].kind, .grid); try eq(r[2].columns, 3)
    try eq(r[2].style, st(["gap": 12, "padding": 8])); try eq(r[2].children.count, 2)
    try eq(r[3].columns, 12)
    try eq(r[4].style, st(["margin": 64, "grow": 12, "maxwidth": 2000]))
    try check(try text(p).contains("<grid 3>"))
    _ = try expectErr("view { text \"x\" gap 4 }", "type error", "a text cannot have 'gap'")
    _ = try expectErr("view { grid 2 align center { text \"x\" } }", "type error", "a grid cannot have 'align'")
    _ = try expectErr("view { button \"b\" maxwidth 5 -> back }", "type error", "a button cannot have 'maxwidth'")
    _ = try expectErr("view { grid \"two\" { text \"x\" } }", "type error", "needs Int")
    _ = try expectErr("state on: Bool = false\nview { row { grid 2 { modal on { text \"x\" } } } }", "type error", "directly in the view")
    _ = try expectErr("state grid: Int = 1\nview { text \"x\" }", "syntax error", "grid")
}
test("select and radio edit a Text place from a list of options") {
    let p = try page("""
select shade in colors placeholder "Pick" width 200
radio plan in ["Free", "Pro"] color red
for i in range(len(people)) { select people[i].role in roles }
table { for i in range(len(people)) { cells select people[i].role in roles placeholder "role", "x" } }
""", """
state colors: List<Text> = ["Red", "Green"]
state shade: Text = "Green"
state plan: Text = "Pro"
state roles: List<Text> = ["admin", "user"]
struct P { name: Text  role: Text }
state people: List<P> = [P(name: "a", role: "user"), P(name: "b", role: "")]
""")
    var r = try p.render()
    try eq(r[0].kind, .select); try eq(r[0].value, "Green"); try eq(r[0].options, ["Red", "Green"])
    try eq(r[0].placeholder, "Pick"); try eq(r[0].style.int("width"), 200)
    try eq(r[1].kind, .radio); try eq(r[1].options, ["Free", "Pro"]); try eq(r[1].value, "Pro")
    try eq(r[1].style.text("color"), "#d1242f")
    try r[0].set!("Red"); try r[1].set!("Free"); try r[3].set!("admin")
    r = try p.render()
    try eq(p.state["shade"]!, .text("Red")); try eq(p.state["plan"]!, .text("Free"))
    let tb = r.first { $0.kind == .table }!
    try eq(tb.body[0].cells[0].kind, "select"); try eq(tb.body[0].cells[0].options, ["admin", "user"])
    try tb.body[0].cells[0].set!("admin")
    let t = try text(p)
    try check(t.contains("[select: Red]") && t.contains("(x) Free") && t.contains("( ) Pro"))
    _ = try expectErr("state n: Int = 0\nview { select n in [\"a\"] }", "type error", "select can only edit Text state")
    _ = try expectErr("state c: Text = \"\"\nview { select c in [1, 2] }", "type error", "the options of a select needs List<Text>")
    _ = try expectErr("state c: Text = \"\"\nview { radio c in \"abc\" }", "type error", "the options of a radio needs List<Text>")
    _ = try expectErr("state c: Text = \"\"\nview { select c [\"a\"] }", "syntax error", "'in'")
    _ = try expectErr("struct P { name: Text }\nstate ps: List<P> = [P(name: \"a\")]\nview { for p in ps { radio p.name in [\"a\"] } }", "type error", "copy of a list item")
    _ = try expectErr("state c: Text = \"\"\nview { select c in [\"a\"] bold }", "type error", "a select cannot have 'bold'")
    _ = try expectErr("view { select 5 in [\"a\"] }", "syntax error", "select edits a Text state")
}
test("textarea, slider and disabled") {
    let decls = """
state notes: Text = "ab"
state level: Int = 99
state low: Int = 0
state levels: List<Int> = [1, 9]
state name: Text = ""
state n: Int = 0
state flag: Bool = false
state pick: Text = ""
state locked: Bool = true
"""
    let bad = try page("slider low in 5 to 1", decls)
    do { _ = try bad.render(); throw Fail(description: "expected a runtime error") }
    catch let e as TernError { try check(e.msg.contains("this slider ends (1) before it starts (5)")) }
    let p = try page("""
textarea notes placeholder "Notes" height 120 width 300
slider level in 0 to 10 width 200
slider levels[1] in 0 to 3
input name disabled when locked width 150
button "Go" disabled when locked -> n = n + 1
checkbox flag "f" disabled when locked
select pick in ["a", "b"] disabled when locked
radio pick in ["a", "b"] disabled
table { cells button "t" disabled -> n = n + 100 }
""", decls)
    var r = try p.render()
    try eq(r[0].kind, .textarea); try eq(r[0].value, "ab"); try eq(r[0].style.int("height"), 120)
    try eq(r[1].kind, .slider); try eq(r[1].number, 10); try eq(r[1].lower, 0); try eq(r[1].upper, 10); try eq(p.state["level"]!, .int(99))
    try eq(r[2].number, 3)
    try r[0].set!("x\ny"); try r[1].set!("4"); try r[2].set!("2")
    try eq(p.state["notes"]!, .text("x\ny")); try eq(p.state["level"]!, .int(4)); try eq(p.state["levels"]!, .list([.int(1), .int(2)]))
    for i in 3...7 { try eq(r[i].style.flag("disabled"), true) }
    try r[3].set!("typed"); try r[4].click!(); try r[5].click!(); try r[6].set!("a"); try r[7].set!("b")
    try r[8].body[0].cells[0].click!()
    try eq(p.state["name"]!, .text("")); try eq(p.state["n"]!, .int(0)); try eq(p.state["flag"]!, .bool(false)); try eq(p.state["pick"]!, .text(""))
    p.state["locked"] = .bool(false); r = try p.render()
    try eq(r[3].style.flag("disabled"), false)
    try r[3].set!("typed"); try r[4].click!(); try r[5].click!(); try r[6].set!("a")
    try eq(p.state["name"]!, .text("typed")); try eq(p.state["n"]!, .int(1)); try eq(p.state["flag"]!, .bool(true)); try eq(p.state["pick"]!, .text("a"))
    let t = try text(p)
    try check(t.contains("[textarea: x]") && t.contains("[slider: 4 in 0..10]"))
    _ = try expectErr("state s: Text = \"\"\nview { slider s in 0 to 5 }", "type error", "slider can only edit Int state")
    _ = try expectErr("state n: Int = 0\nview { slider n in \"a\" to 5 }", "type error", "needs Int")
    _ = try expectErr("state n: Int = 0\nview { slider n in 0 }", "syntax error", "'to'")
    _ = try expectErr("state n: Int = 0\nview { textarea n }", "type error", "textarea can only edit Text state")
    _ = try expectErr("view { slider 5 in 0 to 1 }", "syntax error", "slider edits an Int state")
    _ = try expectErr("state s: Text = \"\"\nview { textarea s bold }", "type error", "a textarea cannot have 'bold'")
    _ = try expectErr("view { text \"x\" disabled }", "type error", "a text cannot have 'disabled'")
    _ = try expectErr("state s: Text = \"\"\nview { input s height 4 }", "type error", "an input cannot have 'height'")
}
test("saved state is restored when it still fits its type") {
    let decls = """
struct P { name: Text  age: Int }
saved state n: Int = 1
saved state xs: List<Text> = ["a"]
saved state who: List<P> = []
saved state f: Float = 0.5
saved state c: Color = red
saved state ok: Bool = false
state temp: Int = 7
"""
    let src = "page \"t\"\n\(decls)\nview {\ntext \"x\"\n}"
    let first = try Page(src)
    try eq(first.savedNames, ["n", "xs", "who", "f", "c", "ok"])
    first.state["n"] = .int(5); first.state["xs"] = .list([.text("q"), .text("r")])
    first.state["who"] = .list([.record(["name": .text("Z"), "age": .int(3)])]); first.state["temp"] = .int(99); first.state["ok"] = .bool(true)
    let json = first.savedJSON()!
    try check(!json.contains("temp"))                                      // only saved states
    let second = try Page(src, saved: json)
    try eq(second.state["n"]!, .int(5)); try eq(second.state["xs"]!, .list([.text("q"), .text("r")]))
    try eq(second.state["who"]!, .list([.record(["name": .text("Z"), "age": .int(3)])])); try eq(second.state["ok"]!, .bool(true))
    try eq(second.state["temp"]!, .int(7))                                 // not saved: starts fresh
    try eq(second.state["f"]!, .float(0.5)); try eq(second.state["c"]!, .text("#d1242f"))
    // values that do not fit the declared type are ignored
    let bad = try Page(src, saved: "{\"n\":\"five\",\"xs\":[1],\"who\":[{\"name\":\"Z\"}],\"f\":\"x\",\"c\":\"red\",\"ok\":1}")
    try eq(bad.state["n"]!, .int(1)); try eq(bad.state["xs"]!, .list([.text("a")])); try eq(bad.state["who"]!, .list([]))
    try eq(bad.state["f"]!, .float(0.5)); try eq(bad.state["c"]!, .text("#d1242f")); try eq(bad.state["ok"]!, .bool(false))
    let extra = try Page(src, saved: "{\"who\":[{\"name\":\"a\",\"age\":1,\"evil\":2}],\"n\":1.5}")
    try eq(extra.state["who"]!, .list([])); try eq(extra.state["n"]!, .int(1))
    let junk = try Page(src, saved: "not json"); try eq(junk.state["n"]!, .int(1))
    try check(try page("text \"x\"", "state z: Int = 1").savedJSON() == nil)   // nothing saved
    let big = try page("text \"x\"", "saved state t: Text = \"\""); big.state["t"] = .text(String(repeating: "x", count: 70000))
    try check(big.savedJSON() == nil); try check(big.savedTooBig)
    _ = try expectErr("saved view { text \"x\" }", "syntax error", "expected 'use'")
}
test("every gives the host timers, with limits") {
    let p = try page("""
every 1000 when running -> secs = secs + 1
every 5 -> secs = secs + 100
text toText(secs)
for i in range(6) { every 2000 -> secs = secs + 1 }
modal open { every 500 -> secs = secs + 1000 }
every 100 + 400 when secs >= 0 -> { secs = secs + 10000 }
""", "state running: Bool = false\nstate secs: Int = 0\nstate open: Bool = false")
    var r = try p.render()
    try eq(p.timers.map { $0.ms }, [100, 2000, 2000, 2000])         // first is off; 5 ms is raised to 100; at most 4
    try p.timers[0].tick(); try p.timers[1].tick(); try eq(p.state["secs"]!, .int(101))
    p.state["running"] = .bool(true); p.state["secs"] = .int(0); r = try p.render()
    try eq(p.timers.map { $0.ms }, [1000, 100, 2000, 2000])
    try p.timers[0].tick(); try eq(p.state["secs"]!, .int(1))
    try check(r.allSatisfy { $0.kind == .text }, "timers are not drawn")
    // a timer that keeps failing stops after 3 errors
    let q = try page("every 100 -> n = n / z\ntext \"x\"", "state n: Int = 1\nstate z: Int = 0")
    _ = try q.render(); let t = q.timers[0]
    for _ in 0..<2 { do { try t.tick(); throw Fail(description: "expected an error") } catch let e as TernError { try check(e.msg.contains("division by zero")) } }
    do { try t.tick(); throw Fail(description: "expected an error") } catch let e as TernError { try check(e.msg.contains("stopped after 3 errors")) }
    _ = try q.render(); try eq(q.timers.count, 0)
    q.state["z"] = .int(1); _ = try q.render(); try eq(q.timers.count, 0)   // stays stopped
    _ = try expectErr("view { every \"soon\" -> back }", "type error", "needs Int")
    _ = try expectErr("state n: Int = 0\nview { every 100 when n -> back }", "type error", "needs Bool")
    _ = try expectErr("state n: Int = 0\nview { every 100 -> n = \"a\" }", "type error", "needs Int")
    _ = try expectErr("view { every 100 back }", "syntax error", "'->'")
}
// ---- web page converter
func conv(_ html: String, _ base: String = "https://example.com/docs/page.html", main: Bool = true) throws -> ConvertResult {
    try convertHTML(html, from: URL(string: base), mainOnly: main, date: "2026-11-02")
}
test("converter: structure, links, images, tables, lists") {
    let r = try conv("""
<html><head><title>My &amp; Page</title><style>p{color:red}</style><script>alert(1)</script></head><body>
<h1>Hello</h1><p>Some <b>bold</b> and <i>italic</i> text with a <a href="/more?x=1">link</a>.</p>
<ul><li>One</li><li>Two <a href="https://other.org/">other</a></li></ul><ol><li>First</li><li>Second</li></ol>
<img src="/pic.png" alt="A picture" width="300"><img src="x.gif" width="1" height="1"><hr>
<table><tr><th>Name</th><th>Qty</th></tr><tr><td>Tea</td><td>2</td></tr><tr><td colspan="2">Total</td></tr></table>
<pre>line 1
  line 2</pre><blockquote>Quoted</blockquote>
</body></html>
""")
    try eq(r.title, "My & Page")
    let src = r.source
    for want in ["page \"My & Page\"", "heading \"Hello\" size 26", "span \"bold\" bold", "span \"italic\" italic",
                 "link \"link\" to \"https://example.com/more?x=1\"", "bullet \"One\"", "bullet \"Two other\"", "link \"other\" to \"https://other.org/\"",
                 "\"1. First\"", "\"2. Second\"", "image \"https://example.com/pic.png\" alt \"A picture\" width 300", "divider",
                 "header \"Name\", \"Qty\"", "cells \"Tea\", \"2\"", "cells \"Total\" span 2", "font mono", "padding 10 background #f6f8fa radius 6"] {
        try check(src.contains(want), "missing: \(want)\n\(src)")
    }
    try check(!src.contains("x.gif"), "tracking pixel kept")
    try check(!src.contains("alert") && !src.contains("color:red"), "script or style leaked")
    try eq(r.dropped["scripts"], 1)
    try check(src.contains("Dropped: 1 script."))
}
test("converter: text can never become Tern code") {
    let evil = "He said \"hi\" \\ and \" } view { text \"owned"
    let r = try conv("<p>\(evil.replacingOccurrences(of: "\"", with: "&quot;"))</p><h2 title='x'>a \"quoted\" heading</h2><a href=\"https://e.com/\\\"x\">y</a>")
    let p = try Page(r.source)
    let shown = try text(p)
    try check(shown.contains("He said \"hi\" \\ and \" } view { text \"owned"), shown)   // shown as plain text
    try eq(try p.render().filter { $0.kind == .text }.count + (try p.render().filter { $0.kind == .heading }.count), 2)
    try check(!r.source.contains("\n} view {"))
    // line breaks and control characters in text become spaces or disappear
    let r2 = try conv("<p>line one\nline two\u{0007}\u{0}end</p>")
    try check(r2.source.contains("\"line one line twoend\""), r2.source)
}
test("converter: entities and whitespace") {
    let r = try conv("<p>a&nbsp;&nbsp;b &amp; c &lt;d&gt; &#65;&#x42; &copy; &unknown; &#0; caf&eacute;</p>")
    try check(r.source.contains("\"a b & c <d> AB \u{A9} &unknown; \u{FFFD} caf&eacute;\""), r.source)
    let r2 = try conv("<p>   lots \n\t of    space   </p>")
    try check(r2.source.contains("text \"lots of space\""), r2.source)
}
test("converter: main content, dropped parts, forms") {
    let page = """
<body><header><a href="/">Site</a></header><nav><a href="/a">A</a></nav>
<main><h1>Title</h1><p>Real content</p><form action="/x"><label>Name <input name="n"></label><button>Go</button></form>
<iframe src="x"></iframe><video src="v"></video><svg><circle/></svg><div hidden>secret</div><p style="display:none">gone</p></main>
<aside>Related</aside><footer>Copyright</footer></body>
"""
    let r = try conv(page)
    try check(r.source.contains("Real content") && !r.source.contains("Related") && !r.source.contains("Copyright") && !r.source.contains("secret") && !r.source.contains("gone"), r.source)
    try check(r.source.contains("Name"), "label text kept")
    for (k, v) in ["form controls": 2, "iframes": 1, "media": 1, "graphics": 1, "hidden parts": 2] { try check(r.dropped[k] == v, "\(k): \(r.dropped[k] ?? 0) not \(v)") }
    // no <main>: the body minus its header, footer and navigation
    let r2 = try conv("<body><header>Top</header><nav>Menu</nav><div><p>Body text</p></div><footer>Bottom</footer></body>")
    try check(r2.source.contains("Body text") && !r2.source.contains("Top") && !r2.source.contains("Menu") && !r2.source.contains("Bottom"), r2.source)
    // everything
    let r3 = try conv("<body><header>Top</header><nav>Menu</nav><p>Body text</p><footer>Bottom</footer></body>", main: false)
    try check(r3.source.contains("Top") && r3.source.contains("Menu") && r3.source.contains("Bottom"), r3.source)
    // an article is preferred when there is no main
    let long = String(repeating: "word ", count: 80)
    let r4 = try conv("<body><p>Outside</p><article><p>\(long)</p></article></body>")
    try check(r4.source.contains("word word") && !r4.source.contains("Outside"), r4.source)
}
test("converter: links and images only for http(s) addresses") {
    let r = try conv("""
<p><a href="javascript:alert(1)">js</a> <a href="mailto:a@b.c">mail</a> <a href="#top">top</a> <a href="//cdn.example.org/x">proto</a> <a href="page2.html">rel</a></p>
<img src="data:image/png;base64,AAAA"><img data-src="/lazy.jpg"><img src="javascript:x">
""")
    let src = r.source
    try check(!src.contains("javascript") && !src.contains("mailto") && !src.contains("#top"), src)
    try check(src.contains("to \"https://cdn.example.org/x\"") && src.contains("to \"https://example.com/docs/page2.html\""), src)
    try check(src.contains("image \"https://example.com/lazy.jpg\"") && !src.contains("data:"), src)
    try eq(r.dropped["inline images"], 1)
    let nobase = try convertHTML("<p><a href=\"/x\">rel</a> <a href=\"https://a.com/\">abs</a></p>", from: nil)
    try check(!nobase.source.contains("\"/x\"") && nobase.source.contains("https://a.com/"), nobase.source)
}
test("converter: inline styles") {
    let r = try conv("""
<h2 style="color:#336699;text-align:center">Styled</h2>
<p style="font-size:16px;background:rgb(10,20,30);color:#fff">Dark box</p>
<p style="color:#ff0000">Red <span style="color:rgb(0,128,0);font-weight:700">green bold</span></p>
<div style="background-color:#cce0ff;"><p>In a box</p></div><center><p>Centered</p></center>
""")
    let src = r.source
    for want in ["heading \"Styled\" size 21 align center color #336699", "text \"Dark box\" color #ffffff size 12 background #0a141e", "span \"green bold\" bold color #008000",
                 "column background #cce0ff padding 12 radius 6", "text \"Centered\" align center"] {
        try check(src.contains(want), "missing: \(want)\n\(src)")
    }
    try check(!(try conv("<p style=\"color:#fff\">White on nothing</p>").source.contains("color #ffffff")), "white text with no background must be dropped")
}
test("converter: layout tables, malformed and hostile input") {
    let r = try conv("<table><tr><td><h3>Left</h3><p>A</p></td><td><p>B</p></td></tr></table>")
    try check(r.source.contains("heading \"Left\"") && !r.source.contains("table {"), r.source)
    let wide = try conv("<table><thead><tr><th>A<th>B<th>C<th>D<th>E<th>F</thead><tbody><tr><td>1<td>2<td>3<td>4<td>5<td>6</table>")
    try check(wide.source.contains("table resizable") && wide.source.contains("header \"A\", \"B\", \"C\", \"D\", \"E\", \"F\""), wide.source)
    let ragged = try conv("<table><tr><th>A<th>B<tr><td>1<tr><td>1<td>2<td>3</table>")
    try check(ragged.source.contains("cells \"1\", \"\"") , ragged.source)               // short rows are padded
    // unclosed and mismatched tags
    let messy = try conv("<div><p>one<p>two<ul><li>a<li>b</div></span><b>bold<i>both</b>x</i><<>& <a href=")
    try check(messy.source.contains("\"one\"") && messy.source.contains("\"two\"") && messy.source.contains("bullet \"b\""), messy.source)
    // very deep nesting and very large input
    let deep = String(repeating: "<div>", count: 20000) + "deep text" + String(repeating: "</div>", count: 20000)
    try check(try conv(deep).source.contains("deep text"))
    let many = String(repeating: "<p>A paragraph of text to fill the page.</p>", count: 30000)
    let big = try conv(many)
    try check(big.truncated && big.source.count <= CONVERT_MAX_OUTPUT + 2000)
    let attrs = "<a " + String(repeating: "x=1 ", count: 5000) + "href=\"/ok\">link</a>"
    _ = try conv(attrs)
}
test("converter: empty and script-only pages say so") {
    try check(try conv("").source.contains("Nothing readable was found"))
    let js = try conv("<html><head><title>App</title></head><body><div id=\"root\"></div><script src=\"app.js\"></script></body></html>")
    try check(js.source.contains("builds its content with JavaScript") && js.source.contains("page \"App\""), js.source)
    try eq(js.title, "App")
    let notitle = try conv("<h1>Only heading</h1><p>text</p>")
    try eq(notitle.title, "Only heading")
}
test("plain text view") {
    let t = try text(try load(ex("article")))
    try check(t.contains("| Type") && t.contains("* Tables, lists"), t)
}
test("all examples load; only broken fails") {
    for id in exampleIds {
        let libs = exampleLibs()
        if id == "broken" { try throwsTern({ _ = try Page(ex(id), libraries: libs) }) }
        else { _ = try Page(ex(id), libraries: libs).render() }
    }
}

// ================= 0.3 =================
// ---- Float
test("float literals and arithmetic") {
    try eq(try txt1("text toText(1.5 + 2.25) + \" \" + toText(3.0 * 2.0) + \" \" + toText(7.0 / 2.0) + \" \" + toText(1.0 - 0.25)"), "3.75 6.0 3.5 0.75")
}
test("float toText hides binary noise") { try eq(try txt1("text toText(0.1 + 0.2)"), "0.3") }
test("float comparisons and unary minus") {
    try eq(try txt1("text toText(-2.5 < 1.0) + toText(2.0 == 2.0) + toText(-1.5 * 2.0)"), "truetrue-3.0")
}
test("Int and Float never mix silently") {
    try expectErr("state n: Int = 1\nview { text toText(n + 1.5) }", "type error", "cannot mix Int and Float")
    try expectErr("state x: Float = 1\nview { }", "type error", "needs Float but this is Int")
    try expectErr("view { text toText(5.0 % 2.0) }", "type error", "'%' only works on Int")
    try expectErr("view { text toText(1.5 < 2) }", "type error", "cannot mix")
}
test("float conversion helpers") {
    try eq(try txt1("text toText(toFloat(3) / 2.0)"), "1.5")
    try eq(try txt1("text toText(round(2.5)) + toText(round(2.4)) + toText(floor(2.9)) + toText(ceil(2.1))"), "3223")
    try eq(try txt1("text fixed(3.14159, 2) + \" \" + fixed(2.0, 3) + \" \" + fixed(0.005, 1)"), "3.14 2.000 0.0")
    try eq(try txt1("text toText(sqrt(2.25))"), "1.5")
    try expectErr("view { text toText(round(3)) }", "type error", "needs Float")
}
test("parse text to numbers safely") {
    try eq(try txt1("text toText(toIntOr(\" 42 \", 0)) + toText(toIntOr(\"4x\", -1)) + toText(toFloatOr(\"2.5\", 0.0)) + toText(toFloatOr(\"\", 9.5))"), "42-12.59.5")
}
test("float division by zero and sqrt of negative are runtime errors") {
    var p = try page("button \"go\" -> r = 1.0 / z\ntext fixed(r, 1)", "state r: Float = 0.0\nstate z: Float = 0.0")
    try throwsTern({ try click(p, "go") }, { $0.phase == "runtime error" && $0.msg.contains("division") })
    p = try page("button \"go\" -> r = sqrt(0.0 - 4.0)", "state r: Float = 0.0")
    try throwsTern({ try click(p, "go") }, { $0.msg.contains("square root") })
}
test("Int division still floors; Float division is exact") {
    try eq(try txt1("text toText(7 / 2) + \" \" + toText(7.0 / 2.0)"), "3 3.5")
}
test("tip calculator example") {
    let p = try load(ex("tip"))
    try type(p, "bill", "80"); try click(p, "20%")
    let t = try text(p)
    try check(t.contains("Tip (20%): $16.00") && t.contains("Total: $96.00"), t)
    try type(p, "bill", "abc")
    try check(try text(p).contains("Total: $0.00"))
}

// ---- Font
test("Font type and constants") {
    let r = try page("text \"a\" font serif\ntext \"b\" font f", "state f: Font = mono").render()
    try eq(r[0].style.text("font"), "serif"); try eq(r[1].style.text("font"), "mono")
    try expectErr("view { text \"a\" font \"serif\" }", "type error", "needs Font")
    try expectErr("view { text \"a\" font 3 }", "type error", "needs Font")
}

// ---- richer styling: buttons, boxes
test("buttons can be styled in depth") {
    let p = try page("button \"Go\" size 18 bold font rounded color white background blue padding 14 radius 999 border #003 width 220 -> n = 1", "state n: Int = 0")
    try eq(try p.render()[0].style, st(["size": 18, "bold": true, "font": "rounded", "color": "#ffffff", "background": "#0b57d0", "padding": 14, "radius": 999, "border": "#000033", "width": 220]))
}
test("button style via named style") {
    let p = try page("button \"Go\" style cta -> n = 1", "state n: Int = 0\nstyle cta { background blue color white radius 10 align center }")
    try eq(try p.render()[0].style, st(["background": "#0b57d0", "color": "#ffffff", "radius": 10]))
}
test("box props on rows/columns, clamped") {
    let r = try page("column background gray padding 12 radius 5000 border red width 9999 { text \"x\" }").render()[0]
    try eq(r.style, st(["background": "#6e7781", "padding": 12, "radius": 999, "border": "#d1242f", "width": 2000]))
}
test("text can have padding/radius/border") {
    try eq(try page("text \"x\" padding 8 radius 6 border gray").render()[0].style, st(["padding": 8, "radius": 6, "border": "#6e7781"]))
}
test("props that do not belong are still rejected") {
    try expectErr("view { button \"b\" align center -> n = 1 }\nstate n: Int = 0", "type error", "a button cannot have 'align'")
    try expectErr("view { text \"b\" width 100 }", "type error", "a text cannot have 'width'")
    try expectErr("view { link \"b\" to \"x\" padding 3 }", "type error", "a link cannot have 'padding'")
}

// ---- navigation
let SITE = """
state hits: Int = 0
view home {
  text "HOME"
  button "Go menu" -> goto menu
  button "Hit" -> hits = hits + 1
}
view menu {
  text "MENU " + toText(hits)
  button "Go about" -> { hits = hits + 10 goto about }
  button "Back" -> back
}
view about {
  text "ABOUT"
  link "Home" -> goto home
  button "Back" -> back
}
"""
test("several pages: start on the first, goto and back") {
    let p = try load("page \"s\"\n" + SITE)
    try eq(p.screens, ["home", "menu", "about"])
    try eq(p.screen, "home"); try check(try text(p).contains("HOME"))
    try click(p, "Hit", 2); try click(p, "Go menu")
    try eq(p.screen, "menu"); try check(try text(p).contains("MENU 2"))
    try click(p, "Go about")
    try eq(p.screen, "about"); try eq(p.history, ["home", "menu"])
    try click(p, "Back"); try eq(p.screen, "menu"); try check(try text(p).contains("MENU 12"))
    try click(p, "Back"); try eq(p.screen, "home")
    p.back(); try eq(p.screen, "home")
}
test("a link can run an action") {
    let p = try load("page \"s\"\n" + SITE)
    try click(p, "Go menu"); try click(p, "Go about")
    let l = try p.render().first { $0.kind == .link }!
    try check(l.target == nil)
    try l.click!(); try eq(p.screen, "home")
}
test("goto from a function, and to the current page does nothing") {
    let p = try load("fn leave() { goto b }\nview a { button \"x\" -> leave() }\nview b { text \"B\" button \"y\" -> goto b }")
    try click(p, "x"); try eq(p.screen, "b"); try eq(p.history.count, 1)
    try click(p, "y"); try eq(p.history.count, 1)
}
test("navigation errors") {
    try expectErr("view { button \"x\" -> goto nowhere }", "type error", "no page called 'nowhere'")
    try expectErr("view { text \"a\" }\nview { text \"b\" }", "type error", "two pages called 'home'")
    try expectErr("view a { text \"a\" }\nview a { text \"b\" }", "type error", "two pages called 'a'")
    try expectErr("view a { button \"x\" -> goto }", "syntax error", "name of a page")
}
test("a single unnamed view is called home") {
    let p = try load("view { text \"x\" button \"h\" -> goto home }")
    try eq(p.screens, ["home"])
}
test("multi-page example runs") {
    let p = try load(ex("pages"))
    try check(p.screens.count == 3)
    try click(p, "Menu"); try check(try text(p).contains("Espresso") && text(p).contains("$2.50"))
    try click(p, "Back"); try click(p, "About"); try eq(p.screen, "about")
}

// ---- images
test("image node with size, alt and style") {
    let n = try page("image \"mountains\" width 200 height 100 radius 12 alt \"Peaks\" align center border gray").render()[0]
    try eq(n.kind, .image); try eq(n.src, "mountains"); try eq(n.alt, "Peaks")
    try eq(n.style, st(["width": 200, "height": 100, "radius": 12, "align": "center", "border": "#6e7781"]))
}
test("image source can be computed") { try eq(try page("image pic", "state pic: Text = \"logo\"").render()[0].src, "logo") }
test("image names are checked when the host knows its assets") {
    let ok = try load("view { image \"logo\" }", assets: ["logo", "sunset"])
    try eq(try ok.render()[0].src, "logo")
    let e = try errOf("view { image \"lgo\" }", assets: ["logo", "sunset"])
    try check(e.phase == "type error" && e.msg.contains("no image called \"lgo\"") && e.msg.contains("logo, sunset"), e.msg)
    _ = try load("view { image \"https://example.com/a.png\" }", assets: [])
    _ = try load("view { image \"data:image/png;base64,AAAA\" }", assets: [])
    _ = try load("view { image \"anything\" }")
}
test("image errors") {
    try expectErr("view { image 5 }", "type error", "needs Text")
    try expectErr("view { image \"a\" color red }", "type error", "an image cannot have 'color'")
    try expectErr("view { image \"a\" width \"wide\" }", "type error", "needs Int")
}
test("all new examples load") {
    for id in ["pages", "tip", "fonts", "images", "buttons"] { _ = try load(ex(id), assets: ["mountains", "sunset", "avatar", "logo"]).render() }
}
test("old reserved names are only the documented ones") {
    try eq(try txt1("text name + \" \" + toText(count)", "state name: Text = \"n\"\nstate count: Int = 3"), "n 3")
}

// ================= structs (0.4) =================
let ITEM = "struct Item {\n  name: Text\n  price: Int\n  qty: Int\n}\n"
test("struct: create, read, with, list") {
    let p = try page("for i in cart { text i.name + \" \" + toText(lineTotal(i)) }\nbutton \"more\" -> bump(0)",
        ITEM + "state cart: List<Item> = [Item(name: \"Tea\", price: 3, qty: 2)]\nfn lineTotal(i: Item): Int { return i.price * i.qty }\nfn bump(n: Int) { cart = setAt(cart, n, cart[n] with qty: cart[n].qty + 1) }")
    try eq(try text(p).components(separatedBy: "\n")[0], "Tea 6")
    try click(p, "more")
    try eq(try text(p).components(separatedBy: "\n")[0], "Tea 9")
}
test("struct: equality by value, with leaves original") {
    try eq(try txt1("text toText(a == b) + toText(a == c) + toText(a.qty)",
        ITEM + "state a: Item = Item(name: \"T\", price: 1, qty: 1)\nstate b: Item = Item(qty: 1, price: 1, name: \"T\")\nstate c: Item = a with qty: 2, price: 5"), "truefalse1")
}
test("struct: nested") {
    try eq(try txt1("text o.item.name", ITEM + "struct Order {\n item: Item\n note: Text\n}\nstate o: Order = Order(item: Item(name: \"X\", price: 1, qty: 1), note: \"n\")"), "X")
}
test("struct errors") {
    let base = "page \"t\"\n\(ITEM)state s: Item = Item(name: \"a\", price: 1, qty: 1)\n"
    _ = try expectErr(base + "view { text s.nope }", "type error", "no field 'nope'")
    _ = try expectErr(base + "view { text s.price }", "type error", "needs Text")
    _ = try expectErr(base + "view { text s }", "type error", "needs Text")
    _ = try expectErr(base + "view { text toText(s) }", "type error", "toText() works on")
    _ = try expectErr(base + "view { text toText(5.name) }", "type error", "only a struct has fields")
    _ = try expectErr("page \"t\"\n\(ITEM)view { text Item(name: \"a\").name }", "type error", "needs price: Int, qty: Int")
    _ = try expectErr("page \"t\"\n\(ITEM)view { text Item(\"a\", 1, 2).name }", "syntax error", "named fields")
    _ = try expectErr("page \"t\"\n\(ITEM)view { text Item(name: \"a\", price: \"x\", qty: 1).name }", "type error", "needs Int")
    _ = try expectErr("page \"t\"\n\(ITEM)view { text Item(name: \"a\", name: \"b\", price: 1, qty: 1).name }", "type error", "twice")
    _ = try expectErr(base + "view { text (s with qty: \"z\").name }", "type error", "needs Int")
    _ = try expectErr("page \"t\"\n\(ITEM)view { text Item.name }", "type error", "is a struct")
}
test("struct declaration errors") {
    _ = try expectErr("struct A {\n b: A\n}\nview { text \"x\" }", "type error", "contains itself")
    _ = try expectErr("struct A {\n b: List<B>\n}\nstruct B {\n a: A\n}\nview { text \"x\" }", "type error", "contains itself")
    _ = try expectErr("struct Int {\n b: Int\n}\nview { text \"x\" }", "type error", "built-in")
    _ = try expectErr("struct A {\n b: Int\n}\nstruct A {\n b: Int\n}\nview { text \"x\" }", "type error", "twice")
    _ = try expectErr("struct A {\n}\nview { text \"x\" }", "type error", "at least one")
    _ = try expectErr("struct A {\n size: Int\n}\nview { text \"x\" }", "syntax error", "reserved")
    _ = try expectErr("struct A {\n b: Nope\n}\nview { text \"x\" }", "syntax error", "unknown type")
}

// ---- methods and field assignment on structs
let STOCK = "struct Item {\n  name: Text\n  quantity: Int\n" +
    "  fn take(qty: Int) {\n    if self.quantity - qty > 0 {\n      self.quantity = self.quantity - qty\n    }\n  }\n" +
    "  fn restock() {\n    self.quantity = self.quantity + 10\n    self.take(0)\n  }\n" +
    "  fn label(): Text { return self.name + \" x\" + toText(self.quantity) }\n}\n"
func first(_ p: Page) throws -> String { try text(p).components(separatedBy: "\n")[0] }
test("methods: change self through a state list, label returns a value") {
    let p = try page("text stock[0].label()\nbutton \"take\" -> stock[0].take(2)\nbutton \"restock\" -> stock[1].restock()",
                     STOCK + "state stock: List<Item> = [Item(name: \"Tea\", quantity: 5), Item(name: \"Cake\", quantity: 1)]")
    try eq(try first(p), "Tea x5")
    try click(p, "take"); try eq(try first(p), "Tea x3")
    try click(p, "take"); try eq(try first(p), "Tea x1")
    try click(p, "take"); try eq(try first(p), "Tea x1")
    try click(p, "restock"); try check(try text(p).contains("Tea x1"))
}
test("methods and fields: values are copies") {
    let decls = STOCK + "state a: Item = Item(name: \"A\", quantity: 5)\nstate b: Item = a\nfn go() { b.take(2) }"
    try eq(try text(try page("text toText(a.quantity) + \" \" + toText(b.quantity)", decls)), "5 5")
    let q = try page("text toText(a.quantity) + \" \" + toText(b.quantity)\nbutton \"go\" -> go()", decls)
    try click(q, "go"); try eq(try first(q), "5 3")
}
test("field assignment: nested paths, locals, lists") {
    let p = try page("text toText(o.item.quantity) + \" \" + toText(o.item.name) + \" \" + toText(xs[1].quantity)\nbutton \"go\" -> go()",
        "struct Item {\n  name: Text\n  quantity: Int\n}\nstruct Order {\n  item: Item\n}\nstate o: Order = Order(item: Item(name: \"T\", quantity: 1))\n" +
        "state xs: List<Item> = [Item(name: \"a\", quantity: 1), Item(name: \"b\", quantity: 2)]\n" +
        "fn go() {\n  o.item.quantity = 9\n  xs[1].quantity = xs[1].quantity * 10\n  let local = xs[0]\n  local.quantity = 77\n}")
    try click(p, "go"); try eq(try first(p), "9 T 20")
}
test("method inside a method sees the changed self; nested struct methods") {
    let p = try page("text toText(g.n) + \" \" + toText(g.inner.n)\nbutton \"go\" -> g.bump()",
        "struct In {\n  n: Int\n  fn inc() { self.n = self.n + 1 }\n}\nstruct Out {\n  n: Int\n  inner: In\n  fn bump() {\n    self.n = self.n + 1\n    self.inner.inc()\n    self.inner.inc()\n  }\n}\nstate g: Out = Out(n: 0, inner: In(n: 0))")
    try click(p, "go", 2); try eq(try first(p), "2 4")
}
test("method errors and field-assignment errors") {
    let base = "page \"t\"\n" + STOCK + "state s: Item = Item(name: \"a\", quantity: 1)\nstate xs: List<Item> = [s]\n"
    func e(_ src: String, _ needle: String, line: Int = #line) throws { _ = try expectErr(src, src.contains("view { for i in xs") ? "type error" : "type error", needle, line: line) }
    try e(base + "view { text Item(name: \"a\", quantity: 1).take(1) }", "own statement")
    try e(base + "fn f() { Item(name: \"a\", quantity: 1).take(1) }\nview { text \"x\" }", "only a variable")
    try e(base + "fn f() { let x = s.take(1) }\nview { text \"x\" }", "own statement")
    try e(base + "view { for i in xs { button \"x\" -> i.take(1) } }", "copy of a list item")
    _ = try expectErr(base + "fn f() { xs[0] = s }\nview { text \"x\" }", "syntax error", "setAt")
    try e(base + "fn f() { s.nope = 1 }\nview { text \"x\" }", "no field 'nope'")
    try e(base + "fn f() { s.quantity = \"x\" }\nview { text \"x\" }", "needs Int")
    try e(base + "fn f() { s.nope(1) }\nview { text \"x\" }", "no method 'nope'")
    try e(base + "fn f() { s.take() }\nview { text \"x\" }", "takes 1 argument")
    try e(base + "fn f() { s.take(\"x\") }\nview { text \"x\" }", "needs Int")
    try e(base + "fn f() { s.quantity() }\nview { text \"x\" }", "is a field")
    try e(base + "fn f() { 5.take(1) }\nview { text \"x\" }", "only a struct has methods")
    try e(base + "view { text toText(self.quantity) }", "only exists inside")
    _ = try expectErr(base + "fn f() { 5 = 6 }\nview { text \"x\" }", "syntax error", "change a variable or a field")
    try e("struct A {\n n: Int\n fn n() { }\n}\nview { text \"x\" }", "defined twice")
    try e("struct A {\n n: Int\n fn get(): Int { self.n = 1\n return self.n }\n}\nview { text \"x\" }", "cannot change self")
    try e("struct A {\n n: Int\n fn inc() { self.n = 1 }\n fn get(): Int { self.inc()\n return self.n }\n}\nview { text \"x\" }", "cannot change self")
    try e("struct A {\n n: Int\n fn get(): Int { }\n}\nview { text \"x\" }", "must return")
}
test("field assignment and methods: runtime index error is reported") {
    let p = try page("button \"go\" -> xs[5].quantity = 1\nbutton \"go2\" -> xs[5].take(1)\ntext \"ok\"", STOCK + "state xs: List<Item> = [Item(name: \"a\", quantity: 1)]")
    try throwsTern({ try click(p, "go") }, { $0.phase == "runtime error" && $0.msg.contains("outside the list") })
    try throwsTern({ try click(p, "go2") }, { $0.phase == "runtime error" && $0.msg.contains("outside the list") })
}
test("library structs can have methods") {
    let lib = "struct Box {\n  n: Int\n  fn bump(by: Int) { self.n = self.n + by }\n  fn show(): Text { return \"n=\" + toText(self.n) }\n}\nfn make(): Box { return Box(n: 1) }\n"
    let p = try Page("use \"bx.ternlib\"\nstate b: bx.Box = bx.make()\nview {\n  text b.show()\n  button \"g\" -> b.bump(4)\n}", libraries: ["bx": lib])
    try eq(try first(p), "n=1"); try click(p, "g"); try eq(try first(p), "n=5")
}

// ================= libraries (use "x.ternlib") =================
let SHOP = "struct Item {\n  name: Text\n  price: Int\n  qty: Int\n}\n" +
    "fn make(n: Text, p: Int): Item { return Item(name: n, price: p, qty: 1) }\n" +
    "fn lineTotal(i: Item): Int { return i.price * i.qty }\n" +
    "fn sum(items: List<Item>): Int {\n  let t = 0\n  for i in items { t = t + lineTotal(i) }\n  return t\n}\n"
func withLib(_ body: String, _ decls: String = "", _ libs: [String: String] = ["shop": SHOP]) throws -> Page {
    try Page("page \"t\"\nuse \"shop.ternlib\"\n\(decls)\nview {\n\(body)\n}", libraries: libs)
}
test("library: functions and structs under a prefix") {
    let p = try withLib("text toText(shop.sum(cart))\nbutton \"add\" -> cart = append(cart, shop.make(\"Cake\", 5))",
                        "state cart: List<shop.Item> = [shop.Item(name: \"Tea\", price: 3, qty: 2)]")
    try eq(try text(p).components(separatedBy: "\n")[0], "6")
    try click(p, "add")
    try eq(try text(p).components(separatedBy: "\n")[0], "11")
}
test("library: page names do not clash with library names") {
    let p = try withLib("text toText(sum(1, 2) + shop.lineTotal(shop.make(\"a\", 4)))", "fn sum(a: Int, b: Int): Int { return a + b }")
    try eq(try text(p), "7")
}
test("library errors name the file") {
    func bad(_ lib: String, _ needle: String, line: Int = #line) throws {
        do { _ = try withLib("text \"x\"", "", ["shop": lib]) }
        catch let e as TernError {
            try check(e.file == "shop.ternlib" && e.msg.contains(needle), "\(e)", line: line)
            try check(e.description.contains("in shop.ternlib"), "\(e)", line: line)
            return
        }
        throw Fail(description: "line \(line): expected an error")
    }
    try bad("fn f(): Int { return \"a\" }", "needs Int")
    try bad("state n: Int = 1", "keep")
    try bad("view { text \"x\" }", "keep")
    try bad("use \"other.ternlib\"", "other libraries")
    try bad("fn f(): Int { return count }", "unknown name")
    try bad("fn len(x: Int): Int { return x }", "built-in")
    try bad("fn f() { goto home }", "no page")
}
test("library use errors") {
    func e1(_ src: String, _ libs: [String: String], _ needle: String, line: Int = #line) throws {
        do { _ = try Page(src, libraries: libs) }
        catch let e as TernError { try check(e.msg.contains(needle), e.msg, line: line); return }
        throw Fail(description: "line \(line): expected an error")
    }
    try e1("use \"shop.ternlib\"\nview { text \"x\" }", [:], "was not found")
    try e1("use \"dir/shop.ternlib\"\nview { text \"x\" }", [:], "no folders")
    try e1("use \"shop.ternlib\"\nuse \"shop.ternlib\"\nview { text \"x\" }", ["shop": SHOP], "twice")
    try e1("use \"text.ternlib\"\nview { text \"x\" }", ["text": SHOP], "cannot be a library name")
    try e1("use \"shop.ternlib\"\nview { text toText(shop.nope(1)) }", ["shop": SHOP], "has no 'nope'")
    try e1("use \"shop.ternlib\"\nstate shop: Int = 1\nview { text \"x\" }", ["shop": SHOP], "name of a library")
    try e1("use \"shop.ternlib\"\nview { text shop.lineTotal }", ["shop": SHOP], "is a function")
    try e1("use \"shop.ternlib\"\nview { text toText(shop.lineTotal(5)) }", ["shop": SHOP], "needs shop.Item")
    try e1("use \"shop.ternlib\"\nview { text toText(Item(1)) }", ["shop": SHOP], "unknown function")
}

// ================= native engine: the host must never crash =================
test("Int overflow is a runtime error") {
    let p = try page("button \"go\" -> n = n * n", "state n: Int = 4000000000")
    try throwsTern({ try click(p, "go") }, { $0.msg.contains("too big") })
    try throwsTern({ _ = try page("text toText(round(1000000000000.0 * 1000000000000.0 * 1000000000000.0))").render() }, { $0.msg.contains("too big") })
}
test("runaway loops are stopped") {
    let p = try page("button \"go\" -> { for a in range(10000) { for b in range(10000) { n = n + 1 } } }", "state n: Int = 0")
    try throwsTern({ try click(p, "go") }, { $0.msg.contains("too much work") })
}
test("deep nesting is a syntax error, not a crash") {
    try expectErr("view { text toText(" + String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500) + ") }", "syntax error", "nested too deeply")
}
test("a state used before it is set is reported") {
    try expectErr("state a: Int = b + 1\nstate b: Int = 2\nview { }", "runtime error", "before it has a value")
}
test("number formatting matches the playground") {
    try eq(try txt1("text toText(1000000000000000000000.0 * 10.0) + \" \" + toText(0.0000001) + \" \" + toText(123456.5) + \" \" + toText(2.0 / 3.0)"), "1e+22 1e-7 123456.5 0.666666666667")
    try eq(try txt1("text fixed(2.5, 0) + fixed(0.125, 2) + \" \" + fixed(1.005, 2) + \" \" + fixed(0.0 - 0.001, 2)"), "30.13 1.00 -0.00")
    try eq(try txt1("text toText(round(0.0 - 2.5)) + toText(round(0.49999999999999994))"), "-20")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
