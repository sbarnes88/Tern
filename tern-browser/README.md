# Tern Browser

A native Mac app for browsing Tern pages. No HTML, no JavaScript, no web view: the Tern language
is implemented in Swift (`Sources/TernCore`) and pages are drawn with native SwiftUI views.

```
./build.sh                      # builds "Tern Browser.app" (and registers .tern files with Finder)
open "Tern Browser.app"
swift run TernTests             # 112 engine tests (the 101 from playground/tests.js, plus native-safety tests)
swift run tern check page.tern  # type-check from the command line; `tern text` prints a page as text
TERN_SELFTEST=1 .build/release/TernBrowser   # drives the browser: links, clicks, Back/Forward, files
```

Needs macOS 14 or newer and the Xcode command line tools.

## Using it

- Start page: `tern://home/` (it is `Pages/home.tern`). Built-in examples are under `tern://home/examples/`.
- Open pages from Finder, File > Open (⌘O), drag and drop, or type a path or web address (⌘L).
- Links between `.tern` files work like web links. Links to ordinary websites open in your web browser.
- `page.tern#menu` opens a page at its view called `menu`. Back steps through a page's views, then through pages.
- `use "shop.ternlib"` loads `shop.ternlib` from the same folder as the page (local pages only).
- Images are looked up next to the page: `image "photo"` finds `photo.png`, `photo.svg`, etc.
- Reload (⌘R) starts the page fresh. View Source is ⌥⌘U.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/TernCore/` | The language: lexer, parser, type checker, runtime, plain-text renderer. No UI code. |
| `Sources/TernBrowser/` | The app: window and toolbar, history, page loading, the native renderer (`PageView.swift`). |
| `Sources/tern/` | Command-line `tern check` / `tern text`. |
| `Sources/TernTests/` | Engine tests, ported from `playground/tests.js`. |
| `Pages/` | Built-in pages copied into the app. |

## Differences from the playground engine

Same language (0.3), same error messages, same output. Because a browser has to survive any page,
the native engine also reports these as runtime errors instead of misbehaving:
Int overflow, more than 20 million steps in one click (runaway loops), recursion deeper than 2000 calls,
nesting deeper than 200 levels, and a state read before it has been set.
