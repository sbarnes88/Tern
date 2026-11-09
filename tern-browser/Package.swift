// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TernBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TernBrowser", targets: ["TernBrowser"]),
        .executable(name: "tern", targets: ["tern"]),
    ],
    targets: [
        // The language: lexer, parser, type checker, runtime. No UI code.
        .target(name: "TernCore"),
        // Command line: tern check FILE, tern text FILE
        .executableTarget(name: "tern", dependencies: ["TernCore"]),
        // The browser app (SwiftUI). Draws pages natively; no web view.
        .executableTarget(name: "TernBrowser", dependencies: ["TernCore"]),
        // Engine tests: swift run TernTests
        .executableTarget(name: "TernTests", dependencies: ["TernCore"]),
    ]
)
