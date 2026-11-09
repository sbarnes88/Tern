import AppKit
import SwiftUI
import TernCore

/// A page that failed to load or failed its checks.
struct PageProblem {
    var title: String
    var detail: String
    var line: Int? = nil
    var col: Int? = nil
    var sourceLine: String? = nil
    var openExternally: URL? = nil
}

/// One browser window: the current page, its live state, and history.
@MainActor
final class Tab: ObservableObject {
    /// The tab in the frontmost window, which receives files opened from Finder.
    static weak var front: Tab?
    struct Entry {
        let url: URL
        let source: String
        let assets: AssetInfo?
        let page: Page?          // kept so Back returns to the page as you left it
    }

    @Published private(set) var url: URL?
    @Published var addressText = ""
    @Published private(set) var title = "Tern Browser"
    @Published private(set) var nodes: [RNode] = []
    @Published private(set) var problem: PageProblem?
    @Published var runtimeError: String?
    @Published private(set) var loading = false
    @Published private(set) var source = ""
    @Published var hoverTarget: String?
    @Published var showingSource = false
    @Published private(set) var renderID = 0    // changes when a different page or screen is shown, to reset scrolling

    private(set) var page: Page?
    private var assets: AssetInfo?
    private var libraries: [String: String] = [:]
    private var backStack: [Entry] = []
    private var forwardStack: [Entry] = []
    private var loadTask: Task<Void, Never>?

