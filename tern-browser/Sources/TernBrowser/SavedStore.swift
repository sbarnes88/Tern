import Foundation
import CryptoKit

/// Where `saved state` values are kept: one small JSON file per page address, in this app's Application Support
/// folder. A page can only ever see its own file; the address (without any #fragment or ?query) is the key.
enum SavedStore {
    static func key(for url: URL?) -> String {
        guard let url = url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        c.fragment = nil; c.query = nil
        return c.string ?? url.absoluteString
    }

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Tern Browser", isDirectory: true).appendingPathComponent("saved", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(hash + ".json")
    }

    static func read(_ key: String) -> String? {
        guard let f = file(key), let d = try? Data(contentsOf: f), d.count <= 65536 else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ json: String, for key: String) {
        guard let f = file(key) else { return }
        try? Data(json.utf8).write(to: f, options: .atomic)
    }
    static func remove(_ key: String) {
        if let f = file(key) { try? FileManager.default.removeItem(at: f) }
    }
}
