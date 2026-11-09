// Turns the HTML of a web page into the source text of a Tern page. This is a reader, not a browser: it never
// runs scripts, never fetches anything and draws nothing. Only the structure and a few inline styles carry over.
//
//   let r = try convertHTML(html, from: url)      // r.source is a Tern page that passes the Tern checker
//
// Everything written into the page is escaped (quotes, backslashes, line breaks), so text from a web page can never
// become Tern code. The result is run through the Tern checker before it is returned.

import Foundation

public let CONVERT_MAX_INPUT = 2_000_000       // characters of HTML read
public let CONVERT_MAX_OUTPUT = 300_000        // characters of Tern written

public struct ConvertResult {
    public let source: String                  // the Tern page
    public let title: String
    public let dropped: [String: Int]          // what was left out, like ["scripts": 14, "iframes": 2]
    public let truncated: Bool                 // the page was cut at CONVERT_MAX_OUTPUT
    public let readableCharacters: Int         // how much text was found (very little means the page builds itself with JavaScript)
}

public enum ConvertError: Error, CustomStringConvertible {
    case failedCheck(String)
    public var description: String {
        switch self { case .failedCheck(let m): return "The converted page did not pass the Tern checker: \(m)" }
    }
}

public func convertHTML(_ html: String, from base: URL?, mainOnly: Bool = true, date: String = "") throws -> ConvertResult {
    let text = html.count > CONVERT_MAX_INPUT ? String(html.prefix(CONVERT_MAX_INPUT)) : html
    let root = HTMLReader(text).parse()
    let c = Converter(base: base, mainOnly: mainOnly)
    let result = c.run(root, date: date)
    do { _ = try Page(result.source) }
    catch let e as TernError { throw ConvertError.failedCheck(e.description) }
    return result
}

// ---------------------------------------------------------------- inline text

private struct Run: Equatable {
    var text: String
    var bold = false, italic = false, underline = false, strike = false, mono = false
    var color: String? = nil
    var link: String? = nil
    func sameStyle(_ o: Run) -> Bool {
        bold == o.bold && italic == o.italic && underline == o.underline && strike == o.strike && mono == o.mono && color == o.color && link == o.link
    }
}

private struct Ctx { var align: String? = nil; var color: String? = nil }

private let INLINE: Set<String> = ["a", "span", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "code", "kbd", "samp", "tt", "small",
                                   "big", "sup", "sub", "abbr", "cite", "dfn", "q", "mark", "time", "label", "font", "var", "bdi", "bdo", "data",
                                   "wbr", "nobr", "ruby", "rt", "rp", "center-inline"]
// elements that are left out, and what they are called in the note at the top of the page ("" = left out without a mention)
private let DROPPED: [String: String] = [
    "script": "scripts", "noscript": "scripts", "iframe": "iframes", "svg": "graphics", "canvas": "graphics", "video": "media",
    "audio": "media", "object": "media", "embed": "media", "input": "form controls", "button": "form controls", "select": "form controls",
    "textarea": "form controls", "style": "", "head": "", "link": "", "meta": "", "title": "", "template": "", "base": "", "map": "",
    "area": "", "param": "", "source": "", "track": "", "dialog": "", "datalist": "", "optgroup": "", "option": "",
]
private let CSS_COLORS: [String: String] = [
    "black": "#000000", "white": "#ffffff", "gray": "#808080", "grey": "#808080", "silver": "#c0c0c0", "red": "#ff0000", "maroon": "#800000",
    "orange": "#ffa500", "yellow": "#ffff00", "olive": "#808000", "lime": "#00ff00", "green": "#008000", "aqua": "#00ffff", "cyan": "#00ffff",
    "teal": "#008080", "blue": "#0000ff", "navy": "#000080", "fuchsia": "#ff00ff", "magenta": "#ff00ff", "purple": "#800080", "pink": "#ffc0cb",
    "brown": "#a52a2a", "gold": "#ffd700", "tomato": "#ff6347", "crimson": "#dc143c", "darkblue": "#00008b", "darkgreen": "#006400",
    "lightgray": "#d3d3d3", "lightgrey": "#d3d3d3", "darkgray": "#a9a9a9", "darkgrey": "#a9a9a9",
]
private let LINK_COLOR = "#0b57d0"

