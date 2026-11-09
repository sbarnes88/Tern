import AppKit
import TernCore
import UniformTypeIdentifiers

/// File > Convert Web Page to Tern…  Asks for an address (and says what will happen), downloads that one page,
/// converts its main content to a Tern page, asks where to save it and opens it.
///
/// The download is plain HTML text: no sign-in, no cookies, no scripts, at most 2 MB, 20 seconds. Nothing from the
/// page is ever run. The conversion itself is in TernCore (HTMLConvert.swift) and is covered by the engine tests.
@MainActor
enum ConvertFlow {
    private static let maxBytes = 2_000_000

    static func start(from tab: Tab?) {
        let alert = NSAlert()
        alert.messageText = "Convert a Web Page to Tern"
        alert.informativeText = "Tern Browser will download this one page (no sign-in, cookies or scripts), turn its main content into a Tern page, and open it. Pages that build their content with JavaScript may come out empty."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://example.com/article"
        if let u = tab?.url, u.scheme == "http" || u.scheme == "https" { field.stringValue = u.absoluteString }
        let everything = NSButton(checkboxWithTitle: "Include everything on the page (menus, footers), not just the main content", target: nil, action: nil)
        let stack = NSStackView(views: [field, everything])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 58)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            fail("That is not a web address", "Type an address that starts with http:// or https://, like https://example.com/article.")
            return
        }
        let mainOnly = everything.state != .on
        Task { await convert(url, mainOnly: mainOnly, tab: tab) }
    }

    private static func convert(_ url: URL, mainOnly: Bool, tab: Tab?) async {
        do {
            let (html, final) = try await download(url)
            let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let result = try await Task.detached(priority: .userInitiated) {
                try onBigStack { try convertHTML(html, from: final, mainOnly: mainOnly, date: String(date)) }
            }.value
            guard let file = askWhereToSave(result) else { return }
            try Data(result.source.utf8).write(to: file, options: .atomic)
            if let t = tab { t.open(file) } else { NSWorkspace.shared.open(file) }
        } catch let e as ConvertFailure {
            fail(e.title, e.detail)
        } catch {
            fail("Could not convert this page", "\(error)")
        }
    }

    private struct ConvertFailure: Error { let title: String; let detail: String }

    /// Downloads one page as text. The session keeps no cookies or cache and sends no credentials.
    private static func download(_ url: URL) async throws -> (String, URL) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false; cfg.urlCache = nil; cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20; cfg.timeoutIntervalForResource = 30
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        req.setValue("TernBrowser/\(TERN_VERSION) (page converter)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html, application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: req) }
        catch { throw ConvertFailure(title: "Can't reach this page", detail: error.localizedDescription) }
        let final = resp.url ?? url
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw ConvertFailure(title: "The server said \(h.statusCode)", detail: HTTPURLResponse.localizedString(forStatusCode: h.statusCode).capitalized + " (\(final.absoluteString))")
        }
        let mime = resp.mimeType?.lowercased() ?? ""
        if !(mime.contains("html") || mime.contains("xml") || mime.isEmpty) {
            throw ConvertFailure(title: "This is not a web page", detail: "The address gave \(mime), not HTML.")
        }
        var data = Data()
        do {
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes { throw ConvertFailure(title: "This page is too big", detail: "Tern Browser converts pages up to 2 MB.") }
            }
        } catch let e as ConvertFailure { throw e }
        catch { throw ConvertFailure(title: "The download stopped", detail: error.localizedDescription) }
        var text: String?
        if let name = resp.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId { text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) }
        }
        guard let html = text ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ConvertFailure(title: "This page isn't text", detail: "Could not read the page as text.")
        }
        return (html, final)
    }

    private static func askWhereToSave(_ r: ConvertResult) -> URL? {
        let panel = NSSavePanel()
        panel.message = "Save the converted page"
        panel.allowedContentTypes = [UTType(filenameExtension: "tern") ?? .plainText]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let slug = r.title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        panel.nameFieldStringValue = (slug.isEmpty ? "converted-page" : String(slug.prefix(40))) + ".tern"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func fail(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }
}
