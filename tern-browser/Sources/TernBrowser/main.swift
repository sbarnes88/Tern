import AppKit
import SwiftUI

// Tern Browser: a native browser for Tern pages. No HTML, no JavaScript, no web view.

/// A page named on the command line: TernBrowser path/to/page.tern
let launchURL: URL? = {
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    guard let a = args.first else { return nil }
    return addressToURL(a) ?? URL(fileURLWithPath: a)
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder (or `open file.tern`) go to the front window instead of a new one.
    func application(_ app: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenRequests.open(urls) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["TERN_SELFTEST"] != nil { Task { @MainActor in await SelfTest.run() } }
        // Development aid: TERN_SNAPSHOT=out.png saves an image of the window after it loads, then quits.
        if let out = ProcessInfo.processInfo.environment["TERN_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let frame = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

struct TernBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            BrowserWindow(initial: launchURL)
        }
        .defaultSize(width: 980, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { BrowserCommands() }
    }
}

TernBrowserApp.main()
