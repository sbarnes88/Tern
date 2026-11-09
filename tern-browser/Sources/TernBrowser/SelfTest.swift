import AppKit
import TernCore

// Regression check: TERN_SELFTEST=1 drives a Tab through navigation and clicks, prints results, quits.
@MainActor
enum SelfTest {
    static func run() async {
        let tab = Tab()
        var fails = 0
        func ok(_ c: Bool, _ what: String) { print(c ? "ok  " : "FAIL", what); if !c { fails += 1 } }
        func wait() async { for _ in 0..<200 where tab.loading { try? await Task.sleep(nanoseconds: 20_000_000) } }
        func text() -> String { renderText(tab.nodes).joined(separator: "\n") }
        func find(_ k: RNode.Kind, _ label: String, in nodes: [RNode]? = nil) -> RNode? {
            for n in nodes ?? tab.nodes {
                if n.kind == k && n.text == label { return n }
                if let r = find(k, label, in: n.children) { return r }
            }
            return nil
        }

        tab.open(Builtin.home); await wait()
        ok(tab.title == "Tern Browser" && !tab.nodes.isEmpty && tab.problem == nil, "home loads: \(tab.problem?.detail ?? "")")
        tab.follow(find(.link, "Counter")!); await wait()
        ok(tab.url?.absoluteString == "tern://home/examples/counter.tern", "relative link: \(tab.url?.absoluteString ?? "-")")
        tab.run { try find(.button, "+")!.click!() }
        ok(text().contains("Count: 1"), "button click")
        tab.goBack(); await wait()
        ok(tab.title == "Tern Browser", "back to home")
        tab.goForward(); await wait()
        ok(text().contains("Count: 1"), "forward keeps the page's state")

        tab.open(URL(string: "tern://home/examples/pages.tern")!); await wait()
        tab.run { try find(.button, "Menu")!.click!() }
        ok(tab.addressText.hasSuffix("#menu"), "address shows view: \(tab.addressText)")
        tab.goBack()
        ok(tab.page?.screen == "home" && tab.url?.lastPathComponent == "pages.tern", "Back steps through views first")
        tab.open(URL(string: "tern://home/examples/pages.tern#about")!); await wait()
        ok(tab.page?.screen == "about", "#view in address opens that view")

        // local files, images next to the page, links between files
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tern-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Builtin.root.appendingPathComponent("examples/logo.svg"), to: dir.appendingPathComponent("pic.svg"))
        try? "page \"A\"\nview { image \"pic\" width 50\n link \"next\" to \"b.tern\" }".write(to: dir.appendingPathComponent("a.tern"), atomically: true, encoding: .utf8)
        try? "page \"B\"\nview { image \"nope\" }".write(to: dir.appendingPathComponent("b.tern"), atomically: true, encoding: .utf8)
        tab.open(dir.appendingPathComponent("a.tern")); await wait()
        ok(tab.title == "A" && tab.problem == nil, "local file with local image: \(tab.problem?.detail ?? "")")
        tab.follow(find(.link, "next")!); await wait()
        ok(tab.problem?.detail.contains("no image called \"nope\"") == true && tab.problem!.detail.contains("pic"), "missing image is a type error: \(tab.problem?.detail ?? "-")")
        tab.addressText = dir.path; tab.openTyped(); await wait()
        ok(tab.problem?.title == "No index.tern here", "folder without index.tern")

        // runaway page: reported, app keeps going
        try? "page \"Loop\"\nstate n: Int = 0\nview { button \"go\" -> { for a in range(10000) { for b in range(10000) { n = n + 1 } } } text toText(n) }".write(to: dir.appendingPathComponent("loop.tern"), atomically: true, encoding: .utf8)
        tab.open(dir.appendingPathComponent("loop.tern")); await wait()
        let t0 = Date()
        tab.run { try find(.button, "go")!.click!() }
        ok(tab.runtimeError?.contains("too much work") == true, "runaway loop stopped in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        ok(text().contains("0") || !tab.nodes.isEmpty, "page still shown after runtime error")

        ok(addressToURL("example.com/x.tern")?.absoluteString == "https://example.com/x.tern", "typed web address")
        ok(addressToURL("~/a.tern")?.isFileURL == true, "typed home path")
        print(fails == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED \(fails)")
        try? FileManager.default.removeItem(at: dir)
        NSApp.terminate(nil)
    }
}