    var canGoBack: Bool { (page?.history.isEmpty == false) || !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // ---- navigation

    func open(_ target: URL, addToHistory: Bool = true) {
        loadTask?.cancel()
        let previous = currentEntry()
        loading = true
        addressText = target.absoluteString
        loadTask = Task {
            do {
                let loaded = try await fetchPage(target)
                if Task.isCancelled { return }
                if addToHistory, let p = previous { backStack.append(p); forwardStack.removeAll() }
                show(loaded, fragment: target.fragment)
            } catch {
                if Task.isCancelled { return }
                if addToHistory, let p = previous { backStack.append(p); forwardStack.removeAll() }
                failLoad(target, error)
            }
            loading = false
        }
    }

    func openTyped() {
        guard let u = addressToURL(addressText) else {
            problem = PageProblem(title: "Not an address", detail: "Type a web address (example.com/page.tern), a file path (/Users/you/page.tern) or tern://home.")
            nodes = []; page = nil
            return
        }
        open(u)
    }

    // ---- timers: `every` actions the page asked for, run while the app is in front and the page stays on screen
    private var timerRuns: [String: (ms: Int, task: Task<Void, Never>)] = [:]
    private var timerLatest: [String: Page.PageTimer] = [:]

    private func syncTimers() {
        let want = Dictionary(uniqueKeysWithValues: (page?.timers ?? []).map { ($0.key, $0) })
        for (k, r) in timerRuns where want[k]?.ms != r.ms { r.task.cancel(); timerRuns[k] = nil; timerLatest[k] = nil }
        for (k, t) in want {
            timerLatest[k] = t
            if timerRuns[k] == nil {
                timerRuns[k] = (t.ms, Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(t.ms) * 1_000_000)
                        if Task.isCancelled { return }
                        guard let self = self, let cur = self.timerLatest[k] else { return }
                        if NSApp.isActive { self.run { try cur.tick() } }   // paused while the app is in the background
                    }
                })
            }
        }
    }

    private func stopTimers() {
        for (_, r) in timerRuns { r.task.cancel() }
        timerRuns = [:]; timerLatest = [:]
    }

    // ---- saved state: each page keeps its `saved state` values on this Mac, under its own address
    private var savedKey = ""
    private var lastSaved: String?
    @Published private(set) var hasSaved = false

    private func persistSaved() {
        guard let p = page, !p.savedNames.isEmpty else { return }
        if let j = p.savedJSON() {
            if j != lastSaved { SavedStore.write(j, for: savedKey); lastSaved = j }
        } else if p.savedTooBig, runtimeError == nil {
            runtimeError = "This page's saved data is over 64 KB, so it is not being kept."
        }
    }

    /// Forgets what this page saved and starts it fresh.
    func clearSaved() {
        SavedStore.remove(savedKey)
        lastSaved = nil
        reload()
    }

    func reload() {
        guard let u = url else { return }
        open(u, addToHistory: false)
    }

    func stop() { loadTask?.cancel(); loading = false }

    func goHome() { open(Builtin.home) }

    func goBack() {
        if let p = page, !p.history.isEmpty {
            run { p.back() }
            return
        }
        guard let prev = backStack.popLast() else { return }
        if let cur = currentEntry() { forwardStack.append(cur) }
        restore(prev)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let cur = currentEntry() { backStack.append(cur) }
        restore(next)
    }

    private func currentEntry() -> Entry? {
        guard let u = url else { return nil }
        return Entry(url: u, source: source, assets: assets, page: page)
    }

    private func restore(_ e: Entry) {
        loadTask?.cancel(); loading = false
        if let p = e.page {
            url = e.url; source = e.source; assets = e.assets; page = p
            problem = nil; runtimeError = nil
            title = p.title
            renderID += 1
            refresh()
        } else {
            open(e.url, addToHistory: false)
        }
    }

    // ---- running pages

    private func show(_ loaded: Loaded, fragment: String?) {
        stopTimers()
        var base = URLComponents(url: loaded.url, resolvingAgainstBaseURL: false)
        base?.fragment = nil
        url = base?.url ?? loaded.url
        source = loaded.source
        assets = loaded.assets
        libraries = loaded.libraries
        runtimeError = nil
        problem = nil
        renderID += 1
        do {
            let src = loaded.source, a = loaded.assets, libs = loaded.libraries, hint = loaded.libraryHint
            let key = SavedStore.key(for: url)
            savedKey = key
            let kept = SavedStore.read(key)
            let p = try onBigStack { try Page(src, assets: a, libraries: libs, libraryHint: hint, saved: kept) }
            lastSaved = kept
            hasSaved = !p.savedNames.isEmpty
            if let f = fragment, !f.isEmpty { _ = p.show(f) }
            page = p
            title = p.title
            refresh()
        } catch let e as TernError {
            page = nil; nodes = []
            title = "Error"
            let errSource = e.file.flatMap { loaded.libraries[String($0.dropLast(".ternlib".count))] } ?? loaded.source
            let lines = errSource.components(separatedBy: "\n")
            problem = PageProblem(
                title: e.phase.prefix(1).uppercased() + e.phase.dropFirst() + (e.file.map { " in \($0)" } ?? ""),
                detail: e.msg, line: e.pos.line, col: e.pos.col,
                sourceLine: (1...max(lines.count, 1)).contains(e.pos.line) ? lines[e.pos.line - 1] : nil)
            updateAddress()
        } catch {
            page = nil; nodes = []
            problem = PageProblem(title: "Something went wrong", detail: "\(error)")
        }
    }

    private func failLoad(_ target: URL, _ error: Error) {
        stopTimers()
        url = target; source = ""; page = nil; nodes = []; assets = nil
        runtimeError = nil
        renderID += 1
        switch error {
        case LoadFailure.notTern(let u):
            title = "Not a Tern page"
            problem = PageProblem(title: "This is not a Tern page",
                                  detail: "\(u.host ?? u.absoluteString) sent an ordinary web page. Tern Browser only shows Tern pages, but you can open it in your web browser.",
                                  openExternally: u)
        case LoadFailure.message(let t, let d):
            title = t
            problem = PageProblem(title: t, detail: d)
        default:
            title = "Can't open page"
            problem = PageProblem(title: "Can't open page", detail: error.localizedDescription)
        }
        updateAddress()
    }

    /// Re-renders the page from its current state.
    func refresh() {
        guard let p = page else { return }
        let before = p.screen
        do { nodes = try onBigStack { try p.render() } }
        catch let e as TernError { runtimeError = e.description }
        catch { runtimeError = "\(error)" }
        if p.screen != before { renderID += 1 }
        updateAddress()
        persistSaved()
        syncTimers()
    }

    /// Runs page code (a click, a back step) and shows the result. Runtime errors appear above the page.
    func run(_ body: @escaping () throws -> Void) {
        guard let p = page else { return }
        runtimeError = nil
        let before = p.screen
        do { try onBigStack { try body() } }
        catch let e as TernError { runtimeError = e.description }
        catch { runtimeError = "\(error)" }
        if p.screen != before { renderID += 1 }
        refresh()
    }

    func setInput(_ node: RNode, _ value: String) {
        run { try node.set?(value) }
    }

    func follow(_ node: RNode) {
        if let action = node.click { run(action); return }
        guard let raw = node.target, let page = page else { return }
        // #name goes to another view of this page
        if raw.hasPrefix("#") {
            let name = String(raw.dropFirst())
            if page.screens.contains(name) { run { page.goto(name) } }
            else { runtimeError = "This page has no view called '\(name)'." }
            return
        }
        guard let target = URL(string: raw, relativeTo: url)?.absoluteURL else {
            runtimeError = "This link's address is not valid: \(raw)"
            return
        }
        let scheme = target.scheme?.lowercased() ?? ""
        let here = url?.scheme?.lowercased() ?? ""
        if scheme == "file" && here != "file" && here != "tern" {
            runtimeError = "A page from the web can't open files on this computer."
            return
        }
        if scheme == "http" || scheme == "https" {
            let ext = target.pathExtension.lowercased()
            if ext != "tern" && !ext.isEmpty || target.path.isEmpty || target.path == "/" {
                NSWorkspace.shared.open(target)   // an ordinary website: hand it to the web browser
                return
            }
        }
        if !["file", "tern", "http", "https"].contains(scheme) {
            if scheme == "mailto" { NSWorkspace.shared.open(target) }
            else { runtimeError = "Tern Browser can't follow \(scheme): links." }
            return
        }
        open(target)
    }

    private func updateAddress() {
        guard let u = url else { return }
        var s = u.isFileURL ? u.path : u.absoluteString
        if let p = page, p.screen != p.screens.first { s += "#" + p.screen }
        addressText = s
    }

    func describeLink(_ node: RNode) -> String {
        if node.click != nil { return "Runs an action on this page" }
        guard let t = node.target else { return "" }
        if t.hasPrefix("#") { return "Goes to “\(t.dropFirst())” on this page" }
        return URL(string: t, relativeTo: url)?.absoluteURL.absoluteString ?? t
    }
}