final class Converter {
    private let base: URL?
    private let mainOnly: Bool
    private var lines: [String] = []
    private var depth = 1
    private var size = 0
    private var truncated = false
    private var dropped: [String: Int] = [:]
    private var readable = 0
    private var bodyIsRoot = false

    init(base: URL?, mainOnly: Bool) { self.base = base; self.mainOnly = mainOnly }

    // ---- the whole page
    fileprivate func run(_ root: HNode, date: String) -> ConvertResult {
        let title = findTitle(root)
        let body = find(root, "body") ?? root
        var start = body
        if mainOnly {
            if let m = find(body, "main") ?? find(body, role: "main") { start = m }
            else if let a = findArticle(body) { start = a }
            else { bodyIsRoot = true }
        }
        if let head = find(root, "head") { countParts(head) }   // scripts in <head> are not on the page, but are still dropped
        var ctx = Ctx()   // the body's own text-align and colour apply to everything in it
        let bs = body.attrs["style"].map(styleDict) ?? [:]
        if let a = bs["text-align"], ["left", "center", "right"].contains(a) { ctx.align = a }
        if let c = bs["color"].flatMap(colorLiteral) { ctx.color = c }
        walkChildren(start, ctx)
        if lines.isEmpty { emit("text \"(Nothing readable was found on this page.)\" color gray") }
        var out = "page \(lit(title))\n\n"
        let from = base.map { $0.absoluteString.filter { !$0.isNewline } } ?? "a web page"
        out += "// Converted from \(from)\(date.isEmpty ? "" : " on \(date)") by Tern Browser.\n"
        out += "// \(mainOnly ? "Main content only" : "The whole page"). "
        let singular = ["scripts": "script", "iframes": "iframe", "graphics": "graphic", "media": "media item", "form controls": "form control",
                        "navigation": "navigation part", "hidden parts": "hidden part", "link lists": "link list", "inline images": "inline image"]
        let notes = dropped.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.value) \($0.value == 1 ? (singular[$0.key] ?? $0.key) : $0.key)" }
        out += notes.isEmpty ? "Nothing was dropped.\n" : "Dropped: \(notes.joined(separator: ", ")).\n"
        out += "// Links point to the original web addresses, and images load from the original site.\n"
        if readable < 200 { out += "// Very little text was found. The page probably builds its content with JavaScript, which is not converted.\n" }
        if truncated { out += "// This page was very long, so the end was left out.\n" }
        out += "\nview {\n" + lines.joined(separator: "\n") + "\n}\n"
        return ConvertResult(source: out, title: title, dropped: dropped, truncated: truncated, readableCharacters: readable)
    }

    private func countParts(_ n: HNode) {
        for k in n.kids {
            if k.tag == "script" || k.tag == "noscript" { count("scripts") }
            countParts(k)
        }
    }

    private func findTitle(_ root: HNode) -> String {
        var t = ""
        if let n = find(root, "title") { t = n.text }
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let h = find(root, "h1") { t = plainText(h) }
        let one = collapse(t)
        return one.isEmpty ? "Converted page" : String(one.prefix(80))
    }

    private func find(_ n: HNode, _ tag: String) -> HNode? {
        if n.tag == tag { return n }
        for k in n.kids { if let f = find(k, tag) { return f } }
        return nil
    }
    private func find(_ n: HNode, role: String) -> HNode? {
        if n.attrs["role"] == role { return n }
        for k in n.kids { if let f = find(k, role: role) { return f } }
        return nil
    }
    private func findArticle(_ n: HNode) -> HNode? {
        if n.tag == "article", plainText(n).count > 300 { return n }
        for k in n.kids { if let f = findArticle(k) { return f } }
        return nil
    }

    // ---- output
    private func emit(_ line: String) {
        if size > CONVERT_MAX_OUTPUT { truncated = true; return }
        let l = String(repeating: "  ", count: depth) + line
        lines.append(l); size += l.count + 1
    }
    private func open(_ line: String) { emit(line + " {"); depth += 1 }
    private func close() { depth -= 1; emit("}") }
    private func count(_ what: String) { if !what.isEmpty { dropped[what, default: 0] += 1 } }

    /// A Tern string literal. Quotes and backslashes are escaped and line breaks become spaces, so nothing in the
    /// text can end the string early or start Tern code.
    private func lit(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n", "\r", "\t", "\u{0C}", "\u{0B}": out += " "
            default: if ch.value >= 0x20, ch.value != 0x7F { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    // ---- walking blocks
    private func isBlockLevel(_ n: HNode) -> Bool {
        if n.isText || n.tag == "br" { return false }
        if INLINE.contains(n.tag) { return n.kids.contains { isBlockLevel($0) } }
        return true
    }

    private func skipped(_ n: HNode, parentIsBody: Bool) -> Bool {
        if let why = DROPPED[n.tag] { count(why); return true }
        if mainOnly {
            if n.tag == "nav" || n.tag == "aside" { count("navigation"); return true }
            if bodyIsRoot, parentIsBody, n.tag == "header" || n.tag == "footer" { count("navigation"); return true }
        }
        if n.attrs["hidden"] != nil || n.attrs["aria-hidden"] == "true" || (n.attrs["style"].map { styleDict($0)["display"] == "none" } ?? false) {
            count("hidden parts"); return true
        }
        return false
    }

    private func walkChildren(_ n: HNode, _ ctx: Ctx) {
        var pending: [Run] = []
        func flush() { paragraph(pending, ctx); pending = [] }
        let isBody = n.tag == "body"
        for k in n.kids {
            if k.isText { pending.append(Run(text: k.text)); continue }
            if k.tag == "br" { flush(); continue }
            if k.tag == "wbr" { continue }
            if skipped(k, parentIsBody: isBody) { continue }
            if INLINE.contains(k.tag), !isBlockLevel(k) { pending += inlineRuns(k, Run(text: ""), ctx); continue }
            flush()
            block(k, ctx)
        }
        flush()
    }

    private func block(_ n: HNode, _ ctx: Ctx) {
        let style = n.attrs["style"].map(styleDict) ?? [:]
        var ctx = ctx
        if let a = style["text-align"], ["left", "center", "right"].contains(a) { ctx.align = a }
        if n.tag == "center" { ctx.align = "center" }
        if let a = n.attrs["align"], ["left", "center", "right"].contains(a.lowercased()) { ctx.align = a.lowercased() }
        if let col = style["color"].flatMap(colorLiteral) { ctx.color = col }
        switch n.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let sizes = ["h1": 26, "h2": 21, "h3": 17, "h4": 15, "h5": 14, "h6": 13]
            let t = plainText(n)
            if t.isEmpty { return }
            var line = "heading \(lit(t)) size \(fontSize(style) ?? sizes[n.tag]!)"
            if let a = ctx.align { line += " align \(a)" }
            if let c = ctx.color ?? nil, !isNearWhite(c) { line += " color \(c)" }
            emit(line); readable += t.count
        case "p", "address", "figcaption", "summary", "caption", "legend":
            paragraph(inlineRuns(n, Run(text: ""), ctx), ctx, style: style)
        case "ul", "ol", "menu":
            list(n, ordered: n.tag == "ol", level: 0, ctx)
        case "table":
            table(n, ctx)
        case "img":
            image(n)
        case "hr":
            emit("divider")
        case "pre":
            preformatted(n)
        case "blockquote":
            open("column padding 10 background #f6f8fa radius 6")
            walkChildren(n, ctx)
            close()
        default:
            // div, section, article, main, form, li outside a list, dl, figure ...: just their contents, in a box if they have a background
            if let bg = style["background-color"].flatMap(colorLiteral) ?? style["background"].flatMap(colorLiteral), !isNearWhite(bg) {
                open("column background \(bg) padding 12 radius 6")
                walkChildren(n, ctx)
                close()
            } else {
                walkChildren(n, ctx)
            }
        }
    }

    // ---- paragraphs
    private func paragraph(_ runs: [Run], _ ctx: Ctx, style: [String: String] = [:], bullet: String? = nil) {
        let r = normalize(runs)
        if r.isEmpty { return }
        let plain = r.map { $0.text }.joined()
        readable += plain.count
        var links: [(label: String, url: String)] = []
        for run in r {
            guard let u = run.link else { continue }
            if let last = links.last, last.url == u { links[links.count - 1].label += run.text }
            else { links.append((run.text, u)) }
        }
        let linkChars = r.filter { $0.link != nil }.map { $0.text.count }.reduce(0, +)
        let otherWords = r.filter { $0.link == nil }.map { $0.text.filter { $0.isLetter || $0.isNumber }.count }.reduce(0, +)
        func linkItems(_ cap: Int) -> String {
            var seen = Set<String>(), items: [String] = []
            for l in links where !seen.contains(l.url) && items.count < cap {
                seen.insert(l.url)
                let label = l.label.trimmingCharacters(in: .whitespaces)
                items.append("link \(lit(label.isEmpty ? l.url : label)) to \(lit(l.url))")
            }
            return items.joined(separator: " ")
        }
        // a line that is only links
        if !links.isEmpty, linkChars * 10 >= plain.count * 9 || otherWords == 0 {   // only links, maybe with separators like " / "
            if bullet != nil { open("row gap 6"); emit("text \(lit("\u{2022}"))"); emit(linkItems(40)); close(); return }
            if links.count == 1 { emit(linkItems(1)) } else { open("row gap 12"); emit(linkItems(40)); close() }
            return
        }
        var blockMods = ""
        if let a = ctx.align { blockMods += " align \(a)" }
        if let sz = fontSize(style) { blockMods += " size \(sz)" }
        if let bg = (style["background-color"] ?? style["background"]).flatMap(colorLiteral), !isNearWhite(bg) { blockMods += " background \(bg)" }
        if bullet != nil {
            emit("bullet \(lit(plain))")
            if !links.isEmpty { open("row gap 12 margin 2"); emit(linkItems(6)); close() }
            return
        }
        let styled = r.map { run -> Run in
            var x = run
            if run.link != nil { x.color = LINK_COLOR; x.underline = true }
            if x.color == nil, let c = ctx.color, !isNearWhite(c) { x.color = c }
            if let c = x.color, isNearWhite(c), blockMods.contains("background") == false { x.color = nil }
            return x
        }
        if styled.count == 1 {
            emit("text \(lit(styled[0].text))" + runMods(styled[0]) + blockMods)
        } else {
            open("para" + blockMods)
            for run in styled { emit("span \(lit(run.text))" + runMods(run)) }
            close()
        }
        if !links.isEmpty { open("row gap 12 margin 2"); emit(linkItems(6)); close() }
    }

    private func runMods(_ r: Run) -> String {
        var m = ""
        if r.bold { m += " bold" }
        if r.italic { m += " italic" }
        if r.underline { m += " underline" }
        if r.strike { m += " strike" }
        if r.mono { m += " font mono" }
        if let c = r.color { m += " color \(c)" }
        return m
    }

    /// Collapses runs of white space into single spaces, trims the ends and joins neighbours that look the same.
    private func normalize(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        var lastSpace = true
        for var r in runs {
            var t = String.UnicodeScalarView()
            for ch in r.text.unicodeScalars {
                if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" || ch == "\u{0C}" || ch == "\u{A0}" || ch == "\u{200B}" {
                    if !lastSpace { t.append(" "); lastSpace = true }
                } else if ch.value >= 0x20, ch.value != 0x7F {
                    t.append(ch); lastSpace = false
                }
            }
            if t.isEmpty { continue }
            r.text = String(t)
            if let p = out.last, p.sameStyle(r) { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        while let l = out.last, l.text.hasSuffix(" ") {
            var l2 = l; l2.text.removeLast()
            if l2.text.isEmpty { out.removeLast() } else { out[out.count - 1] = l2; break }
        }
        return out
    }

    private func inlineRuns(_ n: HNode, _ inherited: Run, _ ctx: Ctx) -> [Run] {
        if n.isText { var r = inherited; r.text = n.text; return [r] }
        if n.tag == "br" || n.tag == "wbr" { var r = inherited; r.text = n.tag == "br" ? " " : ""; return [r] }
        if let why = DROPPED[n.tag] { count(why); return [] }
        if n.attrs["hidden"] != nil || n.attrs["aria-hidden"] == "true" { return [] }
        var r = inherited
        r.text = ""
        let style = n.attrs["style"].map(styleDict) ?? [:]
        switch n.tag {
        case "sup" where n.kids.count == 1 && n.kids[0].tag == "a" && (n.kids[0].attrs["href"] ?? "").hasPrefix("#"): return []   // footnote marks like [1]
        case "b", "strong": r.bold = true
        case "i", "em", "cite", "dfn", "var": r.italic = true
        case "u", "ins": r.underline = true
        case "s", "strike", "del": r.strike = true
        case "code", "kbd", "samp", "tt": r.mono = true
        case "a":
            if let href = n.attrs["href"], let u = resolveLink(href) { r.link = u }
        case "font":
            if let c = n.attrs["color"].flatMap(colorLiteral) { r.color = c }
        default: break
        }
        if let w = style["font-weight"], w == "bold" || w == "bolder" || (Int(w) ?? 0) >= 600 { r.bold = true }
        if style["font-style"] == "italic" { r.italic = true }
        if let d = style["text-decoration"] ?? style["text-decoration-line"] {
            if d.contains("underline") { r.underline = true }
            if d.contains("line-through") { r.strike = true }
        }
        if let c = style["color"].flatMap(colorLiteral) { r.color = c }
        var out: [Run] = []
        if n.tag == "q" { var open = r; open.text = "\u{201C}"; out.append(open) }
        for k in n.kids { out += inlineRuns(k, r, ctx) }
        if n.tag == "q" { var close = r; close.text = "\u{201D}"; out.append(close) }
        return out
    }

    private func plainText(_ n: HNode) -> String {
        var runs: [Run] = []
        func go(_ x: HNode) {
            if x.isText { runs.append(Run(text: x.text)); return }
            if DROPPED[x.tag] != nil || x.attrs["hidden"] != nil { return }
            if x.tag == "br" { runs.append(Run(text: " ")); return }
            for k in x.kids { go(k) }
            if !INLINE.contains(x.tag) { runs.append(Run(text: " ")) }
        }
        go(n)
        return normalize(runs).map { $0.text }.joined()
    }

    private func collapse(_ s: String) -> String { normalize([Run(text: s)]).map { $0.text }.joined() }

    // ---- lists
    /// A long list where every item is just a link is navigation (a menu, a table of contents, a list of languages), not content.
    private func isLinkMenu(_ n: HNode) -> Bool {
        let items = n.kids.filter { $0.tag == "li" }
        if items.count < 10 { return false }
        var linkOnly = 0
        for li in items {
            let total = plainText(li).count
            var inLinks = 0
            func go(_ x: HNode) { if x.tag == "a" { inLinks += plainText(x).count } else { for k in x.kids { go(k) } } }
            go(li)
            if total > 0, inLinks * 10 >= total * 9 { linkOnly += 1 }
        }
        return linkOnly * 10 >= items.count * 9
    }

    private func list(_ n: HNode, ordered: Bool, level: Int, _ ctx: Ctx) {
        if level > 6 { return }
        if mainOnly, isLinkMenu(n) { count("link lists"); return }
        var index = 1
        for li in n.kids where !li.isText {
            if li.tag == "li" { listItem(li, ordered: ordered, index: index, level: level, ctx); index += 1 }
            else if li.tag == "ul" || li.tag == "ol" { list(li, ordered: li.tag == "ol", level: level + 1, ctx) }
        }
    }

    private func listItem(_ li: HNode, ordered: Bool, index: Int, level: Int, _ ctx: Ctx) {
        var first = true
        var pending: [Run] = []
        let indent = String(repeating: "    ", count: level)
        func flush() {
            let r = normalize(pending); pending = []
            if r.isEmpty { return }
            if first {
                first = false
                if ordered {
                    var numbered = r; numbered[0].text = "\(indent)\(index). " + numbered[0].text
                    paragraph(numbered, ctx)
                } else if level > 0 {
                    var nested = r; nested[0].text = indent + nested[0].text
                    paragraph(nested, ctx, bullet: "")
                } else { paragraph(r, ctx, bullet: "") }
            } else { paragraph(r, ctx) }
        }
        for k in li.kids {
            if k.isText { pending.append(Run(text: k.text)); continue }
            if k.tag == "br" { flush(); continue }
            if skipped(k, parentIsBody: false) { continue }
            if k.tag == "ul" || k.tag == "ol" { flush(); list(k, ordered: k.tag == "ol", level: level + 1, ctx); continue }
            if INLINE.contains(k.tag), !isBlockLevel(k) { pending += inlineRuns(k, Run(text: ""), ctx); continue }
            flush(); first = false
            block(k, ctx)
        }
        flush()
    }

    // ---- tables
    private struct Cell { var text: String; var span: Int; var header: Bool }

    private func table(_ t: HNode, _ ctx: Ctx) {
        var rows: [[Cell]] = []
        var inHead = Set<Int>()
        var layout = false
        func collect(_ n: HNode, head: Bool) {
            for k in n.kids where !k.isText {
                switch k.tag {
                case "thead": collect(k, head: true)
                case "tbody", "tfoot": collect(k, head: head)
                case "tr":
                    var cells: [Cell] = []
                    for c in k.kids where c.tag == "td" || c.tag == "th" {
                        if c.kids.contains(where: { isBlockLevel($0) && !["br"].contains($0.tag) }) { layout = true }
                        cells.append(Cell(text: plainText(c), span: max(1, min(Int(c.attrs["colspan"] ?? "1") ?? 1, 30)), header: c.tag == "th"))
                    }
                    if !cells.isEmpty { rows.append(cells); if head { inHead.insert(rows.count - 1) } }
                case "caption": break
                default: break
                }
            }
        }
        collect(t, head: false)
        let columns = rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0
        // a table used for page layout (blocks inside cells, or a single column): show the contents of its cells in order
        if layout || columns <= 1 || rows.count > 500 {
            for row in t.kids where !row.isText { layoutRows(row, ctx) }
            return
        }
        let cols = min(columns, 30)
        var emitted = 0
        let hasHeader = rows.first.map { r in r.allSatisfy { $0.header } || inHead.contains(0) } ?? false
        var head = "table"
        if rows.count > 12 { head += " height 420" }
        if cols > 5 || rows.count > 12 { head += " resizable" }
        open(head)
        for (ri, row) in rows.enumerated() {
            var items: [String] = []
            var used = 0
            for c in row where used < cols {
                let span = min(c.span, cols - used)
                items.append(lit(c.text) + (span > 1 ? " span \(span)" : ""))
                used += span
            }
            if used < cols { items += Array(repeating: "\"\"", count: cols - used) }
            emit((ri == 0 && hasHeader ? "header " : "cells ") + items.joined(separator: ", "))
            readable += row.map { $0.text.count }.reduce(0, +)
            emitted += 1
        }
        close()
    }

    private func layoutRows(_ n: HNode, _ ctx: Ctx) {
        if n.tag == "td" || n.tag == "th" { walkChildren(n, ctx); return }
        if ["thead", "tbody", "tfoot", "tr"].contains(n.tag) { for k in n.kids where !k.isText { layoutRows(k, ctx) } }
    }

    // ---- images and preformatted text
    private func image(_ n: HNode) {
        var src = n.attrs["src"] ?? ""
        if src.isEmpty || src.hasPrefix("data:") { src = n.attrs["data-src"] ?? n.attrs["data-lazy-src"] ?? src }
        if src.hasPrefix("data:") { count("inline images"); return }
        for dim in ["width", "height"] { if let v = n.attrs[dim].flatMap({ Int($0) }), v <= 2 { return } }   // tracking pixels
        guard let url = resolveLink(src) else { return }
        var line = "image \(lit(url))"
        if let alt = n.attrs["alt"].map(collapse), !alt.isEmpty { line += " alt \(lit(String(alt.prefix(200))))" }
        if let w = n.attrs["width"].flatMap({ Int($0) }), w >= 20, w <= 700 { line += " width \(w)" }
        emit(line)
    }

    private func preformatted(_ n: HNode) {
        var raw = ""
        func go(_ x: HNode) { if x.isText { raw += x.text } else if x.tag == "br" { raw += "\n" } else { for k in x.kids { go(k) } } }
        go(n)
        let ls = raw.replacingOccurrences(of: "\t", with: "  ").split(separator: "\n", omittingEmptySubsequences: false).prefix(200)
        if ls.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return }
        open("column gap 0 padding 10 background #f6f8fa radius 6")
        for l in ls {
            let line = l.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            emit("text \(lit(line.isEmpty ? " " : String(line.prefix(300)))) font mono size 10")
        }
        close()
        readable += raw.count
    }

    // ---- addresses
    private func resolveLink(_ href: String) -> String? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty || h.hasPrefix("#") || h.count > 2000 { return nil }
        guard let u = URL(string: h, relativeTo: base)?.absoluteURL, let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil else { return nil }
        return u.absoluteString
    }

    // ---- inline styles
    private func styleDict(_ s: String) -> [String: String] {
        var d: [String: String] = [:]
        for part in s.split(separator: ";").prefix(40) {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { d[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces).lowercased() }
        }
        return d
    }

    private func fontSize(_ style: [String: String]) -> Int? {
        guard let v = style["font-size"] else { return nil }
        func num(_ suffix: String) -> Double? { v.hasSuffix(suffix) ? Double(v.dropLast(suffix.count)) : nil }
        var pt: Double?
        if let px = num("px") { pt = px * 0.75 } else if let pts = num("pt") { pt = pts }
        else if let em = num("rem") ?? num("em") { pt = em * 12 }
        guard let p = pt, p.isFinite else { return nil }
        return min(max(Int(p.rounded()), 6), 96)
    }

    /// A CSS colour as a Tern colour literal like #0b57d0, or nil if it is not one we understand.
    private func colorLiteral(_ v: String) -> String? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            let h = String(s.dropFirst())
            guard h.allSatisfy({ $0.isHexDigit }) else { return nil }
            if h.count == 3 { return "#" + h.map { "\($0)\($0)" }.joined() }
            return h.count == 6 ? "#" + h : nil
        }
        if s.hasPrefix("rgb("), s.hasSuffix(")") {
            let parts = s.dropFirst(4).dropLast().split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).prefix(3).compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            guard parts.count == 3 else { return nil }
            return "#" + parts.map { String(format: "%02x", min(max(Int($0), 0), 255)) }.joined()
        }
        return CSS_COLORS[s]
    }

    private func isNearWhite(_ hex: String) -> Bool {
        let h = hex.dropFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return false }
        let r = Double((v >> 16) & 255), g = Double((v >> 8) & 255), b = Double(v & 255)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 235
    }
}
