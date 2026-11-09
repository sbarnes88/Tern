import SwiftUI
import TernCore

// Draws a Tern render tree with native SwiftUI views.
// Pages are always shown on light "paper", like the playground.

enum Paper {
    static let background = Color.white
    static let ink = hex("#1f2328")
    static let link = hex("#0b57d0")
    static let line = hex("#d0d7de")
    static let buttonFill = hex("#eef1f6")
    static let buttonLine = hex("#c5cbd6")
    static let inputLine = hex("#8c959f")
    static let stripe = hex("#f6f8fa")
    static let muted = hex("#6e7781")
    static let maxWidth: CGFloat = 736      // 46rem
    static let baseSize: CGFloat = 16
}

func hex(_ s: String) -> Color {
    var v: UInt64 = 0
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard h.count == 6, Scanner(string: h).scanHexInt64(&v) else { return Paper.ink }
    return Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

/// Tern sizes are points on the page; shown at 4/3 so they match the playground's pixels.
func fontSize(_ st: Style, _ kind: RNode.Kind) -> CGFloat {
    if let s = st.int("size") { return CGFloat(s) * 4 / 3 }
    return kind == .heading ? 22 * 4 / 3 : Paper.baseSize
}

func ternFont(_ st: Style, _ kind: RNode.Kind, scale: CGFloat = 1) -> Font {
    let size = fontSize(st, kind) * scale
    let bold = st.flag("bold") ?? (kind == .heading)
    var f: Font
    switch st.text("font") ?? "sans" {
    case "serif": f = .system(size: size, design: .serif)
    case "mono": f = .system(size: size, design: .monospaced)
    case "rounded": f = .system(size: size, design: .rounded)
    case "display": f = .custom("Didot", size: size)
    case "hand": f = .custom("Bradley Hand", size: size * 1.1)
    default: f = .system(size: size)
    }
    if bold { f = f.weight(.bold) }
    if st.flag("italic") == true { f = f.italic() }
    return f
}

func alignment(_ st: Style) -> (Alignment, TextAlignment, HorizontalAlignment) {
    switch st.text("align") {
    case "center": return (.center, .center, .center)
    case "right": return (.trailing, .trailing, .trailing)
    default: return (.leading, .leading, .leading)
    }
}

/// Background, padding, corner radius and border, as the playground applies them.
struct BoxStyle: ViewModifier {
    let st: Style
    let defaultPadding: EdgeInsets
    let defaultRadius: CGFloat
    func body(content: Content) -> some View {
        let radius = st.int("radius").map { CGFloat($0) } ?? defaultRadius
        let pad: EdgeInsets = st.int("padding").map { let p = CGFloat($0); return EdgeInsets(top: p, leading: p, bottom: p, trailing: p) }
            ?? (st.text("background") != nil ? defaultPadding : EdgeInsets())
        let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
        content
            .padding(pad)
            .background(st.text("background").map { hex($0) } ?? .clear, in: shape)
            .overlay { if let b = st.text("border") { shape.strokeBorder(hex(b), lineWidth: 1) } }
    }
}

struct PageContent: View {
    let nodes: [RNode]
    @ObservedObject var tab: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NodeList(nodes: nodes, tab: tab, inRow: false)
        }
        .foregroundStyle(Paper.ink)
        .font(.system(size: Paper.baseSize))
        .lineSpacing(3)
    }
}

struct NodeList: View {
    let nodes: [RNode]
    let tab: Tab
    let inRow: Bool
    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
            NodeView(node: n, tab: tab, inRow: inRow).id("\(i)-\(n.kind.rawValue)")
                .layoutValue(key: GrowKey.self, value: n.style.int("grow") ?? 0)   // read by FlowLayout (rows)
        }
    }
}

struct NodeView: View {
    let node: RNode
    let tab: Tab
    let inRow: Bool

    var body: some View {
        content.modifier(LayoutStyle(st: node.style))
    }

