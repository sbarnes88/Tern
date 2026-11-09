// Lexer: turns source text into tokens.

public let KEYWORDS: Set<String> = [
    "page", "state", "fn", "view", "let", "if", "else", "for", "foreach", "in", "return", "true", "false", "null",
    "to", "placeholder", "text", "heading", "button", "input", "row", "column", "link", "divider",
    // 0.2
    "style", "size", "color", "background", "align", "padding", "bold", "italic", "underline",
    "strike", "when", "para", "span", "table", "header", "cells", "bullet",
    // 0.3
    "image", "alt", "width", "height", "radius", "border", "font", "goto", "back",
    // 0.4
    "struct", "with", "use", "self", "checkbox", "resizable", "modal",
    // layout
    "gap", "margin", "grow", "maxwidth", "minwidth", "grid",
    // choices
    "select", "radio", "textarea", "slider", "disabled",
    // saved state
    "saved", "every",
]

struct Token {
    enum Kind { case int, float, hex, str, kw, id, op, eof }
    let kind: Kind
    let val: String       // text for kw/id/op, value for str/hex, display form for numbers
    var int: Int = 0
    var float: Double = 0
    let pos: Pos
}

private let OPS2: Set<String> = ["->", "==", "!=", "<=", ">=", "&&", "||"]
private let OPS1: Set<Character> = ["{", "}", "(", ")", "[", "]", ",", ":", "=", "<", ">", "+", "-", "*", "/", "%", "!", ".", "?"]

private func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
private func isHex(_ c: Unicode.Scalar) -> Bool { isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") }
private func isIdStart(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" }
private func isWord(_ c: Unicode.Scalar) -> Bool { isIdStart(c) || isDigit(c) }

func tokenize(_ src: String) throws -> [Token] {
    let s = Array(src.unicodeScalars)
    var toks: [Token] = []
    var i = 0, line = 1, ls = 0
    func at(_ k: Int) -> Unicode.Scalar? { k < s.count ? s[k] : nil }
    func str(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(s[a..<b])) }

    while i < s.count {
        let c = s[i]
        let pos = Pos(line, i - ls + 1)
        if c == " " || c == "\t" || c == "\r" { i += 1; continue }
        if c == "\n" { i += 1; line += 1; ls = i; continue }
        if c == "/" && at(i + 1) == "/" {
            while i < s.count && s[i] != "\n" { i += 1 }
            continue
        }
        if c == "#" {
            // #rrggbb or #rgb, and the next character must not continue a word
            var n = 0
            while n < 6, let h = at(i + 1 + n), isHex(h) { n += 1 }
            let after = at(i + 1 + n)
            let bounded = after.map { !isWord($0) } ?? true
            var len = 0
            if n == 6 && bounded { len = 6 }
            else if n >= 3 { if let a3 = at(i + 4), isWord(a3) { len = 0 } else { len = 3 } }
            if len == 0 { throw TernError("unexpected character '#'", pos, "syntax error") }
            var h = str(i + 1, i + 1 + len).lowercased()
            if len == 3 { h = h.map { "\($0)\($0)" }.joined() }
            toks.append(Token(kind: .hex, val: "#" + h, pos: pos))
            i += 1 + len
            continue
        }
        if isDigit(c) {
            var j = i
            while let d = at(j), isDigit(d) { j += 1 }
            if at(j) == ".", let d = at(j + 1), isDigit(d) {
                j += 1
                while let d = at(j), isDigit(d) { j += 1 }
                let v = Double(str(i, j)) ?? 0
                toks.append(Token(kind: .float, val: jsNumberString(v), float: v, pos: pos))
            } else {
                guard let v = Int(str(i, j)) else { throw TernError("the number \(str(i, j)) is too large", pos, "syntax error") }
                toks.append(Token(kind: .int, val: String(v), int: v, pos: pos))
            }
            i = j
            continue
        }
        if c == "\"" {
            var j = i + 1
            var out = String.UnicodeScalarView()
            var bad: Unicode.Scalar? = nil
            var closed = false
            while j < s.count {
                let d = s[j]
                if d == "\"" { closed = true; break }
                if d == "\n" { break }
                if d == "\\" {
                    guard let e = at(j + 1), e != "\n" else { break }
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: if bad == nil { bad = e }
                    }
                    j += 2
                    continue
                }
                out.append(d)
                j += 1
            }
            if !closed { throw TernError("unterminated string", pos, "syntax error") }
            if let b = bad { throw TernError("unknown escape \\\(b)", pos, "syntax error") }
            toks.append(Token(kind: .str, val: String(out), pos: pos))
            i = j + 1
            continue
        }
        if isIdStart(c) {
            var j = i
            while let d = at(j), isWord(d) { j += 1 }
            let w = str(i, j)
            toks.append(Token(kind: KEYWORDS.contains(w) ? .kw : .id, val: w, pos: pos))
            i = j
            continue
        }
        if i + 1 < s.count {
            let two = str(i, i + 2)
            if OPS2.contains(two) { toks.append(Token(kind: .op, val: two, pos: pos)); i += 2; continue }
        }
        if OPS1.contains(Character(c)) { toks.append(Token(kind: .op, val: String(Character(c)), pos: pos)); i += 1; continue }
        throw TernError("unexpected character '\(Character(c))'", pos, "syntax error")
    }
    toks.append(Token(kind: .eof, val: "end of file", pos: Pos(line, i - ls + 1)))
    return toks
}
