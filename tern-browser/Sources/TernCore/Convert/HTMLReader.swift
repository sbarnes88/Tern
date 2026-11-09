// A small, tolerant HTML reader for the page converter. It turns HTML text into a tree of elements and text.
// It never runs anything: scripts and styles are kept as empty elements, and nothing is fetched.
// Limits keep hostile input harmless: at most 2 MB of text, 120,000 nodes, 200 levels deep.

import Foundation

final class HNode {
    let tag: String          // lowercase tag name; "" for a run of text; "#root" for the top
    var text: String         // text of a text node, or of <title>
    var attrs: [String: String]
    var kids: [HNode] = []
    init(_ tag: String, text: String = "", attrs: [String: String] = [:]) { self.tag = tag; self.text = text; self.attrs = attrs }
    var isText: Bool { tag.isEmpty }
}

let HTML_MAX_DEPTH = 200
let HTML_MAX_NODES = 120_000

private let VOID: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
// elements whose contents are not markup: they are skipped (script, style, noscript, textarea) or read as plain text (title)
private let RAW: Set<String> = ["script", "style", "noscript", "textarea", "title", "template"]
private let CLOSES_P: Set<String> = ["p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "hr", "form",
                                     "section", "article", "header", "footer", "nav", "aside", "main", "dl", "figure", "li", "address", "fieldset"]

private let NAMED_ENTITIES: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}",
    "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
    "rdquo": "\u{201D}", "laquo": "\u{AB}", "raquo": "\u{BB}", "bull": "\u{2022}", "middot": "\u{B7}", "euro": "\u{20AC}",
    "pound": "\u{A3}", "yen": "\u{A5}", "cent": "\u{A2}", "deg": "\u{B0}", "times": "\u{D7}", "divide": "\u{F7}", "plusmn": "\u{B1}",
    "para": "\u{B6}", "sect": "\u{A7}", "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}",
]

func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let u = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    while i < u.count {
        if u[i] == "&" {
            var j = i + 1
            while j < u.count, j - i <= 12, u[j] != ";", u[j] != "&", u[j] != " " { j += 1 }
            if j < u.count, u[j] == ";" {
                let name = String(String.UnicodeScalarView(u[(i + 1)..<j]))
                if let r = resolveEntity(name) { out.append(contentsOf: r.unicodeScalars); i = j + 1; continue }
            }
        }
        out.append(u[i]); i += 1
    }
    return String(out)
}

private func resolveEntity(_ name: String) -> String? {
    if name.hasPrefix("#") {
        let digits = name.dropFirst()
        let code: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") { code = UInt32(digits.dropFirst(), radix: 16) } else { code = UInt32(digits) }
        guard let c = code, c > 0, c <= 0x10FFFF, let sc = Unicode.Scalar(c) else { return "\u{FFFD}" }
        return String(Character(sc))
    }
    return NAMED_ENTITIES[name]
}

final class HTMLReader {
    private let s: [Unicode.Scalar]
    private var i = 0
    private var stack: [HNode] = []
    private var count = 0

    init(_ html: String) { s = Array(html.unicodeScalars) }

    func parse() -> HNode {
        let root = HNode("#root")
        stack = [root]
        while i < s.count, count < HTML_MAX_NODES {
            if s[i] == "<" {
                if at("<!--") { skip(past: "-->"); continue }
                if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" { skip(past: ">"); continue }
                if i + 1 < s.count, s[i + 1] == "/" { endTag(); continue }
                if i + 1 < s.count, isAlpha(s[i + 1]) { startTag(); continue }
                addText("<"); i += 1; continue
            }
            var j = i
            while j < s.count, s[j] != "<" { j += 1 }
            addText(String(String.UnicodeScalarView(s[i..<j]))); i = j
        }
        return root
    }

    // ---- helpers
    private func isAlpha(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
    private func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
    private func at(_ lit: String, _ k: Int? = nil) -> Bool {
        var p = k ?? i
        for c in lit.unicodeScalars {
            guard p < s.count else { return false }
            let a = s[p]
            let lower = (a >= "A" && a <= "Z") ? Unicode.Scalar(a.value + 32)! : a
            if lower != c { return false }
            p += 1
        }
        return true
    }
    private func skip(past lit: String) {
        while i < s.count { if at(lit) { i += lit.unicodeScalars.count; return }; i += 1 }
    }
    private func lowered(_ a: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(a)).lowercased() }

