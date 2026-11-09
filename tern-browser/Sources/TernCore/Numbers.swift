import Foundation

// Number formatting. These follow the rules the playground uses, so a page shows
// the same digits in Tern Browser as it does there.

/// Shortest digits that read back as the same Float, written as 0.003, 12.5, 1e+21 or 1e-7.
public func jsNumberString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    if x == 0 { return "0" }
    let neg = x < 0
    // Swift's description already gives the shortest round-trip digits; reshape them.
    let desc = "\(abs(x))"
    let parts = desc.split(separator: "e", maxSplits: 1)
    let mant = String(parts[0])
    let exp = parts.count > 1 ? Int(parts[1])! : 0
    let mparts = mant.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = String(mparts[0]), frac = mparts.count > 1 ? String(mparts[1]) : ""
    var digits = Array(intPart + frac)
    var point = intPart.count + exp   // value = 0.digits * 10^point
    while digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count, n = point
    let ds = String(digits)
    var out: String
    if k <= n && n <= 21 {
        out = ds + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        out = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        out = "0." + String(repeating: "0", count: -n) + ds
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        out = String(digits[0]) + (k > 1 ? "." + String(digits[1...]) : "") + "e" + sign + String(abs(e))
    }
    return neg ? "-" + out : out
}

/// toText on a Float: whole numbers keep one decimal (3.0); others are rounded
/// to 12 significant digits so 0.1 + 0.2 shows as 0.3.
func floatToText(_ x: Double) -> String {
    if x.isFinite && x == x.rounded(.towardZero) { return fixedDecimals(x, 1) }
    if !x.isFinite { return jsNumberString(x) }
    let r = Double(String(format: "%.11e", x)) ?? x
    return jsNumberString(r)
}

/// fixed(x, n): exactly n decimals, halves rounded up (2.5 -> 3, 0.125 -> 0.13).
func fixedDecimals(_ x: Double, _ places: Int) -> String {
    if !x.isFinite { return jsNumberString(x) }
    if abs(x) >= 1e21 { return jsNumberString(x) }
    let neg = x < 0
    // The exact decimal expansion, with plenty of digits past the rounding point.
    let exact = String(format: "%.\(places + 40)f", abs(x))
    let dot = exact.firstIndex(of: ".")!
    var whole = Array(exact[..<dot])
    let fracAll = Array(exact[exact.index(after: dot)...])
    var frac = Array(fracAll[0..<places])
    let roundUp = fracAll[places] >= "5"
    if roundUp {
        // add one in the last kept place
        var carry = true
        for i in stride(from: frac.count - 1, through: 0, by: -1) where carry {
            if frac[i] == "9" { frac[i] = "0" } else { frac[i] = Character(UnicodeScalar(frac[i].asciiValue! + 1)); carry = false }
        }
        if carry {
            for i in stride(from: whole.count - 1, through: 0, by: -1) where carry {
                if whole[i] == "9" { whole[i] = "0" } else { whole[i] = Character(UnicodeScalar(whole[i].asciiValue! + 1)); carry = false }
            }
            if carry { whole.insert("1", at: 0) }
        }
    }
    let body = String(whole) + (places > 0 ? "." + String(frac) : "")
    return neg && x != 0 ? "-" + body : body
}

/// Math.round: halves go up (2.5 -> 3, -2.5 -> -2).
func roundHalfUp(_ x: Double) -> Double {
    let f = x.rounded(.down)
    return x - f >= 0.5 ? f + 1 : f
}
