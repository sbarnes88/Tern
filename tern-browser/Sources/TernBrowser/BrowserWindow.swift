import AppKit
import SwiftUI
import TernCore
import UniformTypeIdentifiers

struct BrowserWindow: View {
    @StateObject private var tab = Tab()
    @Environment(\.controlActiveState) private var controlActiveState
    let initial: URL?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                PaperScroll(tab: tab)
                if let h = tab.hoverTarget, !h.isEmpty {
                    StatusPill(text: h)
                } else if tab.loading {
                    StatusPill(text: "Loading \(tab.addressText)…")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .toolbar { BrowserToolbar(tab: tab) }
        .navigationTitle(tab.title)
        .focusedSceneObject(tab)
        .sheet(isPresented: $tab.showingSource) { SourceView(tab: tab) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u = u { Task { @MainActor in tab.open(u) } }
            }
            return true
        }
        .onAppear {
            Tab.front = tab
            if tab.url == nil && !tab.loading { tab.open(OpenRequests.pending.popLast() ?? initial ?? Builtin.home) }
        }
        .onChange(of: controlActiveState) { _, state in if state == .key { Tab.front = tab } }
    }
}

/// Files and links opened from Finder or other apps, waiting for a window to show them.
@MainActor
enum OpenRequests {
    static var pending: [URL] = []
    static func open(_ urls: [URL]) {
        for u in urls {
            if let t = Tab.front { t.open(u) } else { pending.append(u) }
        }
    }
}

struct PaperScroll: View {
    @ObservedObject var tab: Tab
    var body: some View {
        let modal = tab.nodes.last { $0.kind == .modal }
        ZStack {
            scroller.allowsHitTesting(modal == nil).accessibilityHidden(modal != nil)
            if let m = modal { ModalLayer(node: m, tab: tab) }
        }
    }
    var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0).id("top")
                    if let e = tab.runtimeError {
                        RuntimeBanner(message: e) { tab.runtimeError = nil }
                    }
                    if let p = tab.problem {
                        ProblemView(problem: p, tab: tab)
                    } else {
                        PageContent(nodes: tab.nodes, tab: tab)
                    }
                }
                .frame(maxWidth: Paper.maxWidth, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(Paper.background)
            .environment(\.colorScheme, .light)
            .onChange(of: tab.renderID) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
    }
}

struct BrowserToolbar: ToolbarContent {
    @ObservedObject var tab: Tab
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { tab.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!tab.canGoBack).help("Back")
            Button { tab.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!tab.canGoForward).help("Forward")
        }
        ToolbarItem(placement: .principal) {
            AddressBar(tab: tab)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if tab.loading {
                Button { tab.stop() } label: { Label("Stop", systemImage: "xmark") }.help("Stop loading")
            } else {
                Button { tab.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }.help("Reload (starts the page fresh)")
            }
            Button { tab.goHome() } label: { Label("Home", systemImage: "house") }.help("Home")
        }
    }
}

struct AddressBar: View {
    @ObservedObject var tab: Tab
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).imageScale(.small)
            TextField("Address of a Tern page", text: $tab.addressText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { tab.openTyped(); focused = false }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .frame(minWidth: 260, idealWidth: 560, maxWidth: 720)
        .onReceive(NotificationCenter.default.publisher(for: .focusAddress)) { _ in focused = true }
    }
    var icon: String {
        switch tab.url?.scheme {
        case "https": return "lock.fill"
        case "file": return "doc"
        case "tern": return "house"
        default: return "globe"
        }
    }
}

extension Notification.Name { static let focusAddress = Notification.Name("TernFocusAddress") }

struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .padding(6)
            .frame(maxWidth: 520, alignment: .leading)
            .allowsHitTesting(false)
    }
}

struct RuntimeBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Text(message).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
        }
        .foregroundStyle(hex("#b3261e"))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hex("#fdecea"), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProblemView: View {
    let problem: PageProblem
    @ObservedObject var tab: Tab
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem.title).font(.system(size: 18, weight: .bold))
            Text(problem.detail).textSelection(.enabled)
            if let line = problem.line, let src = problem.sourceLine {
                Text("line \(line)\n\(src)\n\(String(repeating: " ", count: max((problem.col ?? 1) - 1, 0)))^")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            HStack {
                if let u = problem.openExternally {
                    Button("Open in Web Browser") { NSWorkspace.shared.open(u) }
                }
                if !tab.source.isEmpty {
                    Button("View Source") { tab.showingSource = true }
                }
                if tab.url?.isFileURL == true {
                    Button("Show in Finder") { if let u = tab.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(hex("#7d1a14"))
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hex("#fdecea"))
        .overlay(alignment: .leading) { Rectangle().fill(hex("#b3261e")).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SourceView: View {
    @ObservedObject var tab: Tab
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.title).font(.headline)
                Text(tab.addressText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.source, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(numbered(tab.source))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 620)
    }
    func numbered(_ s: String) -> AttributedString {
        let lines = s.components(separatedBy: "\n")
        let w = String(lines.count).count
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            var n = AttributedString(String(repeating: " ", count: w - String(i + 1).count) + "\(i + 1)  ")
            n.foregroundColor = .secondary
            out += n
            out += AttributedString(l + (i < lines.count - 1 ? "\n" : ""))
        }
        return out
    }
}

// ---------------------------------------------------------------- menus

struct BrowserCommands: Commands {
    @FocusedObject var tab: Tab?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open File…") { openFile() }.keyboardShortcut("o")
            Button("Open Location…") { NotificationCenter.default.post(name: .focusAddress, object: nil) }.keyboardShortcut("l")
            Button("Convert Web Page to Tern…") { ConvertFlow.start(from: tab) }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { tab?.reload() }.keyboardShortcut("r").disabled(tab?.url == nil)
            Button("View Source") { tab?.showingSource = true }.keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(tab?.source.isEmpty ?? true)
            Button("Clear Saved Data for This Page") { tab?.clearSaved() }.disabled(!(tab?.hasSaved ?? false))
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { tab?.goBack() }.keyboardShortcut("[").disabled(!(tab?.canGoBack ?? false))
            Button("Forward") { tab?.goForward() }.keyboardShortcut("]").disabled(!(tab?.canGoForward ?? false))
            Button("Home") { tab?.goHome() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            ForEach(ExampleList.items, id: \.file) { item in
                Button(item.name) { tab?.open(URL(string: "tern://home/examples/\(item.file)")!) }
            }
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tern") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Tern page"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if let t = tab { t.open(u) } else { NSWorkspace.shared.open(u) }
    }
}

enum ExampleList {
    static let items: [(name: String, file: String)] = [
        ("Welcome", "welcome.tern"), ("Counter", "counter.tern"), ("Todo list", "todo.tern"),
        ("Style gallery", "styles.tern"), ("Price table", "table.tern"), ("Article page", "article.tern"),
        ("Multi-page site", "pages.tern"), ("Tip calculator", "tip.tern"), ("Fonts", "fonts.tern"),
        ("Images", "images.tern"), ("Styled buttons", "buttons.tern"), ("Quiz", "quiz.tern"),
        ("Structs (cart)", "structs.tern"), ("Library (shop)", "library.tern"), ("Data table", "datatable.tern"), ("Editable list", "editable.tern"), ("Dialogs (modal)", "modal.tern"), ("Layout", "layout.tern"), ("Form (dropdown, radio)", "form.tern"), ("Feedback (textarea, slider)", "feedback.tern"), ("Stopwatch (timer, saved)", "stopwatch.tern"),
        ("Broken on purpose", "broken.tern"),
    ]
}