    private func addText(_ raw: String) {
        let t = decodeEntities(raw)
        if t.isEmpty { return }
        let top = stack[stack.count - 1]
        if let last = top.kids.last, last.isText { last.text += t; return }
        top.kids.append(HNode("", text: t)); count += 1
    }

    // ---- tags
    private func startTag() {
        i += 1
        var j = i
        while j < s.count, !isSpace(s[j]), s[j] != ">", s[j] != "/" { j += 1 }
        let tag = lowered(s[i..<j])
        i = j
        var selfClose = false
        let attrs = readAttrs(&selfClose)
        if RAW.contains(tag), !selfClose {
            let closing = "</" + tag
            var k = i
            while k < s.count, !at(closing, k) { k += 1 }
            let raw = String(String.UnicodeScalarView(s[i..<k]))
            i = k
            if i < s.count { skip(past: ">") }
            // <title> keeps its text; script, style, noscript, textarea and template are kept as empty elements
            impliedClose(tag)
            stack[stack.count - 1].kids.append(HNode(tag, text: tag == "title" ? decodeEntities(raw) : "", attrs: attrs)); count += 1
            return
        }
        impliedClose(tag)
        let node = HNode(tag, attrs: attrs)
        stack[stack.count - 1].kids.append(node); count += 1
        if !VOID.contains(tag), !selfClose, stack.count < HTML_MAX_DEPTH { stack.append(node) }
    }

    private func readAttrs(_ selfClose: inout Bool) -> [String: String] {
        var attrs: [String: String] = [:]
        while i < s.count {
            while i < s.count, isSpace(s[i]) { i += 1 }
            if i >= s.count { break }
            if s[i] == ">" { i += 1; return attrs }
            if s[i] == "/" { if i + 1 < s.count, s[i + 1] == ">" { selfClose = true }; i += 1; continue }
            var j = i
            while j < s.count, !isSpace(s[j]), s[j] != "=", s[j] != ">", s[j] != "/" { j += 1 }
            let name = lowered(s[i..<j])
            i = j
            if name.isEmpty { i += 1; continue }
            while i < s.count, isSpace(s[i]) { i += 1 }
            var value = ""
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, isSpace(s[i]) { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let q = s[i]; i += 1
                    var k = i
                    while k < s.count, s[k] != q { k += 1 }
                    value = String(String.UnicodeScalarView(s[i..<min(k, i + 4000)]))
                    i = min(k + 1, s.count)
                } else {
                    var k = i
                    while k < s.count, !isSpace(s[k]), s[k] != ">" { k += 1 }
                    value = String(String.UnicodeScalarView(s[i..<min(k, i + 4000)]))
                    i = k
                }
            }
            if attrs.count < 40 { attrs[name] = decodeEntities(value) }
        }
        return attrs
    }

    private func endTag() {
        i += 2
        var j = i
        while j < s.count, !isSpace(s[j]), s[j] != ">" { j += 1 }
        let tag = lowered(s[i..<j])
        i = j
        skip(past: ">")
        if VOID.contains(tag) { return }
        var k = stack.count - 1
        while k > 0 {
            if stack[k].tag == tag { stack.removeSubrange(k...); return }
            k -= 1
        }
    }

    /// Closes elements that HTML closes by itself: a new <li> ends the open one, a block ends an open <p>, and so on.
    private func impliedClose(_ tag: String) {
        func popThrough(_ names: Set<String>, stopAt: Set<String>) {
            var k = stack.count - 1
            while k > 0 {
                let t = stack[k].tag
                if names.contains(t) { stack.removeSubrange(k...); return }
                if stopAt.contains(t) { return }
                k -= 1
            }
        }
        switch tag {
        case "li": popThrough(["li"], stopAt: ["ul", "ol", "menu"])
        case "dt", "dd": popThrough(["dt", "dd"], stopAt: ["dl"])
        case "tr": popThrough(["tr"], stopAt: ["table"])
        case "td", "th": popThrough(["td", "th"], stopAt: ["tr", "table"])
        case "thead", "tbody", "tfoot": popThrough(["thead", "tbody", "tfoot"], stopAt: ["table"])
        case "option": popThrough(["option"], stopAt: ["select"])
        default: break
        }
        if CLOSES_P.contains(tag), stack[stack.count - 1].tag == "p" { stack.removeLast() }
    }
}
