# Tern

Tern is a small, strongly typed language for describing web pages. You write pages as plain Tern source (no HTML or JavaScript), and the language checks pages for type errors before they run.

This repository contains the current language implementation, a web playground, a native macOS browser, a beginner’s guide, and the original Python/Tk prototype.

## What’s in this repo

| Path | What it is |
| --- | --- |
| `playground/` | **Tern Playground (Tern 0.3)** — a code editor with a live rendered page. Runs in any modern web browser (including phones). |
| `tern-browser/` | **Tern Browser** — a native macOS app that browses Tern pages. It implements Tern in Swift (`TernCore`) and renders with native SwiftUI (no HTML, JavaScript, or web view). |
| `guide/` | **Learn Tern guide** — `Learn_Tern.pdf` (beginner’s guide with exercises) plus the scripts/assets used to build it. |
| `python-desktop-v0.1/` | **Early desktop prototype** — a Python + Tk browser. It implements the older 0.1 language only (no styling/images/fonts/decimals/multiple pages), so newer examples may not load in it. |

## What Tern does (language highlights, 0.3)

- **Strong static types:** `Int`, `Float`, `Text`, `Bool`, `Color`, `Align`, `Font`, `List<T>`. No silent conversions.
- **Page model:** `state`, `fn`, and one or more named `view` pages, with `goto` and `back` navigation.
- **UI/content:** text styling (size, bold/italic/underline/strike, color/background, align, font, padding, radius, border), named `style`s, mixed-style `para`/`span`, bullets, tables, and images.
- **Interactive controls:** buttons/boxes with styling; inputs and common view elements as implemented by the engine/renderers.

## Where to find the guide

- **Read the guide:** [`guide/Learn_Tern.pdf`](guide/Learn_Tern.pdf)
- **Guide sources/build script:** [`guide/build_guide.py`](guide/build_guide.py) (and supporting files under `guide/`, e.g. `check.js`, `img/`).

> Note: `guide/.gitignore` currently contains `*`, so files under `guide/` are ignored by Git and are not tracked/pushed unless that ignore rule is changed.

## What you can compile or build already

### 1) Playground (`playground/`) — build the single-file app

`playground/index.html` is a self-contained file you can open directly in a browser. To rebuild it after editing the source pieces:

```bash
cd playground
python3 build.py
node tests.js
```

- `build.py` inlines `tern.js`, `examples.js`, and `playground.src.html` into `index.html`.
- `tests.js` runs the engine tests (Node).

### 2) Tern Browser (`tern-browser/`) — compile a native macOS app

Builds `Tern Browser.app` and registers `.tern` files with Finder:

```bash
cd tern-browser
./build.sh
open "Tern Browser.app"
```

Useful development commands:

```bash
cd tern-browser
swift run TernTests             # engine tests (ported from playground, plus native-safety tests)
swift run tern check page.tern  # type-check from the command line
swift run tern text page.tern   # render a page as plain text
TERN_SELFTEST=1 .build/release/TernBrowser
```

**Requirements:** macOS 14+ and Xcode Command Line Tools.

### 3) Guide (`guide/`) — rebuild `Learn_Tern.pdf`

`guide/build_guide.py` rebuilds the PDF. It drives the real playground in a headless browser to validate samples and capture screenshots, so it has dependencies and may need path adjustments when run outside its original environment:

- **Needs:** Python with `reportlab`, `Pillow`, and `playwright`, plus Node (and Playwright browsers installed).
- **Paths:** the script/config may contain absolute paths (e.g. `/home/claude/...`) — check/edit `OUT`, `INDEX`, and related paths (including `check.js` references) before running elsewhere.

```bash
cd guide
python3 build_guide.py
```

### 4) Python prototype (`python-desktop-v0.1/`) — run/test (interpreted)

Not a compiled artifact, but runnable from source (Python 3.9+ with `tkinter`):

```bash
cd python-desktop-v0.1
python -m tern browse
python -m tern check examples/broken.tern
python -m unittest discover -s tests
```

## License

See [`LICENSE`](LICENSE).