    @ViewBuilder
    var content: some View {
        let st = node.style
        switch node.kind {
        case .heading, .text:
            textBlock(Text(node.text), st)
        case .bullet:
            let (_, _, h) = alignment(st)
            let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\u{2022}")
                styled(Text(node.text), st).multilineTextAlignment(alignment(st).1)
            }
            .padding(.leading, 4)
            block(row, st, align: h)
        case .para:
            let (a, t, _) = alignment(st)
            Text(paraString(node))
                .multilineTextAlignment(t)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: inRow ? nil : .infinity, alignment: a)
        case .button:
            ButtonNode(node: node, tab: tab)
        case .input:
            InputNode(node: node, tab: tab)
        case .checkbox:
            CheckboxNode(node: node, tab: tab)
        case .textarea:
            TextareaNode(node: node, tab: tab)
        case .slider:
            SliderNode(node: node, tab: tab)
        case .select:
            SelectNode(node: node, tab: tab, inCell: false)
        case .radio:
            RadioNode(node: node, tab: tab)
        case .modal:
            EmptyView()   // drawn on top of the page by ModalLayer
        case .link:
            LinkNode(node: node, tab: tab)
        case .row:
            FlowLayout(spacing: CGFloat(st.int("gap") ?? 8), justify: st.text("align") ?? "left") { NodeList(nodes: node.children, tab: tab, inRow: true) }
                .modifier(BoxStyle(st: st, defaultPadding: EdgeInsets(), defaultRadius: 0))
                .frame(width: st.int("width").map { CGFloat($0) }, alignment: .leading)
                .frame(maxWidth: inRow ? nil : .infinity, alignment: .leading)
        case .grid:
            let gap = CGFloat(st.int("gap") ?? 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .topLeading), count: node.columns), alignment: .leading, spacing: gap) {
                NodeList(nodes: node.children, tab: tab, inRow: false)
            }
            .frame(maxWidth: st.int("width") == nil && !inRow ? .infinity : nil, alignment: .leading)
            .modifier(BoxStyle(st: st, defaultPadding: EdgeInsets(), defaultRadius: 0))
            .frame(width: st.int("width").map { CGFloat($0) }, alignment: .leading)
        case .column:
            // an aligned column lets its children shrink to their content, so they can sit left, centre or right
            let (_, _, h) = alignment(st)
            let aligned = st.text("align") != nil && st.text("align") != "left" && st.text("align") != "spread"
            VStack(alignment: aligned ? h : .leading, spacing: CGFloat(st.int("gap") ?? 8)) { NodeList(nodes: node.children, tab: tab, inRow: aligned) }
                .frame(maxWidth: st.int("width") == nil && !inRow ? .infinity : nil, alignment: Alignment(horizontal: aligned ? h : .leading, vertical: .center))
                .modifier(BoxStyle(st: st, defaultPadding: EdgeInsets(), defaultRadius: 0))
                .frame(width: st.int("width").map { CGFloat($0) }, alignment: .leading)
        case .table:
            TableNode(node: node, tab: tab)
        case .image:
            ImageNode(node: node, tab: tab, inRow: inRow)
        case .divider:
            Rectangle().fill(Paper.line).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 4)
        case .header, .cells:
            EmptyView()
        }
    }

    func styled(_ t: Text, _ st: Style) -> Text {
        var t = t.font(ternFont(st, node.kind))
        if st.flag("underline") == true { t = t.underline() }
        if st.flag("strike") == true { t = t.strikethrough() }
        if let c = st.text("color") { t = t.foregroundColor(hex(c)) }
        return t
    }

    @ViewBuilder
    func textBlock(_ t: Text, _ st: Style) -> some View {
        let (_, ta, h) = alignment(st)
        block(styled(t, st).multilineTextAlignment(ta).textSelection(.enabled), st, align: h)
    }

    /// Text-like blocks fill the column width (so backgrounds and alignment span it), but not inside a row.
    func block<V: View>(_ v: V, _ st: Style, align: HorizontalAlignment) -> some View {
        v.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: inRow ? nil : .infinity, alignment: Alignment(horizontal: align, vertical: .center))
            .modifier(BoxStyle(st: st, defaultPadding: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10), defaultRadius: 4))
    }
}

