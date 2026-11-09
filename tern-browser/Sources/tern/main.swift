import Foundation
import TernCore

// tern check FILE   type-check a page
// tern text FILE    print the page as plain text
// tern convert FILE.html [ADDRESS] [--everything]   convert saved HTML to a Tern page (printed)

let args = CommandLine.arguments
func usage() -> Never {
    print("usage: tern check FILE.tern | tern text FILE.tern | tern convert FILE.html [ADDRESS] [--everything] | tern version")
    exit(2)
}
guard args.count >= 2 else { usage() }
if args[1] == "version" { print("Tern \(TERN_VERSION)"); exit(0) }
if args[1] == "convert" {
    // For trying the converter on HTML you saved yourself (for example with curl). The browser's File menu does the download.
    guard args.count >= 3 else { usage() }
    let everything = args.contains("--everything")
    let rest = args.dropFirst(2).filter { $0 != "--everything" }
    guard let path = rest.first, let html = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write("cannot read the HTML file\n".data(using: .utf8)!); exit(2)
    }
    let base = rest.dropFirst().first.flatMap { URL(string: $0) }
    do {
        let r = try onBigStack { try convertHTML(html, from: base, mainOnly: !everything, date: "") }
        print(r.source, terminator: "")
        exit(0)
    } catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); exit(1) }
}
guard args.count == 3, ["check", "text"].contains(args[1]) else { usage() }

let path = args[2]
guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(2)
}
do {
    let out: String = try onBigStack {
        // libraries are the .ternlib files in the page's own folder
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        var libs: [String: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".ternlib") {
            libs[String(f.dropLast(8))] = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
        }
        let page = try Page(src, libraries: libs)
        if args[1] == "check" { return "ok: \(page.title) (\(page.screens.count) page(s))" }
        return renderText(try page.render()).joined(separator: "\n")
    }
    print(out)
} catch let e as TernError {
    let lines = src.components(separatedBy: "\n")
    var msg = "\(e.file ?? path):\(e.pos.line):\(e.pos.col): \(e.phase): \(e.msg)"
    if e.file == nil, e.pos.line >= 1 && e.pos.line <= lines.count {
        msg += "\n  \(lines[e.pos.line - 1])\n  \(String(repeating: " ", count: max(e.pos.col - 1, 0)))^"
    }
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}
