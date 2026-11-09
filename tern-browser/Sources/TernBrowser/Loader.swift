import AppKit
import Foundation
import TernCore

// Finding and fetching Tern pages. The browser (the host) does all file and network
// access; pages themselves never can.

enum Builtin {
    /// Folder holding the built-in pages (tern://home/...): inside the app, or in the source tree when run with swift run.
    static let root: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Pages"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("home.tern").path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Pages").standardized
    }()
    static let home = URL(string: "tern://home/")!

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == "tern", url.host == "home" else { return nil }
        let path = url.path
        if path.isEmpty || path == "/" { return root.appendingPathComponent("home.tern") }
        let f = root.appendingPathComponent(String(path.dropFirst())).standardized
        return f.path.hasPrefix(root.path) ? f : nil   // no escaping the built-in folder
    }
}

struct Loaded {
    let url: URL
    let source: String
    let assets: AssetInfo?
    var libraries: [String: String] = [:]   // .ternlib files next to a local page, by name ("shop")
    var libraryHint = "put it next to the page"
}

enum LoadFailure: Error {
    case message(String, String)           // title, detail
    case notTern(URL)                      // an ordinary web page, which Tern Browser does not show
}

let IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff", "bmp"]
private let MAX_PAGE_BYTES = 2 << 20

/// Turns what someone typed in the address bar into a URL.
func addressToURL(_ raw: String) -> URL? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if s.hasPrefix("/") || s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    if s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil, let u = URL(string: s) { return u }
    if !s.contains(" "), s.contains("."), let u = URL(string: "https://" + s) { return u }
    return nil
}

/// The images next to a local page, by name with and without extension ("logo" and "logo.svg").
func localAssets(near page: URL) -> AssetInfo {
    let dir = page.deletingLastPathComponent()
    let fm = FileManager.default
    var names: [String] = []
    func scan(_ folder: URL, prefix: String) {
        guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for f in files.sorted() where !f.hasPrefix(".") {
            let ext = (f as NSString).pathExtension.lowercased()
            if IMAGE_EXTS.contains(ext) {
                let base = prefix + (f as NSString).deletingPathExtension
                if !names.contains(base) { names.append(base) }
                names.append(prefix + f)
            } else if prefix.isEmpty, ext.isEmpty {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: folder.appendingPathComponent(f).path, isDirectory: &isDir), isDir.boolValue {
                    scan(folder.appendingPathComponent(f), prefix: f + "/")   // one folder down, e.g. "images/photo"
                }
            }
        }
    }
    scan(dir, prefix: "")
    return AssetInfo(names: names)
}

/// The .ternlib files in the same folder as a local page. Pages can name only these, never a path.
func localLibraries(near page: URL) -> [String: String] {
    let dir = page.deletingLastPathComponent()
    var out: [String: String] = [:]
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".ternlib") && !f.hasPrefix(".") {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path), data.count <= MAX_PAGE_BYTES,
              let src = String(data: data, encoding: .utf8) else { continue }
        out[String(f.dropLast(".ternlib".count))] = src
    }
    return out
}

func fetchPage(_ url: URL) async throws -> Loaded {
    switch url.scheme?.lowercased() {
    case "tern":
        guard let f = Builtin.fileURL(for: url) else { throw LoadFailure.message("Page not found", "There is no built-in page at \(url.absoluteString).") }
        return try readLocal(f, shownAs: url)
    case "file":
        return try readLocal(url, shownAs: url)
    case "http", "https":
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("text/x-tern, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        req.setValue("TernBrowser/\(TERN_VERSION)", forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LoadFailure.message("Can't reach this page", error.localizedDescription) }
        let final = resp.url ?? url
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw LoadFailure.message("The server said \(h.statusCode)", HTTPURLResponse.localizedString(forStatusCode: h.statusCode).capitalized + " (\(final.absoluteString))")
        }
        let mime = resp.mimeType?.lowercased() ?? ""
        let looksTern = final.pathExtension.lowercased() == "tern" || mime == "text/x-tern" || mime == "text/tern"
        if !looksTern && (mime == "text/html" || mime.hasPrefix("image/") || mime == "application/pdf") { throw LoadFailure.notTern(final) }
        if data.count > MAX_PAGE_BYTES { throw LoadFailure.message("This page is too big", "Tern pages can be up to 2 MB.") }
        guard let src = String(data: data, encoding: .utf8) else { throw LoadFailure.message("This page isn't text", "Tern pages must be UTF-8 text.") }
        return Loaded(url: final, source: src, assets: nil, libraryHint: "libraries only work for pages opened from this computer")   // remote image names are not known in advance
    default:
        throw LoadFailure.message("Can't open this address", "Tern Browser opens tern://, file:, http: and https: addresses.")
    }
}

private func readLocal(_ file: URL, shownAs: URL) throws -> Loaded {
    var f = file
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir) else {
        throw LoadFailure.message("File not found", f.path)
    }
    var shown = shownAs
    if isDir.boolValue {
        f = f.appendingPathComponent("index.tern")
        shown = shown.appendingPathComponent("index.tern")
        guard FileManager.default.fileExists(atPath: f.path) else { throw LoadFailure.message("No index.tern here", "This folder has no index.tern page.") }
    }
    guard let data = FileManager.default.contents(atPath: f.path) else { throw LoadFailure.message("Can't read this file", f.path) }
    if data.count > MAX_PAGE_BYTES { throw LoadFailure.message("This page is too big", "Tern pages can be up to 2 MB.") }
    guard let src = String(data: data, encoding: .utf8) else { throw LoadFailure.message("This file isn't text", "Tern pages must be UTF-8 text.") }
    return Loaded(url: shown, source: src, assets: localAssets(near: f), libraries: localLibraries(near: f))
}

// ---------------------------------------------------------------- images

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func cached(_ key: String) -> NSImage? { images[key] }
    func isMissing(_ key: String) -> Bool { missing.contains(key) }

    func load(_ src: String, base: URL?) async -> NSImage? {
        let key = (base?.absoluteString ?? "") + "|" + src
        if let i = images[key] { return i }
        if missing.contains(key) { return nil }
        let img = await Self.fetch(src, base: base)
        if let img = img { images[key] = img } else { missing.insert(key) }
        return img
    }

    private static func fetch(_ src: String, base: URL?) async -> NSImage? {
        if src.hasPrefix("data:") { return decodeDataURL(src).flatMap { NSImage(data: $0) } }
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let u = URL(string: src) else { return nil }
            return await download(u)
        }
        guard let base = base, !src.contains(":") else { return nil }   // only relative names beyond this point
        if let local = Builtin.fileURL(for: base) ?? (base.isFileURL ? base : nil) {
            let dir = local.deletingLastPathComponent()
            for name in [src] + IMAGE_EXTS.map({ src + "." + $0 }) {
                let f = dir.appendingPathComponent(name)
                if let img = NSImage(contentsOf: f) { return img }
            }
            return nil
        }
        guard let u = URL(string: src, relativeTo: base) else { return nil }
        if let img = await download(u.absoluteURL) { return img }
        if u.pathExtension.isEmpty, let png = URL(string: src + ".png", relativeTo: base) { return await download(png.absoluteURL) }
        return nil
    }

    private static func download(_ u: URL) async -> NSImage? {
        guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 20)),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count < 20 << 20 else { return nil }
        return NSImage(data: data)
    }

    private static func decodeDataURL(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        let payload = String(s[s.index(after: comma)...])
        if meta.hasSuffix(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }
}