func paraString(_ n: RNode) -> AttributedString {
    var out = AttributedString()
    for sp in n.spans {
        var a = AttributedString(sp.text)
        a.font = ternFont(sp.style, .text)
        if let c = sp.style.text("color") { a.foregroundColor = hex(c) }
        if let b = sp.style.text("background") { a.backgroundColor = hex(b) }
        if sp.style.flag("underline") == true { a.underlineStyle = .single }
        if sp.style.flag("strike") == true { a.strikethroughStyle = .single }
        out += a
    }
    return out
}

struct ButtonNode: View {
    let node: RNode
    let tab: Tab
    @State private var pressed = false
    var body: some View {
        let st = node.style
        let radius = CGFloat(st.int("radius") ?? 8)
        let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
        let pad = st.int("padding").map { CGFloat($0) }
        Button { tab.run { try node.click?() } } label: {
            Text(node.label)
                .font(ternFont(st, .button))
                .foregroundColor(st.text("color").map { hex($0) } ?? Paper.ink)
                .padding(.horizontal, pad ?? 14)
                .padding(.vertical, pad ?? 0)
                .frame(minHeight: 40)
                .frame(width: st.int("width").map { CGFloat($0) })
                .background(st.text("background").map { hex($0) } ?? Paper.buttonFill, in: shape)
                .overlay(shape.strokeBorder(st.text("border").map { hex($0) } ?? Paper.buttonLine, lineWidth: 1))
                .contentShape(shape)
                .brightness(pressed ? -0.06 : 0)
        }
        .buttonStyle(PressStyle(pressed: $pressed))
        .fixedSize()
        .disabled(st.flag("disabled") == true)
    }
}

struct PressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, v in pressed = v }
    }
}

struct CheckboxNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        let st = node.style
        Button { tab.run { try node.click?() } } label: {
            HStack(spacing: 10) {
                Image(systemName: node.checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(node.checked ? Paper.link : Paper.muted)
                if !node.text.isEmpty {
                    Text(node.text).font(ternFont(st, .text)).foregroundColor(st.text("color").map { hex($0) } ?? Paper.ink)
                }
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(st.flag("disabled") == true)
        .opacity(st.flag("disabled") == true ? 0.5 : 1)
        .accessibilityValue(node.checked ? "checked" : "unchecked")
    }
}

/// A dropdown: shows the chosen text (or the placeholder) and opens a menu of the options.
struct SelectNode: View {
    let node: RNode
    let tab: Tab
    let inCell: Bool
    var body: some View {
        let st = node.style
        let shown = node.options.contains(node.value) ? node.value : ""
        Menu {
            ForEach(node.options, id: \.self) { o in Button(o) { tab.setInput(node, o) } }
        } label: {
            HStack(spacing: 8) {
                Text(shown.isEmpty ? node.placeholder : shown)
                    .font(ternFont(st, .text))
                    .foregroundColor(shown.isEmpty ? Paper.muted : (st.text("color").map { hex($0) } ?? Paper.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Paper.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: inCell ? .infinity : nil, alignment: .leading)
            .frame(width: inCell ? nil : CGFloat(st.int("width") ?? 220), height: 40)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Paper.inputLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !inCell, vertical: true)
        .disabled(st.flag("disabled") == true)
        .accessibilityValue(shown)
    }
}

/// Radio buttons: every option is shown, one is chosen.
struct RadioNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        let st = node.style
        VStack(alignment: .leading, spacing: 0) {
            ForEach(node.options, id: \.self) { o in
                let on = o == node.value
                Button { tab.setInput(node, o) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(on ? Paper.link : Paper.muted)
                        Text(o).font(ternFont(st, .text)).foregroundColor(st.text("color").map { hex($0) } ?? Paper.ink)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(on ? "selected" : "not selected")
            }
        }
        .fixedSize()
        .disabled(st.flag("disabled") == true)
        .opacity(st.flag("disabled") == true ? 0.5 : 1)
    }
}

struct InputNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        TextField(node.placeholder, text: Binding(get: { node.value }, set: { tab.setInput(node, $0) }))
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12)
            .frame(width: CGFloat(node.style.int("width") ?? 288), height: 40)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Paper.inputLine, lineWidth: 1))
            .disabled(node.style.flag("disabled") == true)
    }
}

/// A multi-line text box.
struct TextareaNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        let st = node.style
        TextEditor(text: Binding(get: { node.value }, set: { tab.setInput(node, $0) }))
            .scrollContentBackground(.hidden)
            .font(ternFont(st, .text))
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(alignment: .topLeading) {
                if node.value.isEmpty {
                    Text(node.placeholder).font(ternFont(st, .text)).foregroundStyle(Paper.muted)
                        .padding(.horizontal, 13).padding(.vertical, 14).allowsHitTesting(false)
                }
            }
            .frame(width: CGFloat(st.int("width") ?? 288), height: CGFloat(st.int("height") ?? 100))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Paper.inputLine, lineWidth: 1))
            .disabled(st.flag("disabled") == true)
    }
}

/// A slider that edits an Int between two numbers.
struct SliderNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        let st = node.style
        Group {
            if node.upper > node.lower {
                Slider(value: Binding(get: { Double(node.number) }, set: { tab.setInput(node, String(Int($0.rounded()))) }),
                       in: Double(node.lower)...Double(node.upper), step: 1)
            } else {
                Slider(value: .constant(0)).disabled(true)   // low and high are the same: nothing to choose
            }
        }
        .tint(st.text("color").map { hex($0) } ?? Paper.link)
        .frame(width: CGFloat(st.int("width") ?? 220), height: 40)
        .disabled(st.flag("disabled") == true)
        .accessibilityValue("\(node.number)")
    }
}

struct LinkNode: View {
    let node: RNode
    let tab: Tab
    var body: some View {
        let st = node.style
        var t = Text(node.text).font(ternFont(st, .link)).foregroundColor(st.text("color").map { hex($0) } ?? Paper.link)
        if st.flag("strike") == true { t = t.strikethrough() } else { t = t.underline() }
        return t
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture { tab.follow(node) }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push(); tab.hoverTarget = tab.describeLink(node) }
                else { NSCursor.pop(); tab.hoverTarget = nil }
            }
            .accessibilityAddTraits(.isLink)
            .accessibilityAction { tab.follow(node) }
    }
}

struct TableNode: View {
    let node: RNode
    let tab: Tab
    @State private var dragged: [Int: CGFloat] = [:]       // widths the reader chose by dragging (resizable tables)
    @State private var dragStart: [Int: CGFloat] = [:]

    private var st: Style { node.style }
    private var padH: CGFloat { st.int("padding").map { CGFloat($0) } ?? 12 }
    private var padV: CGFloat { st.int("padding").map { CGFloat($0) } ?? 7 }
    private var lineColor: Color { st.text("border").map { hex($0) } ?? Paper.line }

    var body: some View {
        let widths = currentWidths()
        if let h = st.int("height") { pinned(CGFloat(h), widths) } else { plain(widths) }
    }

    func currentWidths() -> [CGFloat] {
        var widths = columnWidths()
        if node.resizable { for (c, w) in dragged where c < widths.count { widths[c] = w } }
        return widths
    }

    /// No height: the whole table scrolls sideways when it is too wide.
    func plain(_ widths: [CGFloat]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if let h = node.hrow { line(h, widths, header: true, stripe: false) }
                ForEach(Array(node.body.enumerated()), id: \.offset) { i, r in line(r, widths, header: false, stripe: i % 2 == 1) }
            }
            .overlay(Rectangle().strokeBorder(lineColor, lineWidth: 1))
        }
    }

    /// With a height: a box that scrolls both ways, with the header row held at the top.
    func pinned(_ height: CGFloat, _ widths: [CGFloat]) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(node.body.enumerated()), id: \.offset) { i, r in line(r, widths, header: false, stripe: i % 2 == 1) }
                } header: {
                    if let h = node.hrow { line(h, widths, header: true, stripe: false) }
                }
            }
        }
        .frame(height: min(height, CGFloat(node.body.count + 1) * 35))   // short tables don't leave empty space
        .overlay(Rectangle().strokeBorder(lineColor, lineWidth: 1))
    }

    func line(_ row: TRow, _ widths: [CGFloat], header: Bool, stripe: Bool) -> some View {
        var starts: [Int] = [], c = 0
        for cell in row.cells { starts.append(c); c += cell.span }
        return HStack(spacing: 0) {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { i, cell in
                let w = widths[starts[i]..<min(starts[i] + cell.span, widths.count)].reduce(0, +)
                cellView(cell, header: header, stripe: stripe, width: w)
                    .overlay(alignment: .trailing) {
                        if header && node.resizable { grip(starts[i] + cell.span - 1, widths) }
                    }
            }
        }
    }

    /// The drag handle on the right edge of a header cell: drag to widen or narrow that column.
    func grip(_ col: Int, _ widths: [CGFloat]) -> some View {
        Rectangle().fill(Color.clear)
            .frame(width: 10)
            .overlay(Rectangle().fill(Color.gray.opacity(0.7)).frame(width: 2).padding(.vertical, 8))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let base = dragStart[col] ?? widths[col]
                    dragStart[col] = base
                    dragged[col] = max(48, base + g.translation.width)
                    for (c, w) in widths.enumerated() where dragged[c] == nil { dragged[c] = w }   // fix the other columns where they are
                }
                .onEnded { _ in dragStart[col] = nil })
    }

    func mergedStyle(_ c: TCell, header: Bool) -> Style {
        var m = Style()
        for k in ["size", "color", "font"] { if let v = st[k] { m[k] = v } }
        if header { m["bold"] = .bool(true) }
        for (k, v) in c.style.props { m[k] = v }
        return m
    }

    func cellFont(_ m: Style) -> Font { ternFont(m, .text, scale: m.int("size") == nil ? 0.95 : 1) }

    @ViewBuilder
    func cellView(_ c: TCell, header: Bool, stripe: Bool, width: CGFloat) -> some View {
        let m = mergedStyle(c, header: header)
        let (a, _, _) = alignment(m)
        let fill: Color = c.style.text("background").map { hex($0) }
            ?? (header ? Paper.buttonFill : (st.text("background").map { hex($0) } ?? (stripe ? Paper.stripe : Color.white)))
        Group {
            switch c.kind {
            case "button":
                ButtonNode(node: cellNode(.button, c), tab: tab)
            case "link":
                LinkNode(node: cellNode(.link, c), tab: tab)
            case "checkbox":
                CheckboxNode(node: cellNode(.checkbox, c), tab: tab)
            case "select":
                SelectNode(node: cellNode(.select, c), tab: tab, inCell: true)
            case "input":
                let node = cellNode(.input, c)
                TextField(c.placeholder, text: Binding(get: { c.text }, set: { tab.setInput(node, $0) }))
                    .textFieldStyle(.plain)
                    .font(cellFont(m))
                    .foregroundStyle(Paper.ink)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Paper.inputLine, lineWidth: 1))
            default:
                Text(c.text)
                    .font(cellFont(m))
                    .foregroundColor(m.text("color").map { hex($0) } ?? Paper.ink)
                    .underline(m.flag("underline") == true)
                    .strikethrough(m.flag("strike") == true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, padV).padding(.horizontal, padH)
        .frame(width: width, alignment: a)
        .frame(maxHeight: .infinity)
        .background(fill)
        .overlay(Rectangle().stroke(lineColor, lineWidth: 0.5))
    }

    func cellNode(_ kind: RNode.Kind, _ c: TCell) -> RNode {
        var r = RNode(kind)
        r.text = c.text; r.style = c.style; r.click = c.click; r.target = c.target; r.checked = c.checked; r.set = c.set; r.placeholder = c.placeholder; r.value = c.text; r.options = c.options
        return r
    }

    /// Without a Grid the columns are lined up by hand: the widest cell in each column.
    func columnWidths() -> [CGFloat] {
        let rows = (node.hrow.map { [$0] } ?? []) + node.body
        let count = rows.first.map { $0.cells.reduce(0) { $0 + $1.span } } ?? 0
        var w = [CGFloat](repeating: 0, count: count)
        var spans: [(start: Int, span: Int, width: CGFloat)] = []
        for (ri, r) in rows.enumerated() {
            var c = 0
            for cell in r.cells {
                let cw = naturalWidth(cell, header: node.hrow != nil && ri == 0)
                if cell.span == 1 { w[c] = max(w[c], cw) } else { spans.append((c, cell.span, cw)) }
                c += cell.span
            }
        }
        for s in spans {   // a spanning cell widens its last column if the columns it covers are too narrow
            let have = w[s.start..<s.start + s.span].reduce(0, +)
            if have < s.width { w[s.start + s.span - 1] += s.width - have }
        }
        return w
    }

    func naturalWidth(_ c: TCell, header: Bool) -> CGFloat {
        let m = mergedStyle(c, header: header)
        let kind: RNode.Kind = c.kind == "button" ? .button : .text
        let size = fontSize(m, kind) * (kind == .text && m.int("size") == nil ? 0.95 : 1)
        let bold = c.kind == "button" ? (m.flag("bold") ?? false) : (m.flag("bold") ?? false)
        let f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let text = ceil((c.text as NSString).size(withAttributes: [.font: f]).width) + 2
        if c.kind == "select" {
            let f = NSFont.systemFont(ofSize: size)
            let longest = (c.options + [c.placeholder]).map { ceil(($0 as NSString).size(withAttributes: [.font: f]).width) }.max() ?? 0
            return max(150, longest + 60) + 2 * padH
        }
        if c.kind == "input" { return max(150, text + 30) + 2 * padH }
        if c.kind == "checkbox" { return 22 + (c.text.isEmpty ? 0 : 10 + text) + 2 * padH }
        if c.kind == "button" {
            if let w = c.style.int("width") { return CGFloat(w) + 2 * padH }
            return text + 2 * CGFloat(c.style.int("padding") ?? 14) + 2 * padH
        }
        return text + 2 * padH
    }
}

struct ImageNode: View {
    let node: RNode
    let tab: Tab
    let inRow: Bool
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        let st = node.style
        let w = st.int("width").map { CGFloat($0) }, h = st.int("height").map { CGFloat($0) }
        let radius = CGFloat(st.int("radius") ?? 0)
        let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
        let (a, _, _) = alignment(st)
        let key = (tab.url?.absoluteString ?? "") + "|" + node.src
        Group {
            if let img = image {
                picture(img, w, h)
                    .clipShape(shape)
                    .overlay { if let b = st.text("border") { shape.strokeBorder(hex(b), lineWidth: 1) } }
                    .accessibilityLabel(node.alt)
            } else if failed {
                Text(node.alt.isEmpty ? "image not found: \(node.src)" : node.alt)
                    .font(.system(size: 13)).foregroundStyle(Paper.muted)
                    .padding(12)
                    .frame(minWidth: 120, minHeight: 48)
                    .frame(width: w, height: h)
                    .background(Paper.stripe)
                    .overlay(Rectangle().strokeBorder(Paper.buttonLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                Rectangle().fill(Paper.stripe).frame(width: w ?? 120, height: h ?? (w.map { $0 * 0.56 } ?? 68))
            }
        }
        .frame(maxWidth: inRow ? nil : .infinity, alignment: a)
        .task(id: key) {
            failed = false
            image = await ImageCache.shared.load(node.src, base: tab.url)
            failed = image == nil
        }
    }

    @ViewBuilder
    func picture(_ img: NSImage, _ w: CGFloat?, _ h: CGFloat?) -> some View {
        let natural = img.size
        let aspect = natural.height > 0 ? natural.width / natural.height : 1
        let base = Image(nsImage: img).resizable()
        switch (w, h) {
        case let (w?, h?):
            base.scaledToFill().frame(width: w, height: h).clipped()
        case let (w?, nil):
            FitWidth(maxWidth: w, aspect: aspect) { base }
        case let (nil, h?):
            base.frame(width: h * aspect, height: h)
        default:
            FitWidth(maxWidth: natural.width, aspect: aspect) { base }
        }
    }
}

/// Shows an image at up to maxWidth, narrower if there is less room, keeping its shape.
struct FitWidth: Layout {
    let maxWidth: CGFloat
    let aspect: CGFloat
    func size(_ proposal: ProposedViewSize) -> CGSize {
        let w = min(maxWidth, proposal.width ?? maxWidth)
        return CGSize(width: w, height: w / max(aspect, 0.01))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size(proposal) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// A row: children side by side, wrapping onto new lines when they run out of room, vertically centred.
/// Read by FlowLayout: how many shares of a row's free width a block takes (`grow N`).
struct GrowKey: LayoutValueKey { static let defaultValue: Int = 0 }

/// `margin`, `minwidth` and `maxwidth` for any block.
struct LayoutStyle: ViewModifier {
    let st: Style
    func body(content: Content) -> some View {
        content
            .frame(minWidth: st.int("minwidth").map { CGFloat($0) }, maxWidth: st.int("maxwidth").map { CGFloat($0) }, alignment: .leading)
            .padding(CGFloat(st.int("margin") ?? 0))
    }
}

/// A row: items side by side, wrapping onto new lines. `justify` is the row's `align` (left, center, right or spread).
/// If any item has `grow`, the row stays on one line and those items share the width left over, by weight.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var justify: String = "left"

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let grows = subviews.contains { $0[GrowKey.self] > 0 }
        return CGSize(width: proposal.width.map { grows || justify != "left" ? $0 : min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            let extra = max(bounds.width - row.width, 0)
            var x = bounds.minX, gap = spacing
            switch justify {
            case "center": x += extra / 2
            case "right": x += extra
            case "spread": if row.items.count > 1 { gap += extra / CGFloat(row.items.count - 1) }
            default: break
            }
            for (i, size) in zip(row.items, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        if subviews.contains(where: { $0[GrowKey.self] > 0 }) { return [growRow(maxWidth, subviews)] }
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            var size = subviews[i].sizeThatFits(.unspecified)
            if size.width > maxWidth { size = subviews[i].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)) }
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > maxWidth { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i); r.sizes.append(size)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }

    /// One line: fixed items keep their natural width, `grow` items split what is left.
    private func growRow(_ maxWidth: CGFloat, _ subviews: Subviews) -> Row {
        var row = Row()
        let shares = subviews.map { $0[GrowKey.self] }
        let total = CGFloat(shares.reduce(0, +))
        let fixed = subviews.indices.filter { shares[$0] == 0 }.map { subviews[$0].sizeThatFits(.unspecified).width }.reduce(0, +)
        let free = maxWidth.isFinite ? max(maxWidth - fixed - spacing * CGFloat(subviews.count - 1), 0) : 0
        for i in subviews.indices {
            var size: CGSize
            if shares[i] > 0 {
                let w = maxWidth.isFinite ? free * CGFloat(shares[i]) / total : subviews[i].sizeThatFits(.unspecified).width
                size = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)); size.width = w
            } else { size = subviews[i].sizeThatFits(.unspecified) }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i); row.sizes.append(size)
        }
        return row
    }
}

/// A modal dialog drawn over the page: the page is dimmed and cannot be used behind it.
/// A tap on the dim area, or Escape, runs the modal's close action.
struct ModalLayer: View {
    let node: RNode
    @ObservedObject var tab: Tab

    var body: some View {
        let st = node.style
        let pad = CGFloat(st.int("padding") ?? 20)
        let radius = CGFloat(st.int("radius") ?? 12)
        let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 10) {
                NodeList(nodes: node.children, tab: tab, inRow: false)
            }
            .foregroundStyle(Paper.ink)
            .font(.system(size: Paper.baseSize))
            .padding(pad)
            .frame(maxWidth: CGFloat(st.int("width") ?? 360), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(st.text("background").map { hex($0) } ?? Color.white, in: shape)
            .overlay { if let b = st.text("border") { shape.strokeBorder(hex(b), lineWidth: 1) } }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            .padding(24)
            .accessibilityAddTraits(.isModal)
            Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .environment(\.colorScheme, .light)
    }
    func close() { tab.run { try node.click?() } }
}
